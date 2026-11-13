//  Firmware ESP32 — Control de Motores con micro-ROS
//  Placa: ESP32 clasico (WROOM), pines de docs/pines.md §2
//         Banco de prueba: ESP32-S3 N16R8 con la placa 3 en el I2C 6/7, sin motores (bloque #if)
//  Driver de traccion: MC33926 (puente H, 4 canales LEDC)
//  Motores: Pololu 37Dx57L 100:1 12 V SIN encoder -> velocidad y distancia en lazo abierto calibrado
//  IMU: placa 3 (clon de MPU de 6 ejes, WHO_AM_I 0x75, I2C 0x68) -> rumbo y giros en lazo cerrado
//  Bordeadora: Sabertooth 2x25 v2, modo serial simplificado (UART2 TX, GPIO 17, 9600 baud)
//  Cortadora central: AMC CBE12A1C, habilitacion por GPIO 18 → P1-9 INHIBIT (active LOW)
//
//  Protocolo v4:
//      motion_cmd    = [cmd_id, modo, param, bordeadora_on, cortadora_on]
//      motion_status = [cmd_id, estado, pwm_izq, pwm_der, feedback,
//                       rumbo, rumbo_obj, imu_estado, seg_desde_cal]
//      rumbo y rumbo_obj en decimas de grado (-1800..1799), positivo = antihorario (izquierda)
//
//  Modos (motion_cmd[1]):
//      0 = STOP         param ignorado. Corta la traccion y publica DONE a los 0,5 s
//      1 = ADELANTE     param = velocidad [cm/s], continuo, sostiene rumbo_obj con el giroscopio
//      2 = ATRAS        param = velocidad [cm/s], continuo, sostiene rumbo_obj
//      3 = GIRO_IZQ     param = grados: rumbo_obj += param, giro en el lugar
//      4 = GIRO_DER     param = grados: rumbo_obj -= param, giro en el lugar
//      5 = PIVOT        param = cm a avanzar (0 → 30): accesorios ON, adelante param cm,
//                       atras 28 cm, swing 90° izq sobre la rueda izq (rumbo_obj += 90)
//      6 = CALIBRAR     param = segundos de ventana (0 → 5). Traccion quieta, DONE al aceptar
//      7 = FIJAR_RUMBO  param = grados: el rumbo actual pasa a valer param (no corta el movimiento)
//
//  Descripcion:
//      Recibe comandos de alto nivel del Brain (ROS 2) por micro-ROS serial (UART0).
//      Sin encoders, el control se reparte asi:
//        - Velocidad y distancia: lazo abierto, PWM = PWM_ARRANQUE + v / CM_S_POR_PWM
//          (constantes a calibrar en piso). Las distancias del PIVOT se estiman integrando v.
//        - Rumbo y giros: lazo cerrado con el giroscopio. Una tarea propia lee el IMU a 125 Hz e
//          integra la velocidad de giro alrededor de la vertical (compensa la inclinacion).
//          En recta, un PI sobre el error de rumbo corrige la diferencia de velocidad entre ruedas.
//          En giro, un PI sobre la velocidad angular aplica el empuje que haga falta bajo carga.
//        - rumbo_obj es absoluto: un giro completo lo deja exacto en el objetivo y la recta
//          siguiente corrige el sobregiro. Si un giro se interrumpe, rumbo_obj pasa a ser el rumbo
//          actual. Si al arrancar un movimiento el error supera 10° (robot movido a mano), tambien.
//        - Recalibracion del bias del giroscopio en cada parada: con la traccion quieta 1 s y el
//          giro sin bias < 1 dps, ventanas de 5 s con rechazo por ruido, tendencia y salto
//          (pruebas de banco del 02/11/26, docs/pruebas.md §3).
//      Controla la bordeadora (rampa soft-start anti-cogging, Sabertooth serial).
//      Controla la cortadora central brushless (GPIO 18 HIGH = habilitado, LOW = inhibido).
//      El ESP esta SIEMPRE atento: cualquier comando nuevo reemplaza al actual de inmediato.
//      Un comando rechazado corta la traccion y publica ERROR con el codigo en feedback.
//
//  Version: 4.0
//  Autor: Angel Alegre
//  Ultima verificacion: 02/11/2026 (compilacion; falta prueba en hardware)

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
#include "driver/i2c.h"
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

// La tarea del IMU consulta el dato nuevo cada 1 ms
#if CONFIG_FREERTOS_HZ < 1000
#error "El IMU necesita CONFIG_FREERTOS_HZ=1000 (sdkconfig.defaults). Correr idf.py fullclean y compilar de nuevo"
#endif

// =====================================================
// PINES
// =====================================================
#if CONFIG_IDF_TARGET_ESP32S3
// Banco de prueba: ESP32-S3 N16R8 con la placa 3 en el I2C 6/7, sin motores conectados
#define M1_IN1_PIN   GPIO_NUM_4
#define M1_IN2_PIN   GPIO_NUM_5
#define M2_IN1_PIN   GPIO_NUM_15
#define M2_IN2_PIN   GPIO_NUM_16
#define IMU_SDA_PIN  GPIO_NUM_6
#define IMU_SCL_PIN  GPIO_NUM_7
#else
// ESP32 clasico (docs/pines.md §2)
// Izquierda (M1)
#define M1_IN1_PIN   GPIO_NUM_32
#define M1_IN2_PIN   GPIO_NUM_33
// Derecha (M2)
#define M2_IN1_PIN   GPIO_NUM_25
#define M2_IN2_PIN   GPIO_NUM_26
#define IMU_SDA_PIN  GPIO_NUM_21
#define IMU_SCL_PIN  GPIO_NUM_22
#endif

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
// MODELO DE LAZO ABIERTO (velocidad → PWM) — CALIBRAR EN PISO
// =====================================================
// Estimado de la hoja de datos: 100 rpm a 12 V sin carga, bateria 4S (14,8 V), PWM 180 → 10,4 V
// → 87 rpm → 68 cm/s con la rueda de R = 7,5 cm; -15 % por carga → ~58 cm/s.
// Calibracion: ADELANTE a una velocidad durante 5 s, medir la distancia con cinta y ajustar
// CM_S_POR_PWM; PWM_ARRANQUE es el PWM con el que la rueda empieza a moverse en el piso.
#define PWM_MAX_TRACCION   180.0f   // tope decidido (≈180/255)
#define PWM_ARRANQUE       20.0f    // PWM minimo con el que la rueda empieza a moverse
#define CM_S_POR_PWM       0.36f    // pendiente de la velocidad por encima del arranque
#define VEL_MAX_CM_S       ((PWM_MAX_TRACCION - PWM_ARRANQUE) * CM_S_POR_PWM)   // ≈ 57 cm/s
#define VEL_MIN_CM_S       0.5f     // por debajo, la rueda se apaga
#define ACCEL_CM_S2        25.0f    // rampa de velocidad en recta (v3: 30 RPM/s = 23,6 cm/s²)

