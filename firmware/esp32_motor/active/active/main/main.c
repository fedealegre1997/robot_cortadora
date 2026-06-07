//  Firmware ESP32-S3 — Control de Motores con micro-ROS
//  Placa: ESP32-S3-WROOM-1 (N8R2, 8MB Flash, 2MB PSRAM)
//  Driver de traccion: MC33926 (puente H, 4 canales LEDC — GPIO 4,5,6,7)
//  Encoders en cuadratura: PCNT hardware (Izq GPIO 8/9, Der GPIO 10/11)
//  Bordeadora: Sabertooth 2x25 v2, modo serial simplificado (UART2 TX, GPIO 17, 9600 baud)
//  Cortadora central: AMC CBE12A1C, habilitacion por GPIO 18 → P1-9 INHIBIT (active LOW)
//
//  Protocolo:
//      motion_cmd    = [cmd_id, modo, param, bordeadora_on, cortadora_on]
//      motion_status = [cmd_id, estado, rpm_izq, rpm_der, feedback]
//
//  Modos (motion_cmd[1]):
//      0 = STOP        param ignorado
//      1 = ADELANTE    param = RPM base        (control por velocidad)
//      2 = ATRAS       param = RPM base        (control por velocidad)
//      3 = GIRO_IZQ    param = grados a girar  (control por posicion, giro pivot)
//      4 = GIRO_DER    param = grados a girar  (control por posicion, giro pivot)
//      5 = PIVOT       a definir               (placeholder)
//
//  Descripcion:
//      Recibe comandos de alto nivel del Brain (ROS 2) por micro-ROS serial (UART0).
//      El lazo de control corre LOCALMENTE en este ESP:
//        - ADELANTE/ATRAS: PID de velocidad por rueda (forma incremental) + correccion
//          de rumbo por diferencia de cuentas acumuladas de encoder.
//        - GIRO_IZQ/GIRO_DER: PID de posicion por rueda (giro pivot, ruedas opuestas)
//          hasta alcanzar el angulo, medido por encoders.
//      Los encoders son la fuente de verdad. El IMU se procesa en el Brain (monitoreo).
//      Controla la bordeadora (rampa soft-start anti-cogging, Sabertooth serial).
//      Controla la cortadora central brushless (GPIO 18 HIGH = habilitado, LOW = inhibido).
//      Los accesorios se aplican siempre, independientemente del estado de traccion.
//      El ESP esta SIEMPRE atento: cualquier comando nuevo reemplaza al actual de inmediato.
//
//  Version: 3.0
//  Autor: Angel Alegre
//  Ultima verificacion: 03/06/2026

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "driver/gpio.h"
#include "driver/ledc.h"
#include "driver/uart.h"
#include "driver/pulse_cnt.h"
#include "esp_err.h"
#include "esp_timer.h"
#include "esp_log.h"

#include <rcl/rcl.h>
#include <rcl/error_handling.h>
#include <rclc/rclc.h>
#include <rclc/executor.h>

#include <std_msgs/msg/int32_multi_array.h>

#include <rmw_microxrcedds_c/config.h>
#include <rmw_microros/rmw_microros.h>
#include "esp32_serial_transport.h"

#define RCCHECK(fn)  { rcl_ret_t temp_rc = fn; if ((temp_rc != RCL_RET_OK)) { vTaskDelete(NULL); } }
#define RCSOFTCHECK(fn) { rcl_ret_t temp_rc = fn; (void)temp_rc; }

// =====================================================
// DRIVER / MOTORES MC33926
// =====================================================
// Izquierda (M1)
#define M1_IN1_PIN   GPIO_NUM_4
#define M1_IN2_PIN   GPIO_NUM_5

// Derecha (M2)
#define M2_IN1_PIN   GPIO_NUM_6
#define M2_IN2_PIN   GPIO_NUM_7

// =====================================================
// PWM
// =====================================================
#define PWM_FREQ_HZ       1000
#define PWM_MAX_VALUE     255

#define PWM_TIMER         LEDC_TIMER_0
#define PWM_MODE          LEDC_LOW_SPEED_MODE
#define PWM_RESOLUTION    LEDC_TIMER_8_BIT

#define CH_M1_IN1         LEDC_CHANNEL_0
#define CH_M1_IN2         LEDC_CHANNEL_1
#define CH_M2_IN1         LEDC_CHANNEL_2
#define CH_M2_IN2         LEDC_CHANNEL_3

// =====================================================
// ENCODERS EN CUADRATURA (PCNT hardware)
// =====================================================
#define ENC_L_A_PIN   GPIO_NUM_8
#define ENC_L_B_PIN   GPIO_NUM_9
#define ENC_R_A_PIN   GPIO_NUM_10
#define ENC_R_B_PIN   GPIO_NUM_11

// Signo de conteo de cada encoder. Debe ser +1 cuando la rueda, girando en
// sentido ADELANTE (DIR_FORWARD), hace que las cuentas AUMENTEN.
// Si una rueda va adelante y su RPM se reporta negativa, invertir su signo.
#define ENC_L_SIGN   (+1)
#define ENC_R_SIGN   (-1)   // encoder derecho cableado invertido (verificado en banco)

// Limites del contador de 16 bits del PCNT. Al alcanzarlos el hardware
// resetea a 0 y dispara el evento que acumula el valor en un int64 por software.
#define PCNT_H_LIM     30000
#define PCNT_L_LIM    -30000
#define PCNT_GLITCH_NS 1000   // filtro anti-rebote 1 us

// =====================================================
// PARAMETROS FISICOS / ENCODER
// =====================================================
#define CPR_MOTOR   16.0f                          // cuentas/vuelta del motor (fisico)
#define QUAD_X4     4.0f                            // multiplicacion por cuadratura x4
#define GEAR        90.0f                           // reductora 90:1
#define CPR_OUT     (CPR_MOTOR * QUAD_X4 * GEAR)    // = 5760 cuentas/vuelta eje salida

