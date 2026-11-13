//  Firmware ESP32 — Adquisicion de Sensores con micro-ROS
//  Placa: ESP32 (clasico, 2MB Flash)
//  Solo publica, no suscribe ningun topic.
//
//  Sensores incluidos:
//      * Finales de Carrera (x3, GPIO 18, 22, 19)
//      * MPU-6500 — IMU (I2C, GPIO 21 SDA / 23 SCL)
//      * Ultrasonicos HC-SR04 (x3, TRIG: 25,26,33 — ECHO: 32,27,35)
//      * GPS FSTR2 (UART2, GPIO 16 RX / 17 TX, 9600 baud)
//
//  Protocolo de publicacion:
//      Topic: /sensores | Float32MultiArray | reliable, 50 ms
//      [bumper_izq, bumper_centro, bumper_der,
//       ultra_izq, ultra_centro, ultra_der,
//       roll, pitch, yaw,
//       gps_lat, gps_lon, gps_alt, gps_fix]
//
//  Arquitectura de tareas FreeRTOS:
//      Core 0: ultrasonic_task (~180 ms), gps_task (continua)
//      Core 1: bumper_task (10 ms), imu_task (10 ms), micro_ros_task (50 ms)
//      Datos compartidos entre tareas mediante variables globales con mutex.
//
//  NOTA: No usar printf() en ninguna tarea. La UART0 es exclusiva de micro-ROS.
//
//  Version: 6.1
//  Fecha: 31/05/2026
//  Autor: Angel Alegre

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include "esp_rom_sys.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "driver/uart.h"
#include "driver/gpio.h"
#include "driver/i2c.h"
#include "esp_err.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_system.h"

#include <rcl/rcl.h>
#include <rcl/error_handling.h>
#include <rclc/rclc.h>
#include <std_msgs/msg/float32_multi_array.h>
#include <rmw_microros/rmw_microros.h>

#include "esp32_serial_transport.h"

// --- Macros de Error ---
#define RCCHECK(fn) { \
    rcl_ret_t temp_rc = fn; \
    if ((temp_rc != RCL_RET_OK)) { \
        ESP_LOGE("ROS", "Error en %s: %d", #fn, (int)temp_rc); \
        vTaskDelay(pdMS_TO_TICKS(1000)); \
        esp_restart(); \
    } \
}

// --- Configuración General ---
#define SENSORES_SIZE       13

#define PIN_B_L             GPIO_NUM_18
#define PIN_B_C             GPIO_NUM_22
#define PIN_B_R             GPIO_NUM_19

#define TRIG_IZQ            GPIO_NUM_25
#define ECHO_IZQ            GPIO_NUM_32
#define TRIG_CEN            GPIO_NUM_26
#define ECHO_CEN            GPIO_NUM_27
#define TRIG_DER            GPIO_NUM_33
#define ECHO_DER            GPIO_NUM_35

#define ULTRA_TIMEOUT_US    30000UL
#define DESFASE_MS          60
#define ULTRA_STALE_US      500000LL    // 500 ms

#define ROS_PUBLISH_MS      50
#define IMU_PERIOD_MS       10
#define BUMPER_PERIOD_MS    10

// --- GPS ---
#define GPS_UART_NUM        UART_NUM_2
#define GPS_TX_PIN          GPIO_NUM_17
#define GPS_RX_PIN          GPIO_NUM_16
#define GPS_BAUD_RATE       9600
#define GPS_BUF_SIZE        256
#define GPS_STALE_US        3000000LL   // 3 s

// --- I2C / MPU-6500 ---
#define I2C_MASTER_SDA_IO   GPIO_NUM_21
#define I2C_MASTER_SCL_IO   GPIO_NUM_23
#define I2C_MASTER_NUM      I2C_NUM_0
#define I2C_MASTER_FREQ_HZ  100000
#define MPU_ADDR            0x69
#define MPU_PWR_MGMT_1      0x6B
#define MPU_ACCEL_XOUT_H    0x3B
#define ACCEL_SENS          16384.0f
#define GYRO_SENS           131.0f
#define ALPHA               0.98f
#define RAD_TO_DEG          57.29577951f