#define L_RUEDAS_CM        50.0f    // distancia entre ruedas, centro a centro
#define DEG_A_RAD          0.01745329252f

// =====================================================
// ARRANQUE SUAVE — limitador de slew del PWM (anti-patada)
// =====================================================
// Maxima variacion del PWM por segundo. Subir = arranca mas brusco.
// #define PWM_SLEW_RATE   1200.0f   // pasto moderado
#define PWM_SLEW_RATE   600.0f    // piso liso: 0->180 en ~0.3s

// =====================================================
// RUMBO EN RECTA — PI sobre el error de rumbo (giroscopio)
// =====================================================
// La correccion es una diferencia de velocidad entre ruedas [cm/s]: +corr = gira a la izquierda.
// Con KP = 0,45 el error se corrige con una constante de tiempo de ~1 s (2·KP/L·57,3 ≈ 1/s).
#define RUMBO_KP             0.45f   // cm/s por grado de error
#define RUMBO_KI             0.10f   // cm/s por grado·s (corrige la asimetria entre motores)
#define RUMBO_KD             0.05f   // cm/s por dps (amortigua con la velocidad de giro medida)
#define RUMBO_CORR_MAX_CM_S  8.0f    // tope de la correccion (nunca mayor a la velocidad base)
#define RUMBO_REANCLAJE_DEG  10.0f   // error mayor al arrancar → rumbo_obj = rumbo actual

// =====================================================
// GIRO — PI sobre la velocidad angular (giroscopio)
// =====================================================
// Perfil: rampa hasta la velocidad de crucero y desaceleracion en los ultimos grados.
// El PWM = adelanto del modelo + PI; el PI empuja mas si la carga frena el giro (pasto).
#define GIRO_W_DPS          36.0f   // crucero en el lugar (v3: 20 RPM por rueda = 36 °/s)
#define SWING_W_DPS         18.0f   // crucero del swing del PIVOT (v3: rueda der a 20 RPM)
#define GIRO_W_MIN_DPS      8.0f    // velocidad en la aproximacion final
#define GIRO_DECEL_DEG      15.0f   // grados antes del objetivo donde empieza a desacelerar
#define GIRO_ACCEL_DPS2     60.0f   // rampa de arranque del giro
#define GIRO_TOL_DEG        1.0f    // tolerancia para cortar los motores
#define GIRO_KP_W           1.0f    // PWM por dps de error de velocidad angular
#define GIRO_KI_W           2.0f    // PWM por dps·s
#define GIRO_EXTRA_MAX_PWM  80.0f   // tope del empuje del PI sobre el adelanto
#define GIRO_TIMEOUT_BASE_MS 3000   // tiempo maximo = base + grados a la mitad del crucero
// Asentado al final del giro: los motores cortan y se sigue integrando la inercia
#define ASENTAR_W_DPS       2.0f
#define ASENTAR_QUIETO_MS   300
#define ASENTAR_MAX_MS      1500
#define STOP_ASENTAR_MS     500     // STOP publica DONE despues de este tiempo

// =====================================================
// MODO PIVOT (5) — secuencia: adelante param cm + atras 28 cm + swing 90° rueda izq fija
// =====================================================
// Geometria del robot: H=40 cm (eje→frente), L=50 cm (entre ruedas).
// Al girar 90° CCW sobre la rueda izq, la esquina delantera-derecha traza un arco de radio
// sqrt(L²+H²) = 64 cm. La maxima Y alcanzada = 64 cm desde el pivote.
// d_min = 64 - 40 = 24 cm para no chocar el borde norte; se usa 28 cm por margen real.
// Sin encoders, las distancias se estiman integrando la velocidad comandada (calibrar).
#define PIVOT_ADELANTE_CM_DEFAULT 30.0f  // distancia de avance por defecto si param=0
#define PIVOT_ATRAS_CM            28.0f  // retroceso geometrico fijo (d_min=24 cm + 4 cm)
#define PIVOT_DECEL_CM            5.0f   // zona de desaceleracion al acercarse al objetivo
#define PIVOT_GIRO_DEG            90.0f  // angulo del swing
#define PIVOT_VEL_CM_S            23.6f  // avance/retroceso (v3: 30 RPM)
#define PIVOT_VEL_MIN_CM_S        6.0f

// =====================================================
// IMU — placa 3 (clon de MPU de 6 ejes)
// =====================================================
#define I2C_MASTER_NUM      I2C_NUM_0
#define I2C_MASTER_FREQ_HZ  100000
#define I2C_TIMEOUT         pdMS_TO_TICKS(50)

#define MPU_ADDR_AD0_0      0x68
#define MPU_ADDR_AD0_1      0x69
#define MPU_SMPLRT_DIV      0x19
#define MPU_CONFIG          0x1A
#define MPU_GYRO_CONFIG     0x1B
#define MPU_ACCEL_CONFIG    0x1C
#define MPU_ACCEL_CONFIG2   0x1D
#define MPU_INT_PIN_CFG     0x37
#define MPU_INT_ENABLE      0x38
#define MPU_INT_STATUS      0x3A    // bit0 RAW_DATA_RDY (se borra al leerlo)
#define MPU_ACCEL_XOUT_H    0x3B    // 14 bytes big-endian: acel (6), temp (2), giro (6)
#define MPU_USER_CTRL       0x6A
#define MPU_PWR_MGMT_1      0x6B
#define MPU_PWR_MGMT_2      0x6C
#define MPU_WHO_AM_I        0x75

#define CFG_USER_CTRL       0x00
#define CFG_PWR_MGMT_1      0x01    // reloj PLL del giroscopo, sin sleep
#define CFG_PWR_MGMT_2      0x00    // todos los ejes habilitados
#define CFG_SMPLRT_DIV      0x07    // 1 kHz / (1 + 7) = 125 Hz
#define CFG_CONFIG          0x03    // filtro del giro: 41 Hz
#define CFG_GYRO_CONFIG     0x00    // +-250 dps (el robot gira a ~36 °/s)
#define CFG_ACCEL_CONFIG    0x08    // +-4 g
#define CFG_ACCEL_CONFIG2   0x03    // filtro del acel: 41 Hz
#define CFG_INT_PIN_CFG     0x00
#define CFG_INT_ENABLE      0x01    // RAW_RDY_EN

#define GYRO_SENS_DPS       (1.0f / 131.0f)     // +-250 dps -> 131 LSB/dps
#define ACC_SENS_G          (1.0f / 8192.0f)    // +-4 g     -> 8192 LSB/g

#define IMU_TIMEOUT_US      250000  // sin muestras nuevas → falla, se reintenta cada 1 s
#define IMU_DT_MAX_S        0.1f    // hueco maximo que se integra
#define IMU_ESPERA_MS       6       // tras leer una muestra (la siguiente llega a los 8 ms)