#define R_RUEDA     0.075f   // radio de rueda [m]
#define L_RUEDAS    0.50f    // distancia entre ruedas, centro a centro [m]

// Grados de eje de rueda por cuenta de encoder
#define DEG_POR_CUENTA   (360.0f / CPR_OUT)

// Cuentas de encoder por grado de rotacion del robot (giro pivot):
//   cuentas = (grados_rad * L/2) / (2*pi*R) * CPR_OUT
//           = grados * (L/2) / (360 * R) * CPR_OUT
#define CUENTAS_POR_GRADO_PIVOT  ((L_RUEDAS / 2.0f) / (360.0f * R_RUEDA) * CPR_OUT)

// =====================================================
// LIMITES DE VELOCIDAD
// =====================================================
#define MAX_RPM_NOM   60.0f
#define MAX_RPM       (MAX_RPM_NOM * 1.1f)   // 66 rpm

// =====================================================
// PID DE VELOCIDAD (forma incremental) — modos ADELANTE/ATRAS
// =====================================================
// Perfil piso liso:
#define VEL_KP   19.5f
#define VEL_KI   0.5f
#define VEL_KD   0.1f
#define VEL_CV_MAX   500.0f   // saturacion interna del controlador
#define VEL_CV_MIN   25.0f    // piso minimo de cv para vencer zona muerta del driver
// Banda muerta del error con histeresis (apaga integral cerca del setpoint)
#define ERR_BAND_ENTER  0.5f
#define ERR_BAND_EXIT   0.7f
// Filtro pasa-bajos doble de la medicion de RPM
// #define PV_ALPHA1   0.92f   // suave (piso liso)
#define PV_ALPHA1   0.80f   // mas rapido (pasto, detecta tranque antes)
#define PV_ALPHA2   0.30f
//
// Perfil pasto (agresivo — mayor carga dinamica):
// #define VEL_KP   28.0f
// #define VEL_KI   1.8f
// #define VEL_KD   0.25f
// #define VEL_CV_MIN   40.0f
// #define ERR_BAND_ENTER  0.3f
// #define ERR_BAND_EXIT   0.5f
// #define PV_ALPHA2   0.50f

// =====================================================
// CONTROL DE RUMBO — correccion diferencial en recta
// =====================================================
// RPM de correccion por cada cuenta de diferencia izq-der acumulada.
// Subir = corrige mas agresivo; ajustar en campo.
// Pasto agresivo: HEADING_KP=0.035, HEADING_CORR_MAX=22.0
#define HEADING_KP   0.02f
// Tope absoluto de la correccion de rumbo [RPM]. Evita que una rueda quede
// starvada a 0 si la realimentacion se descontrola.
#define HEADING_CORR_MAX  15.0f

// =====================================================
// ARRANQUE SUAVE — limitador de slew del PWM (anti-patada)
// =====================================================
// Maxima variacion del PWM por segundo. Subir = arranca mas brusco.
// #define PWM_SLEW_RATE   1200.0f   // pasto moderado
// #define PWM_SLEW_RATE   1800.0f   // pasto agresivo: 0->255 en ~0.14s
#define PWM_SLEW_RATE   600.0f    // piso liso: 0->255 en ~0.4s

// Rampa de setpoint en recta (ADELANTE/ATRAS): la RPM objetivo sube
// gradualmente a este ritmo [RPM/s] en vez de saltar de golpe.
// Pasto agresivo: 55.0
#define RPM_ACCEL   30.0f

// =====================================================
// GIRO POR VELOCIDAD — modos GIRO_IZQ/GIRO_DER
// =====================================================
// El giro se controla regulando la VELOCIDAD de rotacion (reusa el PID de
// velocidad de cada rueda), no capando PWM. Asi la velocidad de giro es suave y
// pareja, pero el lazo aplica todo el PWM que haga falta (hasta 255) para
// mantenerla contra la carga -> el giro se completa aunque haya friccion.
// Pasto agresivo: GIRO_RPM=32, GIRO_RPM_MIN=9, GIRO_DECEL_DEG=16
#define GIRO_RPM        20.0f   // velocidad de crucero del giro [RPM por rueda]
#define GIRO_RPM_MIN    5.0f    // velocidad minima en la aproximacion final [RPM]
#define GIRO_DECEL_DEG  12.0f   // grados de robot antes del objetivo donde empieza a desacelerar
#define GIRO_TOL_DEG    1.0f    // tolerancia para dar el giro por completado [grados de robot]

// =====================================================
// TOPICOS
// =====================================================
static const char * TOPIC_MOTION_CMD    = "motion_cmd";
static const char * TOPIC_MOTION_STATUS = "motion_status";

// =====================================================
// PROTOCOLO
// motion_cmd    = [cmd_id, modo, param, bordeadora_on, cortadora_on]
// motion_status = [cmd_id, estado, rpm_izq, rpm_der, feedback]
// =====================================================
#define CMD_LEN     5
#define STATUS_LEN  5

// =====================================================
// DRIVER SABERTOOTH (Bordeadora)
// =====================================================
#define SABERTOOTH_UART_NUM   UART_NUM_2
#define SABERTOOTH_TX_PIN     GPIO_NUM_17
#define SABERTOOTH_BAUD_RATE  9600

// =====================================================
// CORTADORA CENTRAL (Brushless AMC CBE12A1C)
// =====================================================
#define CORTADORA_ENABLE_PIN  GPIO_NUM_18

#define TRIMMER_SPEED_STOP    64
#define TRIMMER_SPEED_MIN_START 74 // Salto de potencia inicial (aprox 15%) para vencer inercia
#define TRIMMER_SPEED_MAX     85  // Velocidad de prueba súper segura (~33% potencia)
#define TRIMMER_RAMP_STEP     2
#define TRIMMER_RAMP_MS       30

