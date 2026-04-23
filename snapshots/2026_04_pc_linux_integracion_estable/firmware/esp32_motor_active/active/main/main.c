//  Codigo Main Motores suscribers y publisher
//  Nombre: Codigo_motor1.0.cpp.bak
//  Version 1.0
//  Fecha: 05/04/2026 23:36
//  Autor: Angel Alegre


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
#include "esp_err.h"
#include "esp_timer.h"

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
// DRIVER / MOTORES
// =====================================================
// Izquierda
#define PWM1_PIN   GPIO_NUM_25
#define DIR1_PIN   GPIO_NUM_26

// Derecha
#define PWM2_PIN   GPIO_NUM_27
#define DIR2_PIN   GPIO_NUM_14

#define PWM_FREQ_HZ       1000
#define PWM_MAX_VALUE     255

#define PWM_TIMER         LEDC_TIMER_0
#define PWM_MODE          LEDC_LOW_SPEED_MODE
#define PWM_RESOLUTION    LEDC_TIMER_8_BIT

#define PWM_CH_LEFT       LEDC_CHANNEL_0
#define PWM_CH_RIGHT      LEDC_CHANNEL_1

// =====================================================
// TOPICOS
// =====================================================
static const char * TOPIC_MOTION_CMD    = "motion_cmd";
static const char * TOPIC_MOTION_STATUS = "motion_status";

// =====================================================
// PROTOCOLO
// motion_cmd    = [cmd_id, L_dir, L_pwm, R_dir, R_pwm, T_ms]
// motion_status = [cmd_id, state, L_dir, L_pwm, R_dir, R_pwm, remaining_ms]
// =====================================================
#define CMD_LEN     6
#define STATUS_LEN  7

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
    int64_t start_ms;
    bool active;
    bool continuous;
} motion_cmd_t;

// =====================================================
// GLOBALES micro-ROS
// =====================================================
static size_t uart_port = 0;   // mismo estilo que tu nodo sensor

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
    pwm_write(PWM_CH_LEFT, 0);
    pwm_write(PWM_CH_RIGHT, 0);
}

// Convencion actual segun tu prueba:
// LOW  = un sentido
// HIGH = el otro sentido
//
// Dejo 0->LOW y 1->HIGH.
// Si luego queres invertir, cambia SOLO estas dos lineas.
static void apply_motor_command(int32_t l_dir, int32_t l_pwm, int32_t r_dir, int32_t r_pwm)
{
    gpio_set_level(DIR1_PIN, (l_dir == 1) ? 1 : 0);   // izquierda
    gpio_set_level(DIR2_PIN, (r_dir == 1) ? 1 : 0);   // derecha

    pwm_write(PWM_CH_LEFT,  (uint32_t)l_pwm);
    pwm_write(PWM_CH_RIGHT, (uint32_t)r_pwm);
}

static esp_err_t motor_hw_init(void)
{
    gpio_config_t io_conf = {
        .pin_bit_mask = (1ULL << DIR1_PIN) | (1ULL << DIR2_PIN),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE
    };
    ESP_ERROR_CHECK(gpio_config(&io_conf));

    gpio_set_level(DIR1_PIN, 0);
    gpio_set_level(DIR2_PIN, 0);

    ledc_timer_config_t ledc_timer = {
        .speed_mode       = PWM_MODE,
        .duty_resolution  = PWM_RESOLUTION,
        .timer_num        = PWM_TIMER,
        .freq_hz          = PWM_FREQ_HZ,
        .clk_cfg          = LEDC_AUTO_CLK
    };
    ESP_ERROR_CHECK(ledc_timer_config(&ledc_timer));

    ledc_channel_config_t ledc_left = {
        .gpio_num   = PWM1_PIN,
        .speed_mode = PWM_MODE,
        .channel    = PWM_CH_LEFT,
        .intr_type  = LEDC_INTR_DISABLE,
        .timer_sel  = PWM_TIMER,
        .duty       = 0,
        .hpoint     = 0
    };
    ESP_ERROR_CHECK(ledc_channel_config(&ledc_left));

    ledc_channel_config_t ledc_right = {
        .gpio_num   = PWM2_PIN,
        .speed_mode = PWM_MODE,
        .channel    = PWM_CH_RIGHT,
        .intr_type  = LEDC_INTR_DISABLE,
        .timer_sel  = PWM_TIMER,
        .duty       = 0,
        .hpoint     = 0
    };
    ESP_ERROR_CHECK(ledc_channel_config(&ledc_right));

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
    return (dir == 0 || dir == 1);
}

static bool is_valid_pwm(int32_t pwm)
{
    return (pwm >= 0 && pwm <= 255);
}

static bool is_valid_duration(int32_t duration_ms)
{
    return (duration_ms >= 0);
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

    int32_t cmd_id      = msg->data.data[0];
    int32_t l_dir       = msg->data.data[1];
    int32_t l_pwm       = msg->data.data[2];
    int32_t r_dir       = msg->data.data[3];
    int32_t r_pwm       = msg->data.data[4];
    int32_t duration_ms = msg->data.data[5];

    if (!is_valid_dir(l_dir) || !is_valid_dir(r_dir) ||
        !is_valid_pwm(l_pwm) || !is_valid_pwm(r_pwm) ||
        !is_valid_duration(duration_ms))
    {
        publish_status_now(cmd_id, STATE_ERROR, 0, 0, 0, 0, 0);
        return;
    }

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
    active_cmd.cmd_id      = cmd_id;
    active_cmd.l_dir       = l_dir;
    active_cmd.l_pwm       = l_pwm;
    active_cmd.r_dir       = r_dir;
    active_cmd.r_pwm       = r_pwm;
    active_cmd.duration_ms = duration_ms;
    active_cmd.start_ms    = esp_timer_get_time() / 1000LL;
    active_cmd.continuous  = (duration_ms == 0);
    active_cmd.active      = true;

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

    RCCHECK(rclc_support_init(&support, 0, NULL, &allocator));

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