// Recalibracion en las paradas (afinado 02/11/26, docs/pruebas.md §3)
#define RECAL_S                 5           // ventana: p95 del error a 60 s de 0,34-0,46°
#define RECAL_QUIETO_DPS        1.0f        // giro sin bias por debajo de esto en los 3 ejes...
#define RECAL_QUIETO_PREVIO_US  1000000     // ...durante este tiempo antes de calibrar
#define RECAL_ESPERA_MAX_MS     10000       // CALIBRAR: tiempo extra para quedar quieto
#define RECAL_RUIDO_MAX_DPS     0.5f
#define RECAL_TENDENCIA_MAX_DPS 0.015f      // ~3 sigma de la diferencia entre mitades de 2,5 s
#define RECAL_SALTO_MAX_DPS     0.03f       // el bias normal cambia ~0,002-0,013 dps en minutos
#define RECAL_CAMBIO_ACEL_G     0.03f       // cambio de gravedad (~1,7°) = otra inclinacion

// =====================================================
// TOPICOS
// =====================================================
static const char * TOPIC_MOTION_CMD    = "motion_cmd";
static const char * TOPIC_MOTION_STATUS = "motion_status";

// =====================================================
// PROTOCOLO
// motion_cmd    = [cmd_id, modo, param, bordeadora_on, cortadora_on]
// motion_status = [cmd_id, estado, pwm_izq, pwm_der, feedback, rumbo, rumbo_obj, imu_estado, seg_desde_cal]
// =====================================================
#define CMD_LEN     5
#define STATUS_LEN  9

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
// MODOS, ESTADOS Y CODIGOS
// =====================================================
enum MotionMode {
    MODE_STOP        = 0,
    MODE_ADELANTE    = 1,
    MODE_ATRAS       = 2,
    MODE_GIRO_IZQ    = 3,
    MODE_GIRO_DER    = 4,
    MODE_PIVOT       = 5,
    MODE_CALIBRAR    = 6,
    MODE_FIJAR_RUMBO = 7
};

enum MotionState {
    STATE_IDLE      = 0,
    STATE_ACCEPTED  = 1,
    STATE_EXECUTING = 2,
    STATE_DONE      = 3,   // comando finalizado
    STATE_ABORTED   = 4,   // reemplazado por otro comando antes de terminar
    STATE_ERROR     = 5    // codigo en feedback (CodigoError)
};

enum CodigoError {
    ERR_COMANDO       = 1,   // mal formado o parametro fuera de rango
    ERR_IMU           = 2,   // IMU con falla o sin calibrar (modos que lo necesitan)
    ERR_GIRO_TIEMPO   = 3,   // el giro no llego al objetivo a tiempo (trabado)
    ERR_CAL_QUIETO    = 4,   // CALIBRAR: el robot no quedo quieto a tiempo
    ERR_CAL_RUIDO     = 5,   // ventana con ruido > 0,5 dps (se movio)
    ERR_CAL_TENDENCIA = 6,   // ventana con tendencia (movimiento lento)
    ERR_CAL_SALTO     = 7    // bias distinto al anterior sin cambiar la inclinacion
};

enum ImuEstado {
    IMU_FALLA        = 0,    // no responde o dejo de dar datos
    IMU_INICIANDO    = 1,    // primera calibracion en curso (robot quieto al encender)
    IMU_LISTO        = 2,
    IMU_RECALIBRANDO = 3     // ventana de recalibracion en curso (ya tiene bias)
};

enum PivotStep {
    PIVOT_STEP_ADELANTE = 0,   // avanzando N cm (param)
    PIVOT_STEP_ATRAS    = 1,   // retrocediendo 28 cm (geometrico)
    PIVOT_STEP_GIRO     = 2,   // swing 90° sobre rueda izq
};

enum SubFase {
    SUB_MOVIENDO  = 0,
    SUB_ASENTANDO = 1          // motores cortados, esperando que el giro se detenga
};

enum CalFase {
    CAL_ESPERA  = 0,
    CAL_VENTANA = 1
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
// IMU — estado compartido entre la tarea del IMU y el control
// =====================================================
typedef struct {
    int      estado;         // ImuEstado
    double   yaw;            // rumbo integrado [grados], continuo, + antihorario
    float    w;              // velocidad de giro alrededor de la vertical [dps]
    int64_t  t_cal_us;       // ultima calibracion aceptada (0 = nunca)
    uint32_t n_cal_ok;       // calibraciones aceptadas
    int      ult_rechazo;    // CodigoError de la ultima ventana rechazada
    float    bias_z;         // bias z de la ultima calibracion [dps]
    int      cal_dur_s;      // duracion de la ventana (CALIBRAR la cambia)
} imu_t;

static imu_t imu = { .estado = IMU_FALLA, .cal_dur_s = RECAL_S };
static portMUX_TYPE imu_mux = portMUX_INITIALIZER_UNLOCKED;
static volatile bool g_traccion_activa = false;    // control → IMU: no recalibrar
static volatile bool g_imu_reiniciar_ventana = false;
static uint8_t mpu_addr = 0;

// =====================================================
// ESTADO DEL CONTROL DE TRACCION
// =====================================================
// Comando activo
static int32_t g_cmd_id = 0;
static int32_t g_mode   = MODE_STOP;
static int32_t g_param  = 0;
static int32_t g_state  = STATE_IDLE;
static int32_t g_feedback = 0;

static float   g_pwm_l = 0.0f, g_pwm_r = 0.0f;   // ultimo PWM aplicado con signo (+ adelante)
static float   g_vel_ramp = 0.0f;   // velocidad de recta rampeada [cm/s]
static float   g_rumbo_int = 0.0f;  // integral del error de rumbo [grados·s]
static double  g_rumbo_obj = 0.0;   // rumbo objetivo [grados], continuo
static double  g_yaw_inicio = 0.0;  // rumbo al iniciar el giro
static float   g_w_ramp = 0.0f;     // velocidad angular rampeada [dps]
static float   g_w_int = 0.0f;      // integral del error de velocidad angular
static float   g_dist_cm = 0.0f;    // distancia estimada de la fase lineal del PIVOT
static int32_t g_pivot_step = PIVOT_STEP_ADELANTE;
static int32_t g_sub = SUB_MOVIENDO;
static int64_t g_t_inicio_ms = 0, g_t_sub_ms = 0, g_quieto_desde_ms = 0;
static int64_t g_timeout_ms = 0;
static uint32_t g_cal_ok_ref = 0;

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
    g_pwm_l = 0.0f;
    g_pwm_r = 0.0f;
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

    return ESP_OK;
}

// =====================================================
// IMU — acceso I2C (solo desde la tarea del IMU)
// =====================================================
static void imu_i2c_init(void)
{
    i2c_config_t i2c_c = {
        .mode = I2C_MODE_MASTER,
        .sda_io_num = IMU_SDA_PIN,
        .scl_io_num = IMU_SCL_PIN,
        .sda_pullup_en = GPIO_PULLUP_ENABLE,
        .scl_pullup_en = GPIO_PULLUP_ENABLE,
        .master.clk_speed = I2C_MASTER_FREQ_HZ
    };
    i2c_param_config(I2C_MASTER_NUM, &i2c_c);
    i2c_driver_install(I2C_MASTER_NUM, I2C_MODE_MASTER, 0, 0, 0);
}