// --- Variables Globales ---
static size_t uart_port = UART_NUM_0;
static SemaphoreHandle_t g_data_mutex = NULL;

// Cache bumpers
static float g_bumper_l = 0.0f;
static float g_bumper_c = 0.0f;
static float g_bumper_r = 0.0f;

// Cache ultrasonidos
static float g_dist_izq = -1.0f;
static float g_dist_cen = -1.0f;
static float g_dist_der = -1.0f;
static int64_t g_t_izq_us = 0;
static int64_t g_t_cen_us = 0;
static int64_t g_t_der_us = 0;

// Cache IMU
static float g_roll = 0.0f;
static float g_pitch = 0.0f;
static float g_yaw = 0.0f;

// Cache GPS
static float g_gps_lat = NAN;
static float g_gps_lon = NAN;
static float g_gps_alt = NAN;
static float g_gps_fix = -1.0f;
static int64_t g_t_gps_us = 0;

// Offsets IMU
static float gx_off = 0, gy_off = 0, gz_off = 0;

// --- Prototipos ---
static void init_gpio_sensores(void);
static void init_i2c_mpu(void);
static void calibrar_mpu(void);
static void init_gps_uart(void);

static float medirDistancia(gpio_num_t pinTrig, gpio_num_t pinEcho);
static float ultra_para_publicar(float valor, int64_t t_us, int64_t ahora_us);
static float gps_para_publicar(float valor, int64_t t_us, int64_t ahora_us);
static float gps_fix_para_publicar(float fix, int64_t t_us, int64_t ahora_us);

static double nmea_to_decimal(const char *coord, char hemisphere);
static bool parse_gga_line(
    const char *line,
    double *latitude,
    double *longitude,
    double *altitude,
    int *fix_quality
);

void ultrasonic_task(void *arg);
void imu_task(void *arg);
void micro_ros_task(void *arg);
void bumper_task(void *arg);
void gps_task(void *arg);

// -------------------------------------------------
// app_main
// -------------------------------------------------
void app_main(void)
{
#if defined(RMW_UXRCE_TRANSPORT_CUSTOM)
    rmw_uros_set_custom_transport(
        true,
        (void *)&uart_port,
        esp32_serial_open,
        esp32_serial_close,
        esp32_serial_write,
        esp32_serial_read
    );
#endif

    g_data_mutex = xSemaphoreCreateMutex();
    if (g_data_mutex == NULL) {
        ESP_LOGE("MAIN", "No se pudo crear el mutex");
        return;
    }

    init_gpio_sensores();
    init_i2c_mpu();
    calibrar_mpu();
    init_gps_uart();

    // Core 0 -> tareas lentas
    xTaskCreatePinnedToCore(ultrasonic_task, "ultra_task",  4096, NULL, 6, NULL, 0);
    xTaskCreatePinnedToCore(gps_task,        "gps_task",    6144, NULL, 5, NULL, 0);

    // Core 1 -> tareas rápidas
    xTaskCreatePinnedToCore(bumper_task,     "bumper_task", 4096,  NULL, 7, NULL, 1);
    xTaskCreatePinnedToCore(imu_task,        "imu_task",    8192,  NULL, 6, NULL, 1);
    xTaskCreatePinnedToCore(micro_ros_task,  "uros_task",  16384,  NULL, 4, NULL, 1);
}

// -------------------------------------------------
// Función: Medir Distancia
// -------------------------------------------------
static float medirDistancia(gpio_num_t pinTrig, gpio_num_t pinEcho)
{
    gpio_set_level(pinTrig, 0);
    esp_rom_delay_us(4);

    // Verificar que ECHO esté en bajo antes de disparar
    int64_t t_idle = esp_timer_get_time();
    while (gpio_get_level(pinEcho) == 1) {
        if ((esp_timer_get_time() - t_idle) > 3000) return -4.0f;
    }

    // Trigger
    gpio_set_level(pinTrig, 1);
    esp_rom_delay_us(10);
    gpio_set_level(pinTrig, 0);

    // Esperar flanco de subida
    int64_t t0 = esp_timer_get_time();
    while (gpio_get_level(pinEcho) == 0) {
        if ((esp_timer_get_time() - t0) > ULTRA_TIMEOUT_US) return -1.0f;
    }

    // Esperar flanco de bajada
    int64_t start = esp_timer_get_time();
    while (gpio_get_level(pinEcho) == 1) {
        if ((esp_timer_get_time() - start) > ULTRA_TIMEOUT_US) return -2.0f;
    }

    float distancia = ((float)(esp_timer_get_time() - start) * 0.0343f) / 2.0f;

    if (distancia < 2.0f || distancia > 400.0f) return -3.0f;

    return distancia;
}