// Convencion logica de direccion para la capa fisica del MC33926
#define DIR_REVERSE 0
#define DIR_FORWARD 1

// =====================================================
// MODOS Y ESTADOS
// =====================================================
enum MotionMode {
    MODE_STOP     = 0,
    MODE_ADELANTE = 1,
    MODE_ATRAS    = 2,
    MODE_GIRO_IZQ = 3,
    MODE_GIRO_DER = 4,
    MODE_PIVOT    = 5
};

enum MotionState {
    STATE_IDLE      = 0,
    STATE_ACCEPTED  = 1,
    STATE_EXECUTING = 2,
    STATE_DONE      = 3,   // giro completado / comando finalizado
    STATE_ABORTED   = 4,
    STATE_ERROR     = 5
};

// =====================================================
// ESTADO DE ACCESORIOS
// =====================================================
static int32_t current_trimmer_speed = TRIMMER_SPEED_STOP;
static int64_t last_trimmer_update_ms = 0;
static int32_t target_trimmer_state = 0; // Memoria del último estado de la bordeadora deseado

// =====================================================
// GLOBALES micro-ROS
// =====================================================
static size_t uart_port = 0;

rcl_subscription_t motion_cmd_subscriber;
rcl_publisher_t motion_status_publisher;

std_msgs__msg__Int32MultiArray motion_cmd_msg;
std_msgs__msg__Int32MultiArray motion_status_msg;

// =====================================================
// ENCODERS — handles y acumuladores int64
// =====================================================
static pcnt_unit_handle_t enc_l_unit = NULL;
static pcnt_unit_handle_t enc_r_unit = NULL;
static volatile int64_t enc_l_accum = 0;   // acumulado por overflow (ISR)
static volatile int64_t enc_r_accum = 0;

// =====================================================
// ESTADO DEL CONTROL DE TRACCION
// =====================================================
typedef struct {
    // PID velocidad (incremental) — usado en recta y en giro
    float cv1, error1, error2;
    bool  in_band;
    // filtro de RPM
    float pv_lp, pv_lp2;
    // medicion
    int64_t counts_prev;   // para calcular delta de RPM
    float   rpm;           // RPM con signo (filtrada en magnitud)
    // arranque suave: ultimo PWM aplicado con signo (+ adelante, - atras)
    float last_pwm_signed;
} wheel_ctrl_t;

static wheel_ctrl_t wl = {0};   // rueda izquierda
static wheel_ctrl_t wr = {0};   // rueda derecha

// Comando activo
static int32_t g_cmd_id = 0;
static int32_t g_mode   = MODE_STOP;
static int32_t g_param  = 0;
static int32_t g_state  = STATE_IDLE;

// Referencia de cuentas al iniciar un comando (para rumbo / posicion)
static int64_t g_start_counts_l = 0;
static int64_t g_start_counts_r = 0;

// Setpoint de RPM rampeado (arranque suave en recta y en giro)
static float g_base_ramp = 0.0f;

// Direcciones de cada rueda durante un giro (DIR_FORWARD/DIR_REVERSE)
static int32_t g_giro_dir_l = DIR_FORWARD;
static int32_t g_giro_dir_r = DIR_FORWARD;

// Feedback publicado en motion_status (recta: error_rumbo; giro: grados hechos)
static int32_t g_feedback = 0;

// Tiempos
static int64_t last_status_pub_ms = 0;
static int64_t last_ctrl_tick_ms  = 0;

// =====================================================
// HELPERS HARDWARE PWM
// =====================================================
static void pwm_write(ledc_channel_t channel, uint32_t duty)
{
    if (duty > PWM_MAX_VALUE) {
        duty = PWM_MAX_VALUE;
    }
    ledc_set_duty(PWM_MODE, channel, duty);
    ledc_update_duty(PWM_MODE, channel);
}

static void stop_all_motors(void)
{
    pwm_write(CH_M1_IN1, 0);
    pwm_write(CH_M1_IN2, 0);
    pwm_write(CH_M2_IN1, 0);
    pwm_write(CH_M2_IN2, 0);
}

// Capa fisica: aplica PWM y direccion en el MC33926 (2 canales por motor)
static void apply_motor_command(int32_t l_dir, int32_t l_pwm, int32_t r_dir, int32_t r_pwm)
{
    // Motor Izquierdo (M1)
    if (l_pwm == 0) {
        pwm_write(CH_M1_IN1, 0);
        pwm_write(CH_M1_IN2, 0);
    } else if (l_dir == DIR_FORWARD) {
        pwm_write(CH_M1_IN1, (uint32_t)l_pwm);
        pwm_write(CH_M1_IN2, 0);
    } else {
        pwm_write(CH_M1_IN1, 0);
        pwm_write(CH_M1_IN2, (uint32_t)l_pwm);
    }

    // Motor Derecho (M2)
    if (r_pwm == 0) {
        pwm_write(CH_M2_IN1, 0);
        pwm_write(CH_M2_IN2, 0);
    } else if (r_dir == DIR_FORWARD) {
        pwm_write(CH_M2_IN1, 0);
        pwm_write(CH_M2_IN2, (uint32_t)r_pwm);
    } else {
        pwm_write(CH_M2_IN1, (uint32_t)r_pwm);
        pwm_write(CH_M2_IN2, 0);
    }
}