static esp_err_t leer_regs(uint8_t dev, uint8_t reg, uint8_t *buf, size_t len)
{
    return i2c_master_write_read_device(I2C_MASTER_NUM, dev, &reg, 1, buf, len, I2C_TIMEOUT);
}

static esp_err_t escribir_reg(uint8_t dev, uint8_t reg, uint8_t val)
{
    uint8_t buf[2] = {reg, val};
    return i2c_master_write_to_device(I2C_MASTER_NUM, dev, buf, 2, I2C_TIMEOUT);
}

// Busca el MPU en 0x68 y 0x69 (cualquier WHO_AM_I: la placa 3 es un clon con 0x75)
static bool detectar_mpu(void)
{
    const uint8_t cand[2] = {MPU_ADDR_AD0_0, MPU_ADDR_AD0_1};
    for (int i = 0; i < 2; i++) {
        uint8_t id = 0;
        if (leer_regs(cand[i], MPU_WHO_AM_I, &id, 1) == ESP_OK && id != 0x00 && id != 0xFF) {
            mpu_addr = cand[i];
            return true;
        }
    }
    return false;
}

static bool configurar_mpu(void)
{
    escribir_reg(mpu_addr, MPU_PWR_MGMT_1, 0x80);   // reset por software
    vTaskDelay(pdMS_TO_TICKS(100));
    escribir_reg(mpu_addr, MPU_PWR_MGMT_1, CFG_PWR_MGMT_1);
    vTaskDelay(pdMS_TO_TICKS(50));

    const uint8_t cfg[][2] = {
        {MPU_USER_CTRL,     CFG_USER_CTRL},
        {MPU_PWR_MGMT_1,    CFG_PWR_MGMT_1},
        {MPU_PWR_MGMT_2,    CFG_PWR_MGMT_2},
        {MPU_SMPLRT_DIV,    CFG_SMPLRT_DIV},
        {MPU_CONFIG,        CFG_CONFIG},
        {MPU_GYRO_CONFIG,   CFG_GYRO_CONFIG},
        {MPU_ACCEL_CONFIG,  CFG_ACCEL_CONFIG},
        {MPU_ACCEL_CONFIG2, CFG_ACCEL_CONFIG2},
        {MPU_INT_PIN_CFG,   CFG_INT_PIN_CFG},
        {MPU_INT_ENABLE,    CFG_INT_ENABLE},
    };

    bool ok = true;
    for (size_t i = 0; i < sizeof(cfg) / sizeof(cfg[0]); i++) {
        uint8_t leido = 0;
        escribir_reg(mpu_addr, cfg[i][0], cfg[i][1]);
        if (leer_regs(mpu_addr, cfg[i][0], &leido, 1) != ESP_OK || leido != cfg[i][1]) {
            ok = false;
        }
    }
    vTaskDelay(pdMS_TO_TICKS(200));     // descartar las primeras muestras tras el reset
    return ok;
}

// true si hay dato nuevo (bit RAW_DATA_RDY) y se leyo bien: acel en g, giro en dps (con bias)
static bool leer_muestra(float acc[3], float giro[3])
{
    uint8_t st = 0, b[14];
    if (leer_regs(mpu_addr, MPU_INT_STATUS, &st, 1) != ESP_OK || !(st & 0x01)) return false;
    if (leer_regs(mpu_addr, MPU_ACCEL_XOUT_H, b, 14) != ESP_OK) return false;
    for (int i = 0; i < 3; i++) {
        acc[i]  = (int16_t)((b[2 * i] << 8) | b[2 * i + 1]) * ACC_SENS_G;
        giro[i] = (int16_t)((b[8 + 2 * i] << 8) | b[9 + 2 * i]) * GYRO_SENS_DPS;
    }
    return true;
}

static imu_t imu_leer(void)
{
    imu_t s;
    portENTER_CRITICAL(&imu_mux);
    s = imu;
    portEXIT_CRITICAL(&imu_mux);
    return s;
}

static bool imu_listo(const imu_t *s)
{
    return s->estado == IMU_LISTO || s->estado == IMU_RECALIBRANDO;
}

static void imu_fijar_ventana(int segundos)
{
    portENTER_CRITICAL(&imu_mux);
    imu.cal_dur_s = segundos;
    portEXIT_CRITICAL(&imu_mux);
}