static float ultra_para_publicar(float valor, int64_t t_us, int64_t ahora_us)
{
    if (t_us == 0) return -1.0f;
    if ((ahora_us - t_us) > ULTRA_STALE_US) return -1.0f;
    return valor;
}

static float gps_para_publicar(float valor, int64_t t_us, int64_t ahora_us)
{
    if (t_us == 0) return NAN;
    if ((ahora_us - t_us) > GPS_STALE_US) return NAN;
    return valor;
}

static float gps_fix_para_publicar(float fix, int64_t t_us, int64_t ahora_us)
{
    if (t_us == 0) return -1.0f;
    if ((ahora_us - t_us) > GPS_STALE_US) return -1.0f;
    return fix;
}

// -------------------------------------------------
// GPS helpers
// -------------------------------------------------
static double nmea_to_decimal(const char *coord, char hemisphere)
{
    if (coord == NULL || coord[0] == '\0') {
        return NAN;
    }

    double raw = atof(coord);
    int degrees = (int)(raw / 100.0);
    double minutes = raw - (degrees * 100.0);
    double decimal = degrees + (minutes / 60.0);

    if (hemisphere == 'S' || hemisphere == 'W') {
        decimal = -decimal;
    }

    return decimal;
}

static bool parse_gga_line(
    const char *line,
    double *latitude,
    double *longitude,
    double *altitude,
    int *fix_quality
)
{
    if (strncmp(line, "$GPGGA", 6) != 0 && strncmp(line, "$GNGGA", 6) != 0) {
        return false;
    }

    char buffer[256];
    strncpy(buffer, line, sizeof(buffer) - 1);
    buffer[sizeof(buffer) - 1] = '\0';

    char *token;
    char *saveptr;
    int field_index = 0;

    char lat_str[20] = {0};
    char lon_str[20] = {0};
    char ns = '\0';
    char ew = '\0';
    char fix_str[8] = {0};
    char alt_str[20] = {0};

    token = strtok_r(buffer, ",", &saveptr);
    while (token != NULL) {
        switch (field_index) {
            case 2:
                strncpy(lat_str, token, sizeof(lat_str) - 1);
                break;
            case 3:
                ns = token[0];
                break;
            case 4:
                strncpy(lon_str, token, sizeof(lon_str) - 1);
                break;
            case 5:
                ew = token[0];
                break;
            case 6:
                strncpy(fix_str, token, sizeof(fix_str) - 1);
                break;
            case 9:
                strncpy(alt_str, token, sizeof(alt_str) - 1);
                break;
            default:
                break;
        }

        token = strtok_r(NULL, ",", &saveptr);
        field_index++;
    }

    *fix_quality = atoi(fix_str);

    if (*fix_quality > 0) {
        *latitude = nmea_to_decimal(lat_str, ns);
        *longitude = nmea_to_decimal(lon_str, ew);
        *altitude = (alt_str[0] != '\0') ? atof(alt_str) : NAN;
    } else {
        *latitude = NAN;
        *longitude = NAN;
        *altitude = NAN;
    }

    return true;
}

// -------------------------------------------------
// Init GPIO
// -------------------------------------------------
static void init_gpio_sensores(void)
{
    gpio_config_t bumper_conf = {
        .pin_bit_mask = (1ULL<<PIN_B_L) | (1ULL<<PIN_B_C) | (1ULL<<PIN_B_R),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE
    };
    gpio_config(&bumper_conf);

    gpio_config_t echo_conf = {
        .pin_bit_mask = (1ULL<<ECHO_IZQ) | (1ULL<<ECHO_CEN) | (1ULL<<ECHO_DER),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE
    };
    gpio_config(&echo_conf);

    gpio_set_direction(TRIG_IZQ, GPIO_MODE_OUTPUT);
    gpio_set_direction(TRIG_CEN, GPIO_MODE_OUTPUT);
    gpio_set_direction(TRIG_DER, GPIO_MODE_OUTPUT);

    gpio_set_level(TRIG_IZQ, 0);
    gpio_set_level(TRIG_CEN, 0);
    gpio_set_level(TRIG_DER, 0);
}