// =====================================================
// SABERTOOTH (bordeadora) — sin cambios
// =====================================================
static void sabertooth_hw_init(void)
{
    uart_config_t uart_config = {
        .baud_rate = SABERTOOTH_BAUD_RATE,
        .data_bits = UART_DATA_8_BITS,
        .parity    = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };

    ESP_ERROR_CHECK(uart_driver_install(SABERTOOTH_UART_NUM, 256, 0, 0, NULL, 0));
    ESP_ERROR_CHECK(uart_param_config(SABERTOOTH_UART_NUM, &uart_config));
    ESP_ERROR_CHECK(uart_set_pin(
        SABERTOOTH_UART_NUM,
        SABERTOOTH_TX_PIN,
        UART_PIN_NO_CHANGE, // Sin RX
        UART_PIN_NO_CHANGE,
        UART_PIN_NO_CHANGE
    ));

    // Enviar comando de parada inicial (64) para limpiar la línea UART y sincronizar el driver
    vTaskDelay(pdMS_TO_TICKS(50));
    uart_write_bytes(SABERTOOTH_UART_NUM, (const char[]){TRIMMER_SPEED_STOP}, 1);
    vTaskDelay(pdMS_TO_TICKS(50));
}

static void ledc_init_channel(gpio_num_t pin, ledc_channel_t channel)
{
    ledc_channel_config_t ch_conf = {
        .gpio_num   = pin,
        .speed_mode = PWM_MODE,
        .channel    = channel,
        .intr_type  = LEDC_INTR_DISABLE,
        .timer_sel  = PWM_TIMER,
        .duty       = 0,
        .hpoint     = 0
    };
    ESP_ERROR_CHECK(ledc_channel_config(&ch_conf));
}

// =====================================================
// ENCODERS PCNT — callback de overflow y configuracion
// =====================================================
// Al alcanzar un watch point (H_LIM o L_LIM) el contador se reinicia a 0;
// acumulamos el valor del limite en el int64 de software para no perder cuentas.
static bool enc_on_reach(pcnt_unit_handle_t unit,
                         const pcnt_watch_event_data_t *edata,
                         void *user_ctx)
{
    volatile int64_t *accum = (volatile int64_t *)user_ctx;
    *accum += edata->watch_point_value;
    return false; // no despierta ninguna tarea de mayor prioridad
}

static void encoder_unit_init(pcnt_unit_handle_t *unit,
                              gpio_num_t pin_a, gpio_num_t pin_b,
                              volatile int64_t *accum)
{
    pcnt_unit_config_t unit_config = {
        .high_limit = PCNT_H_LIM,
        .low_limit  = PCNT_L_LIM,
    };
    ESP_ERROR_CHECK(pcnt_new_unit(&unit_config, unit));

    pcnt_glitch_filter_config_t filter = { .max_glitch_ns = PCNT_GLITCH_NS };
    ESP_ERROR_CHECK(pcnt_unit_set_glitch_filter(*unit, &filter));

    // Canal A: cuenta flancos de pin_a, controlado por nivel de pin_b
    pcnt_chan_config_t chan_a_cfg = {
        .edge_gpio_num  = pin_a,
        .level_gpio_num = pin_b,
    };
    pcnt_channel_handle_t chan_a = NULL;
    ESP_ERROR_CHECK(pcnt_new_channel(*unit, &chan_a_cfg, &chan_a));
    ESP_ERROR_CHECK(pcnt_channel_set_edge_action(chan_a,
        PCNT_CHANNEL_EDGE_ACTION_DECREASE,   // flanco descendente
        PCNT_CHANNEL_EDGE_ACTION_INCREASE)); // flanco ascendente
    ESP_ERROR_CHECK(pcnt_channel_set_level_action(chan_a,
        PCNT_CHANNEL_LEVEL_ACTION_KEEP,
        PCNT_CHANNEL_LEVEL_ACTION_INVERSE));

    // Canal B: cuenta flancos de pin_b, controlado por nivel de pin_a (=> x4)
    pcnt_chan_config_t chan_b_cfg = {
        .edge_gpio_num  = pin_b,
        .level_gpio_num = pin_a,
    };
    pcnt_channel_handle_t chan_b = NULL;
    ESP_ERROR_CHECK(pcnt_new_channel(*unit, &chan_b_cfg, &chan_b));
    ESP_ERROR_CHECK(pcnt_channel_set_edge_action(chan_b,
        PCNT_CHANNEL_EDGE_ACTION_INCREASE,
        PCNT_CHANNEL_EDGE_ACTION_DECREASE));
    ESP_ERROR_CHECK(pcnt_channel_set_level_action(chan_b,
        PCNT_CHANNEL_LEVEL_ACTION_KEEP,
        PCNT_CHANNEL_LEVEL_ACTION_INVERSE));

    // Watch points en los limites para acumular el overflow
    ESP_ERROR_CHECK(pcnt_unit_add_watch_point(*unit, PCNT_H_LIM));
    ESP_ERROR_CHECK(pcnt_unit_add_watch_point(*unit, PCNT_L_LIM));
    pcnt_event_callbacks_t cbs = { .on_reach = enc_on_reach };
    ESP_ERROR_CHECK(pcnt_unit_register_event_callbacks(*unit, &cbs, (void *)accum));

    ESP_ERROR_CHECK(pcnt_unit_enable(*unit));
    ESP_ERROR_CHECK(pcnt_unit_clear_count(*unit));
    ESP_ERROR_CHECK(pcnt_unit_start(*unit));

    // Pull-up interno por seguridad (encoders push-pull lo dominan; evita ruido si se desconecta)
    gpio_set_pull_mode(pin_a, GPIO_PULLUP_ONLY);
    gpio_set_pull_mode(pin_b, GPIO_PULLUP_ONLY);
}

// Lectura del conteo total (acumulado + contador hardware), con signo aplicado
static int64_t encoder_read(pcnt_unit_handle_t unit, volatile int64_t *accum, int sign)
{
    int count = 0;
    pcnt_unit_get_count(unit, &count);
    return (int64_t)sign * (*accum + (int64_t)count);
}