// =====================================================
// IMU — tarea: lectura a 125 Hz, rumbo y recalibracion en las paradas
// =====================================================
static void imu_task(void *arg)
{
    (void)arg;

    float bias[3] = {0}, up[3] = {0, 0, 1};   // up: vertical en ejes del sensor (acelerometro)
    bool  cal_hecha = false;
    int   rechazos_salto = 0;
    bool  mpu_ok = false;
    int64_t t_ult = 0, t_reintento = 0;

    // Ventana de calibracion
    int     fase = CAL_ESPERA;
    int64_t quieto_desde = 0, t_ini = 0, dur_us = 0;
    double  s[3] = {0}, s2[3] = {0}, sa[3] = {0}, sw_mitad[2] = {0}, dyaw_ventana = 0.0;
    uint32_t n = 0, n_mitad[2] = {0};

    imu_i2c_init();

    while (1) {
        int64_t ahora = esp_timer_get_time();

        // Deteccion y configuracion (al arrancar y cada 1 s mientras falle)
        if (!mpu_ok) {
            if (ahora >= t_reintento) {
                mpu_ok = detectar_mpu() && configurar_mpu();
                t_reintento = ahora + 1000000;
                t_ult = quieto_desde = esp_timer_get_time();
                fase = CAL_ESPERA;
            }
            if (!mpu_ok) {
                portENTER_CRITICAL(&imu_mux);
                imu.estado = IMU_FALLA;
                imu.w = 0.0f;
                portEXIT_CRITICAL(&imu_mux);
                vTaskDelay(pdMS_TO_TICKS(10));
                continue;
            }
        }

        float a[3], g[3];
        if (!leer_muestra(a, g)) {
            if (ahora - t_ult > IMU_TIMEOUT_US) {
                mpu_ok = false;     // el MPU no responde o se reseteo (queda en sleep)
            }
            vTaskDelay(1);
            continue;
        }

        ahora = esp_timer_get_time();
        float dt = (ahora - t_ult) * 1e-6f;
        t_ult = ahora;
        if (dt > IMU_DT_MAX_S) dt = IMU_DT_MAX_S;

        // Velocidad de giro alrededor de la vertical (compensa la inclinacion del montaje y el terreno)
        float w = 0.0f;
        if (cal_hecha) {
            w = (g[0] - bias[0]) * up[0] + (g[1] - bias[1]) * up[1] + (g[2] - bias[2]) * up[2];
        }

        // ---- Recalibracion en las paradas ----
        double corr_yaw = 0.0;
        int rechazo = 0;
        bool aceptada = false;
        int dur_s = RECAL_S;

        bool quieto = true;
        if (cal_hecha) {
            for (int i = 0; i < 3; i++) {
                if (fabsf(g[i] - bias[i]) > RECAL_QUIETO_DPS) quieto = false;
            }
        }

        if (g_traccion_activa || !quieto) {
            if (fase == CAL_VENTANA) rechazo = ERR_CAL_QUIETO;
            fase = CAL_ESPERA;
            quieto_desde = ahora;
        } else if (g_imu_reiniciar_ventana) {
            // CALIBRAR: empezar una ventana nueva con la duracion pedida
            g_imu_reiniciar_ventana = false;
            fase = CAL_ESPERA;
        }

        if (fase == CAL_ESPERA && !g_traccion_activa && quieto
            && ahora - quieto_desde >= RECAL_QUIETO_PREVIO_US) {
            portENTER_CRITICAL(&imu_mux);
            dur_s = imu.cal_dur_s;
            portEXIT_CRITICAL(&imu_mux);
            fase = CAL_VENTANA;
            t_ini = ahora;
            dur_us = (int64_t)dur_s * 1000000;
            memset(s, 0, sizeof(s));
            memset(s2, 0, sizeof(s2));
            memset(sa, 0, sizeof(sa));
            sw_mitad[0] = sw_mitad[1] = 0.0;
            n_mitad[0] = n_mitad[1] = 0;
            n = 0;
            dyaw_ventana = 0.0;
        }

        if (fase == CAL_VENTANA) {
            int mitad = (ahora - t_ini) * 2 >= dur_us;
            for (int i = 0; i < 3; i++) {
                s[i] += g[i];
                s2[i] += (double)g[i] * g[i];
                sa[i] += a[i];
            }
            sw_mitad[mitad] += g[0] * up[0] + g[1] * up[1] + g[2] * up[2];
            n_mitad[mitad]++;
            n++;
            dyaw_ventana += w * dt;

            if (ahora - t_ini >= dur_us && n >= 10 && n_mitad[0] > 0 && n_mitad[1] > 0) {
                float b[3], ruido = 0.0f, am[3];
                for (int i = 0; i < 3; i++) {
                    b[i] = s[i] / n;
                    double var = s2[i] / n - (double)b[i] * b[i];
                    float r = var > 0 ? (float)sqrt(var) : 0.0f;
                    if (r > ruido) ruido = r;
                    am[i] = sa[i] / n;
                }
                float a_mod = sqrtf(am[0] * am[0] + am[1] * am[1] + am[2] * am[2]);
                float tendencia = sw_mitad[1] / n_mitad[1] - sw_mitad[0] / n_mitad[0];
                float salto = (b[0] - bias[0]) * up[0] + (b[1] - bias[1]) * up[1] + (b[2] - bias[2]) * up[2];
                float da = sqrtf((am[0] - up[0] * a_mod) * (am[0] - up[0] * a_mod)
                                 + (am[1] - up[1] * a_mod) * (am[1] - up[1] * a_mod)
                                 + (am[2] - up[2] * a_mod) * (am[2] - up[2] * a_mod));

                if (ruido > RECAL_RUIDO_MAX_DPS || a_mod < 0.5f) {
                    rechazo = ERR_CAL_RUIDO;
                } else if (cal_hecha && fabsf(tendencia) > RECAL_TENDENCIA_MAX_DPS) {
                    rechazo = ERR_CAL_TENDENCIA;
                } else if (cal_hecha && da <= RECAL_CAMBIO_ACEL_G && fabsf(salto) > RECAL_SALTO_MAX_DPS
                           && rechazos_salto++ == 0) {
                    // Se acepta al segundo rechazo seguido, por si el bias cambio de verdad
                    rechazo = ERR_CAL_SALTO;
                } else {
                    aceptada = true;
                    rechazos_salto = 0;
                    // El robot estuvo quieto: lo que se integro en la ventana era error del bias viejo
                    if (cal_hecha) corr_yaw = dyaw_ventana;
                    for (int i = 0; i < 3; i++) {
                        bias[i] = b[i];
                        up[i] = am[i] / a_mod;
                    }
                    cal_hecha = true;
                }
                // Ventana siguiente enseguida si sigue quieto
                fase = CAL_ESPERA;
                quieto_desde = ahora - RECAL_QUIETO_PREVIO_US;
            }
        }

        portENTER_CRITICAL(&imu_mux);
        imu.yaw += (double)w * dt - corr_yaw;
        imu.w = w;
        if (aceptada) {
            imu.t_cal_us = ahora;
            imu.n_cal_ok++;
            imu.bias_z = bias[2];
        }
        if (rechazo) imu.ult_rechazo = rechazo;
        imu.estado = !cal_hecha ? IMU_INICIANDO : (fase == CAL_VENTANA ? IMU_RECALIBRANDO : IMU_LISTO);
        portEXIT_CRITICAL(&imu_mux);

        vTaskDelay(pdMS_TO_TICKS(IMU_ESPERA_MS));
    }
}

// =====================================================
// STATUS
// =====================================================
static int32_t decimas_envueltas(double grados)
{
    double a = fmod(grados + 180.0, 360.0);
    if (a < 0.0) a += 360.0;
    return (int32_t)lround((a - 180.0) * 10.0);
}

static void publish_status_now(int32_t cmd_id, int32_t estado, int32_t feedback)
{
    imu_t s = imu_leer();
    int64_t ahora_us = esp_timer_get_time();

    motion_status_msg.data.data[0] = cmd_id;
    motion_status_msg.data.data[1] = estado;
    motion_status_msg.data.data[2] = (int32_t)lroundf(g_pwm_l);
    motion_status_msg.data.data[3] = (int32_t)lroundf(g_pwm_r);
    motion_status_msg.data.data[4] = feedback;
    motion_status_msg.data.data[5] = decimas_envueltas(s.yaw);
    motion_status_msg.data.data[6] = decimas_envueltas(g_rumbo_obj);
    motion_status_msg.data.data[7] = s.estado;
    motion_status_msg.data.data[8] = s.t_cal_us ? (int32_t)((ahora_us - s.t_cal_us) / 1000000LL) : -1;
    RCSOFTCHECK(rcl_publish(&motion_status_publisher, &motion_status_msg, NULL));
    last_status_pub_ms = ahora_us / 1000LL;
}

// =====================================================
// CONTROL: salida a las ruedas
// =====================================================
// Velocidad de rueda con signo [cm/s] → PWM con signo, por el modelo de lazo abierto
static float pwm_de_vel(float v)
{
    if (fabsf(v) < VEL_MIN_CM_S) return 0.0f;
    float p = PWM_ARRANQUE + fabsf(v) / CM_S_POR_PWM;
    if (p > PWM_MAX_TRACCION) p = PWM_MAX_TRACCION;
    return (v > 0.0f) ? p : -p;
}