// -------------------------------------------------
// Init I2C + MPU
// -------------------------------------------------
static void init_i2c_mpu(void)
{
    i2c_config_t i2c_c = {
        .mode = I2C_MODE_MASTER,
        .sda_io_num = I2C_MASTER_SDA_IO,
        .scl_io_num = I2C_MASTER_SCL_IO,
        .sda_pullup_en = GPIO_PULLUP_ENABLE,
        .scl_pullup_en = GPIO_PULLUP_ENABLE,
        .master.clk_speed = I2C_MASTER_FREQ_HZ
    };

    i2c_param_config(I2C_MASTER_NUM, &i2c_c);
    i2c_driver_install(I2C_MASTER_NUM, I2C_MODE_MASTER, 0, 0, 0);

    i2c_master_write_to_device(
        I2C_MASTER_NUM,
        MPU_ADDR,
        (uint8_t[]){MPU_PWR_MGMT_1, 0x00},
        2,
        pdMS_TO_TICKS(100)
    );

    vTaskDelay(pdMS_TO_TICKS(100));
}

static void calibrar_mpu(void)
{
    float sx = 0, sy = 0, sz = 0;
    uint8_t r[14];

    for (int i = 0; i < 300; i++) {
        if (i2c_master_write_read_device(
                I2C_MASTER_NUM,
                MPU_ADDR,
                (uint8_t[]){MPU_ACCEL_XOUT_H},
                1,
                r,
                14,
                pdMS_TO_TICKS(50)
            ) == ESP_OK) {

            sx += (float)((int16_t)(r[8]  << 8 | r[9]))  / GYRO_SENS;
            sy += (float)((int16_t)(r[10] << 8 | r[11])) / GYRO_SENS;
            sz += (float)((int16_t)(r[12] << 8 | r[13])) / GYRO_SENS;
        }
        vTaskDelay(pdMS_TO_TICKS(1));
    }

    gx_off = sx / 300.0f;
    gy_off = sy / 300.0f;
    gz_off = sz / 300.0f;
}

// -------------------------------------------------
// Init GPS UART
// -------------------------------------------------
static void init_gps_uart(void)
{
    uart_config_t uart_config = {
        .baud_rate = GPS_BAUD_RATE,
        .data_bits = UART_DATA_8_BITS,
        .parity    = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };

    ESP_ERROR_CHECK(uart_driver_install(GPS_UART_NUM, GPS_BUF_SIZE * 2, 0, 0, NULL, 0));
    ESP_ERROR_CHECK(uart_param_config(GPS_UART_NUM, &uart_config));
    ESP_ERROR_CHECK(uart_set_pin(
        GPS_UART_NUM,
        GPS_TX_PIN,
        GPS_RX_PIN,
        UART_PIN_NO_CHANGE,
        UART_PIN_NO_CHANGE
    ));
}

// -------------------------------------------------
// Task: Bumpers
// Core 1 - rápida
// -------------------------------------------------
void bumper_task(void *arg)
{
    while (1) {
        float b_l = (gpio_get_level(PIN_B_L) == 0) ? 1.0f : 0.0f;
        float b_c = (gpio_get_level(PIN_B_C) == 0) ? 1.0f : 0.0f;
        float b_r = (gpio_get_level(PIN_B_R) == 0) ? 1.0f : 0.0f;

        xSemaphoreTake(g_data_mutex, portMAX_DELAY);
        g_bumper_l = b_l;
        g_bumper_c = b_c;
        g_bumper_r = b_r;
        xSemaphoreGive(g_data_mutex);

        vTaskDelay(pdMS_TO_TICKS(BUMPER_PERIOD_MS));
    }
}