// =====================================================
// INIT HARDWARE GLOBAL
// =====================================================
static esp_err_t motor_hw_init(void)
{
    sabertooth_hw_init(); // UART del Sabertooth

    // Cortadora central: GPIO de habilitación, arranca deshabilitada
    gpio_config_t cortadora_gpio = {
        .pin_bit_mask = (1ULL << CORTADORA_ENABLE_PIN),
        .mode         = GPIO_MODE_OUTPUT,
        .pull_up_en   = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&cortadora_gpio));
    gpio_set_level(CORTADORA_ENABLE_PIN, 0);

    // PWM de traccion
    ledc_timer_config_t ledc_timer = {
        .speed_mode       = PWM_MODE,
        .duty_resolution  = PWM_RESOLUTION,
        .timer_num        = PWM_TIMER,
        .freq_hz          = PWM_FREQ_HZ,
        .clk_cfg          = LEDC_AUTO_CLK
    };
    ESP_ERROR_CHECK(ledc_timer_config(&ledc_timer));

    ledc_init_channel(M1_IN1_PIN, CH_M1_IN1);
    ledc_init_channel(M1_IN2_PIN, CH_M1_IN2);
    ledc_init_channel(M2_IN1_PIN, CH_M2_IN1);
    ledc_init_channel(M2_IN2_PIN, CH_M2_IN2);

    stop_all_motors();

    // Encoders en cuadratura por hardware
    encoder_unit_init(&enc_l_unit, ENC_L_A_PIN, ENC_L_B_PIN, &enc_l_accum);
    encoder_unit_init(&enc_r_unit, ENC_R_A_PIN, ENC_R_B_PIN, &enc_r_accum);

    return ESP_OK;
}

// =====================================================
// STATUS
// =====================================================
static void publish_status_now(int32_t cmd_id, int32_t estado,
                               int32_t rpm_izq, int32_t rpm_der, int32_t feedback)
{
    motion_status_msg.data.data[0] = cmd_id;
    motion_status_msg.data.data[1] = estado;
    motion_status_msg.data.data[2] = rpm_izq;
    motion_status_msg.data.data[3] = rpm_der;
    motion_status_msg.data.data[4] = feedback;
    RCSOFTCHECK(rcl_publish(&motion_status_publisher, &motion_status_msg, NULL));
    last_status_pub_ms = esp_timer_get_time() / 1000LL;
}

// =====================================================
// CONTROL: reset de estado de los lazos
// =====================================================
static void reset_wheel_ctrl(wheel_ctrl_t *w, int64_t counts_now)
{
    w->cv1 = 0.0f;
    w->error1 = 0.0f;
    w->error2 = 0.0f;
    w->in_band = false;
    w->pv_lp = 0.0f;
    w->pv_lp2 = 0.0f;
    w->counts_prev = counts_now;
    w->rpm = 0.0f;
    w->last_pwm_signed = 0.0f;   // arranca desde 0 -> rampa suave en cada comando
}

// Limitador de slew del PWM (anti-patada). Recibe el PWM deseado CON SIGNO
// (+ adelante, - atras), limita su variacion por ciclo y devuelve la magnitud
// limitada; la direccion resultante queda en *dir_out.
static int32_t slew_pwm(wheel_ctrl_t *w, float desired_signed, float dt_s, int32_t *dir_out)
{
    float maxstep = PWM_SLEW_RATE * dt_s;
    float delta = desired_signed - w->last_pwm_signed;
    if (delta >  maxstep) delta =  maxstep;
    if (delta < -maxstep) delta = -maxstep;
    float limited = w->last_pwm_signed + delta;
    w->last_pwm_signed = limited;

    if (limited >= 0.0f) {
        *dir_out = DIR_FORWARD;
        return (int32_t)(limited + 0.5f);
    }
    *dir_out = DIR_REVERSE;
    return (int32_t)(-limited + 0.5f);
}

// Mide RPM con signo a partir del delta de cuentas. Devuelve magnitud filtrada en *pv_out.
static void measure_rpm(wheel_ctrl_t *w, int64_t counts_now, float dt_s, float *pv_out)
{
    int64_t delta = counts_now - w->counts_prev;
    w->counts_prev = counts_now;

    float rev = (float)delta / CPR_OUT;
    float rpm_signed = (rev / dt_s) * 60.0f;
    w->rpm = rpm_signed;

    float pv_raw = fabsf(rpm_signed);
    w->pv_lp  = PV_ALPHA1 * w->pv_lp  + (1.0f - PV_ALPHA1) * pv_raw;
    w->pv_lp2 = (1.0f - PV_ALPHA2) * w->pv_lp2 + PV_ALPHA2 * w->pv_lp;
    *pv_out = w->pv_lp2;
}

// PID de velocidad (forma incremental). sp y pv en RPM (magnitud). Devuelve PWM 0..255.
static int32_t vel_pid_step(wheel_ctrl_t *w, float sp, float pv, float Tm)
{
    float error = sp - pv;

    // Histeresis de banda muerta
    float abs_e = fabsf(error);
    if (w->in_band) {
        if (abs_e >= ERR_BAND_EXIT) w->in_band = false;
    } else {
        if (abs_e <= ERR_BAND_ENTER) w->in_band = true;
    }
    float ki_eff = w->in_band ? 0.0f : VEL_KI;

    // Coeficientes incrementales con Tm dinamico
    float a0 = (VEL_KP + VEL_KD / Tm);
    float a1 = (-VEL_KP + ki_eff * Tm - 2.0f * VEL_KD / Tm);
    float a2 = (VEL_KD / Tm);

    float cv_new = w->cv1 + a0 * error + a1 * w->error1 + a2 * w->error2;

    if (cv_new > VEL_CV_MAX) cv_new = VEL_CV_MAX;
    if (sp <= 0.0f) cv_new = 0.0f;
    else if (cv_new < VEL_CV_MIN) cv_new = VEL_CV_MIN;

    w->cv1 = cv_new;
    w->error2 = w->error1;
    w->error1 = error;

    int32_t pwm = (int32_t)(cv_new * (255.0f / VEL_CV_MAX));
    if (pwm > PWM_MAX_VALUE) pwm = PWM_MAX_VALUE;
    if (pwm < 0) pwm = 0;
    return pwm;
}