// Limitador de slew por rueda (anti-patada) y salida al MC33926
static float slew(float actual, float deseado, float dt_s)
{
    float maxstep = PWM_SLEW_RATE * dt_s;
    float delta = deseado - actual;
    if (delta >  maxstep) delta =  maxstep;
    if (delta < -maxstep) delta = -maxstep;
    float r = actual + delta;
    if (r >  PWM_MAX_TRACCION) r =  PWM_MAX_TRACCION;
    if (r < -PWM_MAX_TRACCION) r = -PWM_MAX_TRACCION;
    return r;
}

static void aplicar_pwm(float pwm_l, float pwm_r, float dt_s)
{
    g_pwm_l = slew(g_pwm_l, pwm_l, dt_s);
    g_pwm_r = slew(g_pwm_r, pwm_r, dt_s);
    apply_motor_command(g_pwm_l >= 0.0f ? DIR_FORWARD : DIR_REVERSE, (int32_t)lroundf(fabsf(g_pwm_l)),
                        g_pwm_r >= 0.0f ? DIR_FORWARD : DIR_REVERSE, (int32_t)lroundf(fabsf(g_pwm_r)));
}

// Rampa hacia el objetivo: sube con la aceleracion dada, baja de inmediato (el slew suaviza)
static float rampa(float actual, float objetivo, float accel, float dt_s)
{
    if (actual < objetivo) {
        actual += accel * dt_s;
        if (actual > objetivo) actual = objetivo;
    } else {
        actual = objetivo;
    }
    return actual;
}

// =====================================================
// CONTROL: recta con rumbo sostenido (ADELANTE, ATRAS y fases lineales del PIVOT)
// =====================================================
// sentido +1 adelante, -1 atras; vel_obj en cm/s (magnitud)
static void control_recta(float sentido, float vel_obj, const imu_t *s, float dt_s)
{
    if (vel_obj > VEL_MAX_CM_S) vel_obj = VEL_MAX_CM_S;
    g_vel_ramp = rampa(g_vel_ramp, vel_obj, ACCEL_CM_S2, dt_s);

    float corr = 0.0f;
    if (imu_listo(s)) {
        float e = (float)(g_rumbo_obj - s->yaw);
        g_rumbo_int += e * dt_s;
        float int_max = RUMBO_CORR_MAX_CM_S / RUMBO_KI;
        if (g_rumbo_int >  int_max) g_rumbo_int =  int_max;
        if (g_rumbo_int < -int_max) g_rumbo_int = -int_max;
        corr = RUMBO_KP * e + RUMBO_KI * g_rumbo_int - RUMBO_KD * s->w;
        if (g_mode != MODE_PIVOT) g_feedback = (int32_t)lroundf(e * 10.0f);
    }
    // Ninguna rueda invierte en recta
    float lim = fminf(RUMBO_CORR_MAX_CM_S, g_vel_ramp);
    if (corr >  lim) corr =  lim;
    if (corr < -lim) corr = -lim;

    // +corr → rueda der mas rapida que la izq → gira a la izquierda (en los dos sentidos)
    aplicar_pwm(pwm_de_vel(sentido * g_vel_ramp - corr), pwm_de_vel(sentido * g_vel_ramp + corr), dt_s);
    g_dist_cm += g_vel_ramp * dt_s;
}

// =====================================================
// CONTROL: giro hacia g_rumbo_obj con lazo de velocidad angular
// =====================================================
// dir +1 izquierda (antihorario), -1 derecha. swing = solo avanza la rueda der (PIVOT).
// Devuelve true al llegar (motores cortados).
static bool control_giro(float dir, bool swing, float w_crucero, const imu_t *s, float dt_s)
{
    float restante = dir * (float)(g_rumbo_obj - s->yaw);
    g_feedback = (int32_t)lround(dir * (s->yaw - g_yaw_inicio) * 10.0);

    if (restante <= GIRO_TOL_DEG) {
        stop_all_motors();
        return true;
    }

    float w_obj = w_crucero;
    if (restante < GIRO_DECEL_DEG) {
        w_obj = GIRO_W_MIN_DPS + (w_crucero - GIRO_W_MIN_DPS) * (restante / GIRO_DECEL_DEG);
    }
    g_w_ramp = rampa(g_w_ramp, w_obj, GIRO_ACCEL_DPS2, dt_s);

    // PI sobre la velocidad angular medida en el sentido del giro
    float err = g_w_ramp - dir * s->w;
    g_w_int += err * dt_s;
    float int_max = GIRO_EXTRA_MAX_PWM / GIRO_KI_W;
    if (g_w_int >  int_max) g_w_int =  int_max;
    if (g_w_int < -int_max) g_w_int = -int_max;
    float extra = GIRO_KP_W * err + GIRO_KI_W * g_w_int;
    if (extra >  GIRO_EXTRA_MAX_PWM) extra =  GIRO_EXTRA_MAX_PWM;
    if (extra < -GIRO_EXTRA_MAX_PWM) extra = -GIRO_EXTRA_MAX_PWM;

    // Adelanto: velocidad de rueda para w (en el lugar: radio L/2; swing: radio L)
    float v_rueda = g_w_ramp * DEG_A_RAD * (swing ? L_RUEDAS_CM : L_RUEDAS_CM * 0.5f);
    float p = pwm_de_vel(v_rueda) + extra;
    if (p < 0.0f) p = 0.0f;
    if (p > PWM_MAX_TRACCION) p = PWM_MAX_TRACCION;

    if (swing) {
        aplicar_pwm(0.0f, dir * p, dt_s);
    } else {
        aplicar_pwm(-dir * p, dir * p, dt_s);
    }
    return false;
}

// Motores cortados: sigue integrando la inercia hasta que el giro se detiene. true al terminar.
static bool asentar_giro(float dir, const imu_t *s, int64_t ahora_ms)
{
    stop_all_motors();
    g_feedback = (int32_t)lround(dir * (s->yaw - g_yaw_inicio) * 10.0);
    if (fabsf(s->w) > ASENTAR_W_DPS) g_quieto_desde_ms = ahora_ms;
    return (ahora_ms - g_quieto_desde_ms >= ASENTAR_QUIETO_MS) || (ahora_ms - g_t_sub_ms >= ASENTAR_MAX_MS);
}

static bool girando_ahora(void)
{
    if (g_state != STATE_EXECUTING || g_sub != SUB_MOVIENDO) return false;
    return g_mode == MODE_GIRO_IZQ || g_mode == MODE_GIRO_DER
        || (g_mode == MODE_PIVOT && g_pivot_step == PIVOT_STEP_GIRO);
}

static void empezar_giro(double grados, int64_t ahora_ms, float w_crucero, const imu_t *s)
{
    g_rumbo_obj += grados;
    g_yaw_inicio = s->yaw;
    g_w_ramp = 0.0f;
    g_w_int = 0.0f;
    g_sub = SUB_MOVIENDO;
    g_t_inicio_ms = ahora_ms;
    g_timeout_ms = GIRO_TIMEOUT_BASE_MS + (int64_t)(fabs(grados) * 1000.0 / (w_crucero * 0.5f));
}