// -------------------------------------------------
// Task: Ultrasonidos
// Core 0 - lenta/bloqueante
// -------------------------------------------------
void ultrasonic_task(void *arg)
{
    while (1) {
        float izq, cen, der;

        izq = medirDistancia(TRIG_IZQ, ECHO_IZQ);
        vTaskDelay(pdMS_TO_TICKS(DESFASE_MS));

        cen = medirDistancia(TRIG_CEN, ECHO_CEN);
        vTaskDelay(pdMS_TO_TICKS(DESFASE_MS));

        der = medirDistancia(TRIG_DER, ECHO_DER);

        xSemaphoreTake(g_data_mutex, portMAX_DELAY);

        g_dist_izq = izq;
        g_t_izq_us = esp_timer_get_time();

        g_dist_cen = cen;
        g_t_cen_us = esp_timer_get_time();

        g_dist_der = der;
        g_t_der_us = esp_timer_get_time();

        xSemaphoreGive(g_data_mutex);

        vTaskDelay(pdMS_TO_TICKS(DESFASE_MS));
    }
}

// -------------------------------------------------
// Task: GPS
// Core 0 - lenta
// -------------------------------------------------
void gps_task(void *arg)
{
    uint8_t gps_data[GPS_BUF_SIZE];
    char line[256];
    int line_pos = 0;

    while (1) {
        int len = uart_read_bytes(
            GPS_UART_NUM,
            gps_data,
            sizeof(gps_data),
            pdMS_TO_TICKS(20)
        );

        if (len > 0) {
            for (int i = 0; i < len; i++) {
                char c = (char)gps_data[i];

                if (c == '\r') {
                    continue;
                }

                if (c == '\n') {
                    if (line_pos > 0) {
                        line[line_pos] = '\0';

                        double lat, lon, alt;
                        int fix_quality;

                        if (parse_gga_line(line, &lat, &lon, &alt, &fix_quality)) {
                            xSemaphoreTake(g_data_mutex, portMAX_DELAY);

                            g_gps_lat = (float)lat;
                            g_gps_lon = (float)lon;
                            g_gps_alt = (float)alt;
                            g_gps_fix = (float)fix_quality;
                            g_t_gps_us = esp_timer_get_time();

                            xSemaphoreGive(g_data_mutex);
                        }

                        line_pos = 0;
                    }
                } else {
                    if (line_pos < (int)(sizeof(line) - 1)) {
                        line[line_pos++] = c;
                    } else {
                        line_pos = 0;
                    }
                }
            }
        }

        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

// -------------------------------------------------
// Task: IMU
// Core 1 - rápida
// -------------------------------------------------
void imu_task(void *arg)
{
    uint8_t r[14];
    float roll_local = 0.0f;
    float pitch_local = 0.0f;
    float yaw_local = 0.0f;
    int64_t last_time_us = esp_timer_get_time();

    while (1) {
        if (i2c_master_write_read_device(
                I2C_MASTER_NUM,
                MPU_ADDR,
                (uint8_t[]){MPU_ACCEL_XOUT_H},
                1,
                r,
                14,
                pdMS_TO_TICKS(50)
            ) == ESP_OK) {

            int64_t now = esp_timer_get_time();
            float dt = (float)(now - last_time_us) / 1000000.0f;
            last_time_us = now;

            if (dt <= 0.0f || dt > 0.5f) dt = 0.01f;

            float ax = (float)((int16_t)(r[0]  << 8 | r[1])) / ACCEL_SENS;
            float ay = (float)((int16_t)(r[2]  << 8 | r[3])) / ACCEL_SENS;
            float az = (float)((int16_t)(r[4]  << 8 | r[5])) / ACCEL_SENS;
            float gx = ((float)((int16_t)(r[8]  << 8 | r[9]))  / GYRO_SENS) - gx_off;
            float gy = ((float)((int16_t)(r[10] << 8 | r[11])) / GYRO_SENS) - gy_off;
            float gz = ((float)((int16_t)(r[12] << 8 | r[13])) / GYRO_SENS) - gz_off;

            float r_acc = atan2f(ay, az) * RAD_TO_DEG;
            float p_acc = atan2f(-ax, sqrtf(ay * ay + az * az)) * RAD_TO_DEG;

            roll_local  = ALPHA * (roll_local  + gx * dt) + (1.0f - ALPHA) * r_acc;
            pitch_local = ALPHA * (pitch_local + gy * dt) + (1.0f - ALPHA) * p_acc;
            yaw_local  += gz * dt;

            xSemaphoreTake(g_data_mutex, portMAX_DELAY);
            g_roll = roll_local;
            g_pitch = pitch_local;
            g_yaw = yaw_local;
            xSemaphoreGive(g_data_mutex);
        }

        vTaskDelay(pdMS_TO_TICKS(IMU_PERIOD_MS));
    }
}

// -------------------------------------------------
// Task: Micro-ROS Publish
// Core 1 - rápida
// -------------------------------------------------
void micro_ros_task(void *arg)
{
    vTaskDelay(pdMS_TO_TICKS(1000));

    rcl_allocator_t allocator = rcl_get_default_allocator();
    rclc_support_t support;
    RCCHECK(rclc_support_init(&support, 0, NULL, &allocator));

    vTaskDelay(pdMS_TO_TICKS(500));

    rcl_node_t node;
    RCCHECK(rclc_node_init_default(&node, "esp32_sensor_node", "/", &support));

    vTaskDelay(pdMS_TO_TICKS(500));

    rcl_publisher_t pub;
    RCCHECK(rclc_publisher_init_default(
        &pub,
        &node,
        ROSIDL_GET_MSG_TYPE_SUPPORT(std_msgs, msg, Float32MultiArray),
        "sensores"
    ));

    std_msgs__msg__Float32MultiArray msg;
    std_msgs__msg__Float32MultiArray__init(&msg);
    msg.data.data = (float *)malloc(SENSORES_SIZE * sizeof(float));
    msg.data.size = SENSORES_SIZE;
    msg.data.capacity = SENSORES_SIZE;
    msg.layout.dim.size = 0;
    msg.layout.dim.capacity = 0;

    while (1) {
        float bumper_l, bumper_c, bumper_r;
        float dist_izq, dist_cen, dist_der;
        float roll, pitch, yaw;
        float gps_lat, gps_lon, gps_alt, gps_fix;
        int64_t t_izq, t_cen, t_der, t_gps;
        int64_t ahora = esp_timer_get_time();

        xSemaphoreTake(g_data_mutex, portMAX_DELAY);

        bumper_l = g_bumper_l;
        bumper_c = g_bumper_c;
        bumper_r = g_bumper_r;

        dist_izq = g_dist_izq;  t_izq = g_t_izq_us;
        dist_cen = g_dist_cen;  t_cen = g_t_cen_us;
        dist_der = g_dist_der;  t_der = g_t_der_us;

        roll = g_roll;
        pitch = g_pitch;
        yaw = g_yaw;

        gps_lat = g_gps_lat;
        gps_lon = g_gps_lon;
        gps_alt = g_gps_alt;
        gps_fix = g_gps_fix;
        t_gps = g_t_gps_us;

        xSemaphoreGive(g_data_mutex);

        // Bumpers desde cache
        msg.data.data[0] = bumper_l;
        msg.data.data[1] = bumper_c;
        msg.data.data[2] = bumper_r;

        // Ultrasonidos desde cache
        msg.data.data[3] = ultra_para_publicar(dist_izq, t_izq, ahora);
        msg.data.data[4] = ultra_para_publicar(dist_cen, t_cen, ahora);
        msg.data.data[5] = ultra_para_publicar(dist_der, t_der, ahora);

        // IMU desde cache
        msg.data.data[6] = roll;
        msg.data.data[7] = pitch;
        msg.data.data[8] = yaw;

        // GPS desde cache
        msg.data.data[9]  = gps_para_publicar(gps_lat, t_gps, ahora);
        msg.data.data[10] = gps_para_publicar(gps_lon, t_gps, ahora);
        msg.data.data[11] = gps_para_publicar(gps_alt, t_gps, ahora);
        msg.data.data[12] = gps_fix_para_publicar(gps_fix, t_gps, ahora);

        rcl_ret_t pub_rc = rcl_publish(&pub, &msg, NULL);
        if (pub_rc != RCL_RET_OK) {
            ESP_LOGW("ROS", "rcl_publish fallo: %d", (int)pub_rc);
        }

        vTaskDelay(pdMS_TO_TICKS(ROS_PUBLISH_MS));
    }
}