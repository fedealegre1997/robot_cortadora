//  Firmware ESP32-S3 — Control de Motores con micro-ROS
//  Placa: ESP32-S3-WROOM-1 (N8R2, 8MB Flash, 2MB PSRAM)
//  Driver de traccion: MC33926 (puente H, 4 canales LEDC — GPIO 4,5,6,7)
//  Bordeadora: Sabertooth 2x25 v2, modo serial simplificado (UART2 TX, GPIO 17, 9600 baud)
//  Cortadora central: AMC CBE12A1C, habilitacion por GPIO 18 → P1-9 INHIBIT (active LOW)
//
//  Protocolo:
//      motion_cmd    = [cmd_id, L_dir, L_pwm, R_dir, R_pwm, T_ms, bordeadora_on, cortadora_on]
//      motion_status = [cmd_id, state, L_dir, L_pwm, R_dir, R_pwm, remaining_ms]
//
//  Descripcion:
//      Recibe comandos de movimiento del Brain (ROS 2) por micro-ROS serial (UART0).
//      Traduce la trama al driver MC33926 (2 canales PWM por motor).
//      Controla la bordeadora (rampa soft-start anti-cogging, Sabertooth serial).
//      Controla la cortadora central brushless (GPIO 18 HIGH = habilitado, LOW = inhibido).
//      Los accesorios se aplican siempre, independientemente del estado de traccion.
//      Publica el estado de ejecucion en /motion_status cada 200 ms (EXECUTING) o 1 s (IDLE).
//
//  Version: 2.2
//  Autor: Angel Alegre
//  Ultima verificacion: 31/05/2026

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "driver/gpio.h"
#include "driver/ledc.h"
#include "driver/uart.h"
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
// TOPICOS
// =====================================================
static const char * TOPIC_MOTION_CMD    = "motion_cmd";
static const char * TOPIC_MOTION_STATUS = "motion_status";

// =====================================================
// PROTOCOLO
// motion_cmd    = [cmd_id, L_dir, L_pwm, R_dir, R_pwm, T_ms, bordeadora_on, cortadora_on]
// motion_status = [cmd_id, state, L_dir, L_pwm, R_dir, R_pwm, remaining_ms]
// =====================================================
#define CMD_LEN     8
#define STATUS_LEN  7

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

// Convencion logica mantenida para compatibilidad con el nodo central
#define DIR_REVERSE 0
#define DIR_FORWARD 1

enum MotionState {
    STATE_IDLE      = 0,
    STATE_ACCEPTED  = 1,
    STATE_EXECUTING = 2,
    STATE_DONE      = 3,
    STATE_ABORTED   = 4,
    STATE_ERROR     = 5
};

typedef struct {
    int32_t cmd_id;
    int32_t l_dir;
    int32_t l_pwm;
    int32_t r_dir;
    int32_t r_pwm;
    int32_t duration_ms;   // 0 = continuo
    int32_t bordeadora_on; // 0 = off, 1 = on
    int64_t start_ms;
    bool active;
    bool continuous;
} motion_cmd_t;

static int32_t current_trimmer_speed = TRIMMER_SPEED_STOP;
static int64_t last_trimmer_update_ms = 0;
static int32_t target_trimmer_state = 0; // Memoria del último estado de la bordeadora Deseado

// =====================================================
// GLOBALES micro-ROS
// =====================================================
static size_t uart_port = 0;

rcl_subscription_t motion_cmd_subscriber;
rcl_publisher_t motion_status_publisher;

std_msgs__msg__Int32MultiArray motion_cmd_msg;
std_msgs__msg__Int32MultiArray motion_status_msg;

static motion_cmd_t active_cmd = {0};
static int32_t current_state = STATE_IDLE;
static int64_t last_status_pub_ms = 0;

// =====================================================
// HELPERS HARDWARE
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

// Aplica el comando físico usando PWM y Dirección digital en MC33926
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