// Termina el comando activo: corta la traccion y publica el estado final
static void terminar(int32_t estado, int32_t feedback)
{
    if (estado == STATE_ERROR && girando_ahora()) {
        g_rumbo_obj = imu_leer().yaw;   // giro interrumpido: el objetivo pasa a ser el rumbo actual
    }
    stop_all_motors();
    g_feedback = feedback;
    publish_status_now(g_cmd_id, estado, feedback);
    g_mode  = MODE_STOP;
    g_state = STATE_IDLE;
    g_traccion_activa = false;
}

// =====================================================
// APLICAR UN COMANDO NUEVO (siempre atento)
// =====================================================
static void start_command(int32_t cmd_id, int32_t mode, int32_t param)
{
    imu_t s = imu_leer();
    int64_t ahora_ms = esp_timer_get_time() / 1000LL;

    // El comando activo queda reemplazado
    if (g_state == STATE_EXECUTING) {
        if (girando_ahora()) g_rumbo_obj = s.yaw;
        publish_status_now(g_cmd_id, STATE_ABORTED, g_feedback);
    }

    // Seguir rampeando si la recta nueva va en el mismo sentido que la anterior
    bool misma_recta = (g_state == STATE_EXECUTING && g_mode == mode
                        && (mode == MODE_ADELANTE || mode == MODE_ATRAS));

    g_cmd_id = cmd_id;
    g_mode   = mode;
    g_param  = param;
    g_feedback = 0;
    g_state  = STATE_EXECUTING;
    g_sub    = SUB_MOVIENDO;
    g_t_inicio_ms = ahora_ms;
    g_dist_cm = 0.0f;
    g_traccion_activa = (mode != MODE_STOP && mode != MODE_CALIBRAR);
    if (!misma_recta) {
        g_vel_ramp = 0.0f;
        g_rumbo_int = 0.0f;
    }
    if (mode != MODE_CALIBRAR) imu_fijar_ventana(RECAL_S);

    // Robot movido a mano (o giro fallido): el objetivo viejo ya no sirve
    if (mode >= MODE_ADELANTE && mode <= MODE_PIVOT && imu_listo(&s)
        && fabs(g_rumbo_obj - s.yaw) > RUMBO_REANCLAJE_DEG) {
        g_rumbo_obj = s.yaw;
    }

    switch (mode) {
        case MODE_STOP:
            stop_all_motors();
            break;

        case MODE_ADELANTE:
        case MODE_ATRAS:
            break;

        case MODE_GIRO_IZQ:
            empezar_giro((double)param, ahora_ms, GIRO_W_DPS, &s);
            break;

        case MODE_GIRO_DER:
            empezar_giro(-(double)param, ahora_ms, GIRO_W_DPS, &s);
            break;

        case MODE_PIVOT:
            // Forzar accesorios ON independientemente de lo que mande el Brain
            target_trimmer_state = 1;
            gpio_set_level(CORTADORA_ENABLE_PIN, 1);
            g_pivot_step = PIVOT_STEP_ADELANTE;
            break;

        case MODE_CALIBRAR:
            stop_all_motors();
            portENTER_CRITICAL(&imu_mux);
            imu.cal_dur_s = (param > 0) ? param : RECAL_S;
            imu.ult_rechazo = 0;
            portEXIT_CRITICAL(&imu_mux);
            g_cal_ok_ref = s.n_cal_ok;
            g_imu_reiniciar_ventana = true;
            break;

        default:
            break;
    }
}

// =====================================================
// CONTROL POR CICLO
// =====================================================
static void control_step(float dt_s)
{
    if (g_state != STATE_EXECUTING) {
        g_traccion_activa = false;
        return;
    }

    imu_t s = imu_leer();
    int64_t ahora_ms = esp_timer_get_time() / 1000LL;
    g_traccion_activa = (g_mode != MODE_STOP && g_mode != MODE_CALIBRAR);

    switch (g_mode) {

        case MODE_STOP:
            if (ahora_ms - g_t_inicio_ms >= STOP_ASENTAR_MS) {
                terminar(STATE_DONE, 0);
            }
            break;

        case MODE_ADELANTE:
            control_recta(1.0f, (float)g_param, &s, dt_s);
            break;

        case MODE_ATRAS:
            control_recta(-1.0f, (float)g_param, &s, dt_s);
            break;

        case MODE_GIRO_IZQ:
        case MODE_GIRO_DER: {
            float dir = (g_mode == MODE_GIRO_IZQ) ? 1.0f : -1.0f;
            if (g_sub == SUB_MOVIENDO) {
                if (!imu_listo(&s)) {
                    terminar(STATE_ERROR, ERR_IMU);
                } else if (ahora_ms - g_t_inicio_ms > g_timeout_ms) {
                    terminar(STATE_ERROR, ERR_GIRO_TIEMPO);
                } else if (control_giro(dir, false, GIRO_W_DPS, &s, dt_s)) {
                    g_sub = SUB_ASENTANDO;
                    g_t_sub_ms = g_quieto_desde_ms = ahora_ms;
                }
            } else if (asentar_giro(dir, &s, ahora_ms)) {
                terminar(STATE_DONE, g_feedback);   // grados girados (decimas), incluida la inercia
            }
            break;
        }

        case MODE_PIVOT: {
            if (g_pivot_step == PIVOT_STEP_ADELANTE || g_pivot_step == PIVOT_STEP_ATRAS) {
                // Fases lineales: distancia estimada en lazo abierto, rumbo sostenido
                bool adelante = (g_pivot_step == PIVOT_STEP_ADELANTE);
                float objetivo = adelante
                    ? ((g_param > 0) ? (float)g_param : PIVOT_ADELANTE_CM_DEFAULT)
                    : PIVOT_ATRAS_CM;
                float restante = objetivo - g_dist_cm;
                g_feedback = (int32_t)lroundf(g_dist_cm);   // cm recorridos (estimados)

                if (restante <= 0.0f) {
                    stop_all_motors();
                    g_vel_ramp = 0.0f;
                    g_dist_cm = 0.0f;
                    if (adelante) {
                        g_pivot_step = PIVOT_STEP_ATRAS;
                    } else {
                        if (!imu_listo(&s)) {
                            terminar(STATE_ERROR, ERR_IMU);
                            break;
                        }
                        g_pivot_step = PIVOT_STEP_GIRO;
                        empezar_giro(PIVOT_GIRO_DEG, ahora_ms, SWING_W_DPS, &s);
                    }
                    break;
                }

                float vel = PIVOT_VEL_CM_S;
                if (restante < PIVOT_DECEL_CM) {
                    vel = PIVOT_VEL_MIN_CM_S + (PIVOT_VEL_CM_S - PIVOT_VEL_MIN_CM_S) * (restante / PIVOT_DECEL_CM);
                }
                control_recta(adelante ? 1.0f : -1.0f, vel, &s, dt_s);

            } else if (g_sub == SUB_MOVIENDO) {
                // Fase 3: swing 90° — rueda izq fija, solo rueda der avanza
                if (!imu_listo(&s)) {
                    terminar(STATE_ERROR, ERR_IMU);
                } else if (ahora_ms - g_t_inicio_ms > g_timeout_ms) {
                    terminar(STATE_ERROR, ERR_GIRO_TIEMPO);
                } else if (control_giro(1.0f, true, SWING_W_DPS, &s, dt_s)) {
                    g_sub = SUB_ASENTANDO;
                    g_t_sub_ms = g_quieto_desde_ms = ahora_ms;
                }
            } else if (asentar_giro(1.0f, &s, ahora_ms)) {
                terminar(STATE_DONE, g_feedback);
            }
            break;
        }

        case MODE_CALIBRAR:
            if (s.estado == IMU_FALLA) {
                terminar(STATE_ERROR, ERR_IMU);
            } else if (s.n_cal_ok != g_cal_ok_ref) {
                terminar(STATE_DONE, (int32_t)lroundf(s.bias_z * 1000.0f));   // bias z [mdps]
            } else {
                int dur_s = (g_param > 0) ? g_param : RECAL_S;
                if (ahora_ms - g_t_inicio_ms > (int64_t)dur_s * 1000 + RECAL_ESPERA_MAX_MS) {
                    terminar(STATE_ERROR, s.ult_rechazo ? s.ult_rechazo : ERR_CAL_QUIETO);
                }
            }
            if (g_state != STATE_EXECUTING) imu_fijar_ventana(RECAL_S);
            break;

        default:
            terminar(STATE_ERROR, ERR_COMANDO);
            break;
    }
}