// =====================================================
// APLICAR UN COMANDO NUEVO (siempre atento)
// =====================================================
static void start_command(int32_t cmd_id, int32_t mode, int32_t param)
{
    int64_t cl = encoder_read(enc_l_unit, &enc_l_accum, ENC_L_SIGN);
    int64_t cr = encoder_read(enc_r_unit, &enc_r_accum, ENC_R_SIGN);

    g_cmd_id = cmd_id;
    g_mode   = mode;
    g_param  = param;
    g_start_counts_l = cl;
    g_start_counts_r = cr;

    reset_wheel_ctrl(&wl, cl);
    reset_wheel_ctrl(&wr, cr);
    g_base_ramp = 0.0f;   // arranque suave: la RPM objetivo arranca de 0

    switch (mode) {
        case MODE_STOP:
            stop_all_motors();
            g_state = STATE_IDLE;
            break;

        case MODE_ADELANTE:
        case MODE_ATRAS:
            g_state = STATE_EXECUTING;
            break;

        case MODE_GIRO_IZQ:
            // Giro a la izquierda (pivot): rueda izq retrocede, rueda der avanza.
            // El angulo objetivo esta en g_param; el progreso se mide por encoders.
            g_giro_dir_l = DIR_REVERSE;
            g_giro_dir_r = DIR_FORWARD;
            g_state = STATE_EXECUTING;
            break;

        case MODE_GIRO_DER:
            // Giro a la derecha (pivot): rueda izq avanza, rueda der retrocede.
            g_giro_dir_l = DIR_FORWARD;
            g_giro_dir_r = DIR_REVERSE;
            g_state = STATE_EXECUTING;
            break;

        case MODE_PIVOT:
            // TODO: modo especial a definir. Por seguridad, detener.
            stop_all_motors();
            g_mode = MODE_STOP;
            g_state = STATE_IDLE;
            break;

        default:
            stop_all_motors();
            g_mode = MODE_STOP;
            g_state = STATE_ERROR;
            break;
    }
}

// =====================================================
// CONTROL POR CICLO
// =====================================================
static void control_step(float dt_s)
{
    int64_t cl = encoder_read(enc_l_unit, &enc_l_accum, ENC_L_SIGN);
    int64_t cr = encoder_read(enc_r_unit, &enc_r_accum, ENC_R_SIGN);

    float pv_l = 0.0f, pv_r = 0.0f;
    measure_rpm(&wl, cl, dt_s, &pv_l);
    measure_rpm(&wr, cr, dt_s, &pv_r);

    switch (g_mode) {

        case MODE_ADELANTE:
        case MODE_ATRAS: {
            int32_t dir = (g_mode == MODE_ADELANTE) ? DIR_FORWARD : DIR_REVERSE;
            float dir_sign = (g_mode == MODE_ADELANTE) ? 1.0f : -1.0f;

            // Distancia recorrida en la direccion comandada (cuentas, positivas si avanza bien)
            float dist_l = (float)(cl - g_start_counts_l) * dir_sign;
            float dist_r = (float)(cr - g_start_counts_r) * dir_sign;

            // Correccion de rumbo por diferencia de cuentas acumuladas
            float error_rumbo = dist_l - dist_r;
            g_feedback = (int32_t)error_rumbo;
            float corr = HEADING_KP * error_rumbo;
            if (corr >  HEADING_CORR_MAX) corr =  HEADING_CORR_MAX;
            if (corr < -HEADING_CORR_MAX) corr = -HEADING_CORR_MAX;

            // Rampa de setpoint: la RPM base sube gradualmente hacia el objetivo
            float base_target = (float)g_param;
            if (base_target > MAX_RPM) base_target = MAX_RPM;
            float ramp_step = RPM_ACCEL * dt_s;
            if (g_base_ramp < base_target) {
                g_base_ramp += ramp_step;
                if (g_base_ramp > base_target) g_base_ramp = base_target;
            } else if (g_base_ramp > base_target) {
                g_base_ramp -= ramp_step;
                if (g_base_ramp < base_target) g_base_ramp = base_target;
            }
            float base = g_base_ramp;

            float sp_l = base - corr;
            float sp_r = base + corr;
            if (sp_l < 0.0f) sp_l = 0.0f;
            if (sp_r < 0.0f) sp_r = 0.0f;
            if (sp_l > MAX_RPM) sp_l = MAX_RPM;
            if (sp_r > MAX_RPM) sp_r = MAX_RPM;

            int32_t pwm_l = vel_pid_step(&wl, sp_l, pv_l, dt_s);
            int32_t pwm_r = vel_pid_step(&wr, sp_r, pv_r, dt_s);

            // Arranque suave: limitar la variacion del PWM por ciclo.
            // Sin writeback a cv1: el PID incremental no integra error sostenido
            // (solo reacciona a cambios), asi que no genera windup.
            int32_t dl, dr;
            int32_t out_l = slew_pwm(&wl, (dir == DIR_FORWARD) ? (float)pwm_l : -(float)pwm_l, dt_s, &dl);
            int32_t out_r = slew_pwm(&wr, (dir == DIR_FORWARD) ? (float)pwm_r : -(float)pwm_r, dt_s, &dr);

            apply_motor_command(dl, out_l, dr, out_r);
            break;
        }

        case MODE_GIRO_IZQ:
        case MODE_GIRO_DER: {
            // Progreso angular del robot: promedio de cuentas giradas por ambas ruedas
            float dl_cnt = fabsf((float)(cl - g_start_counts_l));
            float dr_cnt = fabsf((float)(cr - g_start_counts_r));
            float prog_deg = ((dl_cnt + dr_cnt) * 0.5f) / CUENTAS_POR_GRADO_PIVOT;
            float remaining = (float)g_param - prog_deg;
            g_feedback = (int32_t)prog_deg;   // grados completados

            // Giro completo: frenar y reportar
            if (remaining <= GIRO_TOL_DEG) {
                stop_all_motors();
                wl.last_pwm_signed = 0.0f;
                wr.last_pwm_signed = 0.0f;
                publish_status_now(g_cmd_id, STATE_DONE,
                                   (int32_t)wl.rpm, (int32_t)wr.rpm, g_param);
                g_mode  = MODE_STOP;
                g_state = STATE_IDLE;
                break;
            }

            // Setpoint de velocidad de giro con taper de desaceleracion al final
            float sp_turn = GIRO_RPM;
            if (remaining < GIRO_DECEL_DEG) {
                sp_turn = GIRO_RPM_MIN + (GIRO_RPM - GIRO_RPM_MIN) * (remaining / GIRO_DECEL_DEG);
            }

            // Rampa de arranque suave hacia el setpoint (sube y baja)
            float ramp_step = RPM_ACCEL * dt_s;
            if (g_base_ramp < sp_turn) {
                g_base_ramp += ramp_step;
                if (g_base_ramp > sp_turn) g_base_ramp = sp_turn;
            } else if (g_base_ramp > sp_turn) {
                g_base_ramp -= ramp_step;
                if (g_base_ramp < sp_turn) g_base_ramp = sp_turn;
            }
            float sp = g_base_ramp;

            // PID de velocidad por rueda (regula la velocidad; aplica el PWM que
            // haga falta hasta 255 para mantenerla contra la carga)
            int32_t pwm_l = vel_pid_step(&wl, sp, pv_l, dt_s);
            int32_t pwm_r = vel_pid_step(&wr, sp, pv_r, dt_s);

            // Slew + direccion de giro de cada rueda
            int32_t dl, dr;
            int32_t out_l = slew_pwm(&wl, (g_giro_dir_l == DIR_FORWARD) ? (float)pwm_l : -(float)pwm_l, dt_s, &dl);
            int32_t out_r = slew_pwm(&wr, (g_giro_dir_r == DIR_FORWARD) ? (float)pwm_r : -(float)pwm_r, dt_s, &dr);

            apply_motor_command(dl, out_l, dr, out_r);
            break;
        }

        case MODE_STOP:
        default:
            stop_all_motors();
            break;
    }
}