static esp_err_t motor_hw_init(void)
{
    sabertooth_hw_init(); // Inicializar el UART del Sabertooth

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
// HELPERS STATUS
// =====================================================
static void fill_status_msg(
    int32_t cmd_id,
    int32_t state,
    int32_t l_dir,
    int32_t l_pwm,
    int32_t r_dir,
    int32_t r_pwm,
    int32_t remaining_ms)
{
    motion_status_msg.data.data[0] = cmd_id;
    motion_status_msg.data.data[1] = state;
    motion_status_msg.data.data[2] = l_dir;
    motion_status_msg.data.data[3] = l_pwm;
    motion_status_msg.data.data[4] = r_dir;
    motion_status_msg.data.data[5] = r_pwm;
    motion_status_msg.data.data[6] = remaining_ms;
}

static void publish_status_now(
    int32_t cmd_id,
    int32_t state,
    int32_t l_dir,
    int32_t l_pwm,
    int32_t r_dir,
    int32_t r_pwm,
    int32_t remaining_ms)
{
    fill_status_msg(cmd_id, state, l_dir, l_pwm, r_dir, r_pwm, remaining_ms);
    RCSOFTCHECK(rcl_publish(&motion_status_publisher, &motion_status_msg, NULL));
    last_status_pub_ms = esp_timer_get_time() / 1000LL;
}

static int32_t get_remaining_ms(void)
{
    if (!active_cmd.active || active_cmd.continuous) {
        return 0;
    }

    int64_t now_ms = esp_timer_get_time() / 1000LL;
    int64_t elapsed = now_ms - active_cmd.start_ms;
    int64_t remaining = (int64_t)active_cmd.duration_ms - elapsed;

    if (remaining < 0) {
        remaining = 0;
    }

    return (int32_t)remaining;
}

// =====================================================
// VALIDACION
// =====================================================
static bool is_valid_dir(int32_t dir)
{
    return (dir == DIR_REVERSE || dir == DIR_FORWARD);
}

static bool is_valid_pwm(int32_t pwm)
{
    return (pwm >= 0 && pwm <= 255);
}

static bool is_valid_duration(int32_t duration_ms)
{
    return (duration_ms >= 0);
}

static bool is_valid_bordeadora(int32_t val)
{
    return (val == 0 || val == 1);
}

static bool is_stop_command(int32_t l_pwm, int32_t r_pwm)
{
    return (l_pwm == 0 && r_pwm == 0);
}

// =====================================================
// CALLBACK DE COMANDOS
// =====================================================
static void motion_cmd_callback(const void * msgin)
{
    const std_msgs__msg__Int32MultiArray * msg = (const std_msgs__msg__Int32MultiArray *)msgin;

    if (msg == NULL || msg->data.size < CMD_LEN) {
        publish_status_now(-1, STATE_ERROR, 0, 0, 0, 0, 0);
        return;
    }

    int32_t cmd_id        = msg->data.data[0];
    int32_t l_dir         = msg->data.data[1];
    int32_t l_pwm         = msg->data.data[2];
    int32_t r_dir         = msg->data.data[3];
    int32_t r_pwm         = msg->data.data[4];
    int32_t duration_ms   = msg->data.data[5];
    int32_t bordeadora_on = msg->data.data[6];
    int32_t cortadora_on  = msg->data.data[7];

    if (!is_valid_dir(l_dir) || !is_valid_dir(r_dir) ||
        !is_valid_pwm(l_pwm) || !is_valid_pwm(r_pwm) ||
        !is_valid_duration(duration_ms) || !is_valid_bordeadora(bordeadora_on) ||
        !is_valid_bordeadora(cortadora_on))
    {
        publish_status_now(cmd_id, STATE_ERROR, 0, 0, 0, 0, 0);
        return;
    }

    // Accesorios: se aplican siempre, independientemente del comando de movimiento
    target_trimmer_state = bordeadora_on;
    gpio_set_level(CORTADORA_ENABLE_PIN, (uint32_t)cortadora_on);

    // STOP:
    // si ya habia un comando activo, lo aborta
    // y luego responde DONE para el STOP recibido
    if (is_stop_command(l_pwm, r_pwm)) {
        if (active_cmd.active) {
            stop_all_motors();
            publish_status_now(active_cmd.cmd_id, STATE_ABORTED, 0, 0, 0, 0, 0);
        }

        active_cmd.active = false;
        active_cmd.continuous = false;
        current_state = STATE_DONE;

        publish_status_now(cmd_id, STATE_DONE, 0, 0, 0, 0, 0);
        current_state = STATE_IDLE;
        return;
    }

    // Si esta ocupado, por ahora no acepta otro comando
    if (active_cmd.active) {
        publish_status_now(cmd_id, STATE_ERROR, 0, 0, 0, 0, get_remaining_ms());
        return;
    }

    // Guardar comando
    active_cmd.cmd_id        = cmd_id;
    active_cmd.l_dir         = l_dir;
    active_cmd.l_pwm         = l_pwm;
    active_cmd.r_dir         = r_dir;
    active_cmd.r_pwm         = r_pwm;
    active_cmd.duration_ms   = duration_ms;
    active_cmd.bordeadora_on = bordeadora_on;
    active_cmd.start_ms      = esp_timer_get_time() / 1000LL;
    active_cmd.continuous    = (duration_ms == 0);
    active_cmd.active        = true;

    current_state = STATE_ACCEPTED;
    publish_status_now(
        active_cmd.cmd_id,
        STATE_ACCEPTED,
        active_cmd.l_dir,
        active_cmd.l_pwm,
        active_cmd.r_dir,
        active_cmd.r_pwm,
        get_remaining_ms()
    );

    // Ejecutar
    apply_motor_command(
        active_cmd.l_dir,
        active_cmd.l_pwm,
        active_cmd.r_dir,
        active_cmd.r_pwm
    );

    current_state = STATE_EXECUTING;
    publish_status_now(
        active_cmd.cmd_id,
        STATE_EXECUTING,
        active_cmd.l_dir,
        active_cmd.l_pwm,
        active_cmd.r_dir,
        active_cmd.r_pwm,
        get_remaining_ms()
    );
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

    // Bucle de reintento de conexión con el agente micro-ROS (completamente silencioso para no corromper UART0)
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

    publish_status_now(0, STATE_IDLE, 0, 0, 0, 0, 0);

    const int64_t STATUS_PERIOD_MS = 200;
    const int64_t IDLE_HEARTBEAT_MS = 1000;

    while (1) {
        rclc_executor_spin_some(&executor, RCL_MS_TO_NS(10));

        int64_t now_ms = esp_timer_get_time() / 1000LL;

        // Control automático de rampa de la bordeadora (Soft-Start)
        if (now_ms - last_trimmer_update_ms >= TRIMMER_RAMP_MS) {
            last_trimmer_update_ms = now_ms;
            
            if (target_trimmer_state == 1) {
                // Rampa ascendente
                if (current_trimmer_speed == TRIMMER_SPEED_STOP) {
                    // Salto inicial para evitar el "cogging" (tirón hacia atrás por bajo voltaje)
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
                // Apagado inmediato (o rampa descendente si se desea, pero inmediato es más seguro)
                if (current_trimmer_speed != TRIMMER_SPEED_STOP) {
                    current_trimmer_speed = TRIMMER_SPEED_STOP;
                    uart_write_bytes(SABERTOOTH_UART_NUM, (const char[]){TRIMMER_SPEED_STOP}, 1);
                }
            }
        }

        // Comando temporizado
        if (active_cmd.active && !active_cmd.continuous) {
            int32_t remaining_ms = get_remaining_ms();

            if (remaining_ms <= 0) {
                stop_all_motors();

                int32_t finished_cmd_id = active_cmd.cmd_id;

                active_cmd.active = false;
                active_cmd.continuous = false;
                current_state = STATE_DONE;

                publish_status_now(finished_cmd_id, STATE_DONE, 0, 0, 0, 0, 0);
                current_state = STATE_IDLE;
            }
            else if ((now_ms - last_status_pub_ms) >= STATUS_PERIOD_MS) {
                publish_status_now(
                    active_cmd.cmd_id,
                    STATE_EXECUTING,
                    active_cmd.l_dir,
                    active_cmd.l_pwm,
                    active_cmd.r_dir,
                    active_cmd.r_pwm,
                    remaining_ms
                );
            }
        }
        // Comando continuo
        else if (active_cmd.active && active_cmd.continuous) {
            if ((now_ms - last_status_pub_ms) >= STATUS_PERIOD_MS) {
                publish_status_now(
                    active_cmd.cmd_id,
                    STATE_EXECUTING,
                    active_cmd.l_dir,
                    active_cmd.l_pwm,
                    active_cmd.r_dir,
                    active_cmd.r_pwm,
                    0
                );
            }
        }
        // Heartbeat en reposo
        else {
            if ((now_ms - last_status_pub_ms) >= IDLE_HEARTBEAT_MS) {
                publish_status_now(0, STATE_IDLE, 0, 0, 0, 0, 0);
            }
        }

        usleep(10000);
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