// =====================================================
// VALIDACION
// =====================================================
static bool param_valido(int32_t mode, int32_t param)
{
    switch (mode) {
        case MODE_STOP:        return true;
        case MODE_ADELANTE:
        case MODE_ATRAS:       return param >= 0;            // > VEL_MAX se recorta
        case MODE_GIRO_IZQ:
        case MODE_GIRO_DER:    return param >= 0 && param <= 720;
        case MODE_PIVOT:       return param >= 0 && param <= 300;
        case MODE_CALIBRAR:    return param >= 0 && param <= 30;
        case MODE_FIJAR_RUMBO: return param >= -360 && param <= 360;
        default:               return false;
    }
}

static bool is_valid_onoff(int32_t v)
{
    return (v == 0 || v == 1);
}

// Rechazo: corta la traccion (los accesorios no cambian) y publica ERROR con el codigo
static void rechazar(int32_t cmd_id, int32_t codigo)
{
    if (g_state == STATE_EXECUTING) {
        if (girando_ahora()) g_rumbo_obj = imu_leer().yaw;
        publish_status_now(g_cmd_id, STATE_ABORTED, g_feedback);
    }
    stop_all_motors();
    g_mode  = MODE_STOP;
    g_state = STATE_IDLE;
    g_traccion_activa = false;
    imu_fijar_ventana(RECAL_S);
    publish_status_now(cmd_id, STATE_ERROR, codigo);
}

// =====================================================
// CALLBACK DE COMANDOS — siempre atento
// =====================================================
static void motion_cmd_callback(const void * msgin)
{
    const std_msgs__msg__Int32MultiArray * msg = (const std_msgs__msg__Int32MultiArray *)msgin;

    if (msg == NULL || msg->data.size < CMD_LEN) {
        rechazar(-1, ERR_COMANDO);
        return;
    }

    int32_t cmd_id        = msg->data.data[0];
    int32_t mode          = msg->data.data[1];
    int32_t param         = msg->data.data[2];
    int32_t bordeadora_on = msg->data.data[3];
    int32_t cortadora_on  = msg->data.data[4];

    if (!param_valido(mode, param) || !is_valid_onoff(bordeadora_on) || !is_valid_onoff(cortadora_on)) {
        rechazar(cmd_id, ERR_COMANDO);
        return;
    }

    // Accesorios: se aplican siempre, independientemente del movimiento
    target_trimmer_state = bordeadora_on;
    gpio_set_level(CORTADORA_ENABLE_PIN, (uint32_t)cortadora_on);

    imu_t s = imu_leer();

    // FIJAR_RUMBO no reemplaza al movimiento: corre el rumbo y el objetivo lo mismo
    if (mode == MODE_FIJAR_RUMBO) {
        if (s.estado == IMU_FALLA) {
            publish_status_now(cmd_id, STATE_ERROR, ERR_IMU);
            return;
        }
        portENTER_CRITICAL(&imu_mux);
        double offset = (double)param - imu.yaw;
        imu.yaw += offset;
        portEXIT_CRITICAL(&imu_mux);
        g_rumbo_obj += offset;
        g_yaw_inicio += offset;
        publish_status_now(cmd_id, STATE_DONE, param * 10);
        return;
    }

    // Si la orden de movimiento es IDENTICA a la que ya se esta ejecutando
    // (mismo modo y param), no reiniciar el lazo de control: el comando solo
    // cambia accesorios. Asi se evita el "hipo" de marcha al, p.ej., prender
    // la cortadora mientras se avanza recto.
    if (mode == g_mode && param == g_param && g_state == STATE_EXECUTING) {
        g_cmd_id = cmd_id;   // actualizar el id para el feedback
        publish_status_now(cmd_id, STATE_EXECUTING, g_feedback);
        return;
    }

    // Giros y PIVOT necesitan el IMU calibrado; CALIBRAR, que responda
    bool necesita_imu = (mode == MODE_GIRO_IZQ || mode == MODE_GIRO_DER || mode == MODE_PIVOT);
    if ((necesita_imu && !imu_listo(&s)) || (mode == MODE_CALIBRAR && s.estado == IMU_FALLA)) {
        rechazar(cmd_id, ERR_IMU);
        return;
    }

    // Cualquier comando nuevo reemplaza al actual de inmediato
    start_command(cmd_id, mode, param);

    // ACK del comando aceptado
    publish_status_now(cmd_id, STATE_ACCEPTED, 0);
}

// =====================================================
// TAREA PRINCIPAL micro-ROS
// =====================================================
void micro_ros_task(void * arg)
{
    (void)arg;

    ESP_ERROR_CHECK(motor_hw_init());

    // IMU en su propia tarea, con mas prioridad, para no perder muestras mientras micro-ROS bloquea
    xTaskCreatePinnedToCore(imu_task, "imu_task", 4096, NULL,
                            CONFIG_MICRO_ROS_APP_TASK_PRIO + 1, NULL, portNUM_PROCESSORS - 1);

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

    publish_status_now(0, STATE_IDLE, 0);

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
                publish_status_now(g_cmd_id, STATE_EXECUTING, g_feedback);
            }
        } else {
            // IDLE: heartbeat (incluye rumbo y estado del IMU)
            if ((now_ms - last_status_pub_ms) >= IDLE_HEARTBEAT_MS) {
                publish_status_now(0, STATE_IDLE, 0);
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
    // UART0 es de micro-ROS: ningun log despues del arranque
    esp_log_level_set("*", ESP_LOG_NONE);

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