// =====================================================
// VALIDACION
// =====================================================
static bool is_valid_mode(int32_t m)
{
    return (m >= MODE_STOP && m <= MODE_PIVOT);
}

static bool is_valid_onoff(int32_t v)
{
    return (v == 0 || v == 1);
}

// =====================================================
// CALLBACK DE COMANDOS — siempre atento
// =====================================================
static void motion_cmd_callback(const void * msgin)
{
    const std_msgs__msg__Int32MultiArray * msg = (const std_msgs__msg__Int32MultiArray *)msgin;

    if (msg == NULL || msg->data.size < CMD_LEN) {
        publish_status_now(-1, STATE_ERROR, 0, 0, 0);
        return;
    }

    int32_t cmd_id        = msg->data.data[0];
    int32_t mode          = msg->data.data[1];
    int32_t param         = msg->data.data[2];
    int32_t bordeadora_on = msg->data.data[3];
    int32_t cortadora_on  = msg->data.data[4];

    if (!is_valid_mode(mode) || !is_valid_onoff(bordeadora_on) || !is_valid_onoff(cortadora_on)) {
        publish_status_now(cmd_id, STATE_ERROR, 0, 0, 0);
        return;
    }

    // Accesorios: se aplican siempre, independientemente del movimiento
    target_trimmer_state = bordeadora_on;
    gpio_set_level(CORTADORA_ENABLE_PIN, (uint32_t)cortadora_on);

    // Si la orden de movimiento es IDENTICA a la que ya se esta ejecutando
    // (mismo modo y param), no reiniciar el lazo de control: el comando solo
    // cambia accesorios. Asi se evita el "hipo" de marcha al, p.ej., prender
    // la cortadora mientras se avanza recto.
    if (mode == g_mode && param == g_param && g_state == STATE_EXECUTING) {
        g_cmd_id = cmd_id;   // actualizar el id para el feedback
        publish_status_now(cmd_id, STATE_EXECUTING,
                           (int32_t)wl.rpm, (int32_t)wr.rpm, 0);
        return;
    }

    // Cualquier comando nuevo reemplaza al actual de inmediato
    start_command(cmd_id, mode, param);

    // ACK del comando aceptado
    publish_status_now(cmd_id, (g_state == STATE_ERROR) ? STATE_ERROR : STATE_ACCEPTED, 0, 0, 0);
}

// =====================================================
// TAREA PRINCIPAL micro-ROS
// =====================================================
void micro_ros_task(void * arg)
{
    (void)arg;

    ESP_ERROR_CHECK(motor_hw_init());

    rcl_allocator_t allocator = rcl_get_default_allocator();
    rclc_support_t support;

    // Bucle de reintento de conexión con el agente micro-ROS (silencioso para no corromper UART0)
    while (1) {
        rcl_ret_t rc = rclc_support_init(&support, 0, NULL, &allocator);
        if (rc == RCL_RET_OK) {
            break;
        }
        vTaskDelay(1000 / portTICK_PERIOD_MS);
    }

    rcl_node_t node;
    RCCHECK(rclc_node_init_default(&node, "esp32_motor_node", "", &support));

    RCCHECK(rclc_publisher_init_default(
        &motion_status_publisher,
        &node,
        ROSIDL_GET_MSG_TYPE_SUPPORT(std_msgs, msg, Int32MultiArray),
        TOPIC_MOTION_STATUS
    ));

    RCCHECK(rclc_subscription_init_default(
        &motion_cmd_subscriber,
        &node,
        ROSIDL_GET_MSG_TYPE_SUPPORT(std_msgs, msg, Int32MultiArray),
        TOPIC_MOTION_CMD
    ));

    // Buffer de recepcion motion_cmd
    std_msgs__msg__Int32MultiArray__init(&motion_cmd_msg);
    motion_cmd_msg.layout.data_offset = 0;
    motion_cmd_msg.data.data = (int32_t *) malloc(CMD_LEN * sizeof(int32_t));
    if (motion_cmd_msg.data.data == NULL) {
        vTaskDelete(NULL);
    }
    motion_cmd_msg.data.size = CMD_LEN;
    motion_cmd_msg.data.capacity = CMD_LEN;
    for (size_t i = 0; i < CMD_LEN; i++) {
        motion_cmd_msg.data.data[i] = 0;
    }

    // Buffer de envio motion_status
    std_msgs__msg__Int32MultiArray__init(&motion_status_msg);
    motion_status_msg.layout.data_offset = 0;
    motion_status_msg.data.data = (int32_t *) malloc(STATUS_LEN * sizeof(int32_t));
    if (motion_status_msg.data.data == NULL) {
        vTaskDelete(NULL);
    }
    motion_status_msg.data.size = STATUS_LEN;
    motion_status_msg.data.capacity = STATUS_LEN;
    for (size_t i = 0; i < STATUS_LEN; i++) {
        motion_status_msg.data.data[i] = 0;
    }

    rclc_executor_t executor;
    RCCHECK(rclc_executor_init(&executor, &support.context, 1, &allocator));
    RCCHECK(rclc_executor_add_subscription(
        &executor,
        &motion_cmd_subscriber,
        &motion_cmd_msg,
        &motion_cmd_callback,
        ON_NEW_DATA
    ));

    publish_status_now(0, STATE_IDLE, 0, 0, 0);

    const int64_t STATUS_PERIOD_MS  = 200;
    const int64_t IDLE_HEARTBEAT_MS = 1000;

    last_ctrl_tick_ms = esp_timer_get_time() / 1000LL;

    while (1) {
        // 1) Atender comandos entrantes (puede reemplazar el comando activo)
        rclc_executor_spin_some(&executor, RCL_MS_TO_NS(10));

        int64_t now_ms = esp_timer_get_time() / 1000LL;

        // 2) Rampa soft-start de la bordeadora (sin cambios)
        if (now_ms - last_trimmer_update_ms >= TRIMMER_RAMP_MS) {
            last_trimmer_update_ms = now_ms;

            if (target_trimmer_state == 1) {
                if (current_trimmer_speed == TRIMMER_SPEED_STOP) {
                    current_trimmer_speed = TRIMMER_SPEED_MIN_START;
                    uart_write_bytes(SABERTOOTH_UART_NUM, (const char[]){current_trimmer_speed}, 1);
                } else if (current_trimmer_speed < TRIMMER_SPEED_MAX) {
                    current_trimmer_speed += TRIMMER_RAMP_STEP;
                    if (current_trimmer_speed > TRIMMER_SPEED_MAX) {
                        current_trimmer_speed = TRIMMER_SPEED_MAX;
                    }
                    uart_write_bytes(SABERTOOTH_UART_NUM, (const char[]){current_trimmer_speed}, 1);
                }
            } else {
                if (current_trimmer_speed != TRIMMER_SPEED_STOP) {
                    current_trimmer_speed = TRIMMER_SPEED_STOP;
                    uart_write_bytes(SABERTOOTH_UART_NUM, (const char[]){TRIMMER_SPEED_STOP}, 1);
                }
            }
        }

        // 3) Lazo de control de traccion (dt dinamico)
        int64_t dt_ms = now_ms - last_ctrl_tick_ms;
        if (dt_ms >= 10) {   // ~100 Hz max
            last_ctrl_tick_ms = now_ms;
            float dt_s = dt_ms / 1000.0f;
            if (dt_s > 0.3f) dt_s = 0.12f;   // clamp ante hipos del scheduler
            control_step(dt_s);
        }

        // 4) Publicacion de estado
        if (g_state == STATE_EXECUTING) {
            if ((now_ms - last_status_pub_ms) >= STATUS_PERIOD_MS) {
                // g_feedback lo actualiza control_step (recta: error_rumbo; giro: grados hechos)
                publish_status_now(g_cmd_id, STATE_EXECUTING,
                                   (int32_t)wl.rpm, (int32_t)wr.rpm, g_feedback);
            }
        } else {
            // IDLE: heartbeat
            if ((now_ms - last_status_pub_ms) >= IDLE_HEARTBEAT_MS) {
                publish_status_now(0, STATE_IDLE, 0, 0, 0);
            }
        }

        usleep(5000);
    }

    // No deberia llegar aca
    free(motion_cmd_msg.data.data);
    free(motion_status_msg.data.data);

    std_msgs__msg__Int32MultiArray__fini(&motion_cmd_msg);
    std_msgs__msg__Int32MultiArray__fini(&motion_status_msg);

    RCCHECK(rcl_subscription_fini(&motion_cmd_subscriber, &node));
    RCCHECK(rcl_publisher_fini(&motion_status_publisher, &node));
    RCCHECK(rcl_node_fini(&node));

    vTaskDelete(NULL);
}

void app_main(void)
{
#if defined(RMW_UXRCE_TRANSPORT_CUSTOM)
    rmw_uros_set_custom_transport(
        true,
        (void *) &uart_port,
        esp32_serial_open,
        esp32_serial_close,
        esp32_serial_write,
        esp32_serial_read
    );
#else
#error micro-ROS transports misconfigured
#endif

    xTaskCreate(
        micro_ros_task,
        "uros_motor_task",
        CONFIG_MICRO_ROS_APP_STACK,
        NULL,
        CONFIG_MICRO_ROS_APP_TASK_PRIO,
        NULL
    );
}
