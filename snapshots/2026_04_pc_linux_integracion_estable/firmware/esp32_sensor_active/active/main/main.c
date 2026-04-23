//  Codigo Main con los sensores y publisher
//      actualmente incluye los sensores:
//          * Finales de Carrera
//          * GPS FSTR2
//          * MPU-6500
//          * Ultrasonicos (topic array, demo temporal con 1 sensor real)
//  Version 4.0
//  Fecha: 23/03/2026 21:48

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "driver/uart.h"
#include "driver/gpio.h"
#include "driver/i2c.h"
#include "esp_err.h"
#include "esp_timer.h"
#include "esp_rom_sys.h"

#include <rcl/rcl.h>
#include <rcl/error_handling.h>
#include <rclc/rclc.h>

#include <std_msgs/msg/u_int8_multi_array.h>
#include <std_msgs/msg/float32_multi_array.h>
#include <sensor_msgs/msg/nav_sat_fix.h>
#include <sensor_msgs/msg/imu.h>
#include <rosidl_runtime_c/string_functions.h>

#include <rmw_microxrcedds_c/config.h>
#include <rmw_microros/rmw_microros.h>
#include "esp32_serial_transport.h"

#define RCCHECK(fn) { rcl_ret_t temp_rc = fn; if ((temp_rc != RCL_RET_OK)) { vTaskDelete(NULL); } }
#define RCSOFTCHECK(fn) { rcl_ret_t temp_rc = fn; (void)temp_rc; }

// -------------------- BUMPERS --------------------
#define PIN_FINAL_LEFT   GPIO_NUM_18
#define PIN_FINAL_CENTER GPIO_NUM_22
#define PIN_FINAL_RIGHT  GPIO_NUM_19

// -------------------- GPS --------------------
#define GPS_UART_NUM   2
#define GPS_TX_PIN     17
#define GPS_RX_PIN     16
#define GPS_BAUD_RATE  9600
#define GPS_BUF_SIZE   256

// -------------------- MPU-6500 --------------------
#define I2C_MASTER_NUM      I2C_NUM_0
#define I2C_MASTER_SDA_IO   GPIO_NUM_21
#define I2C_MASTER_SCL_IO   GPIO_NUM_23
#define I2C_MASTER_FREQ_HZ  100000
#define I2C_TIMEOUT_MS      1000

#define MPU_ADDR            0x69
#define MPU_WHO_AM_I_REG    0x75
#define MPU_PWR_MGMT_1      0x6B
#define MPU_ACCEL_XOUT_H    0x3B

#define ACCEL_SENSITIVITY   16384.0f   // ±2g
#define GYRO_SENSITIVITY    131.0f     // ±250 dps
#define GRAVITY_MS2         9.80665f
#define DEG_TO_RAD          0.01745329251f

// -------------------- ULTRASONICO --------------------
// Demo temporal:
//  - izquierdo = real
//  - centro    = fake
//  - derecho   = fake
#define ULTRA_TRIG_PIN      GPIO_NUM_25
#define ULTRA_ECHO_PIN      GPIO_NUM_32

static size_t uart_port = 0;   // micro-ROS por USB/UART0

rcl_publisher_t bumpers_publisher;
rcl_publisher_t gps_publisher;
rcl_publisher_t imu_publisher;
rcl_publisher_t ultrasonic_publisher;

std_msgs__msg__UInt8MultiArray bumpers_msg;
std_msgs__msg__Float32MultiArray ultrasonic_msg;
sensor_msgs__msg__NavSatFix gps_msg;
sensor_msgs__msg__Imu imu_msg;

static float ultima_distancia_valida = 20.0f;

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
// MPU helpers
// -------------------------------------------------
static esp_err_t i2c_master_init(void)
{
    i2c_config_t conf = {
        .mode = I2C_MODE_MASTER,
        .sda_io_num = I2C_MASTER_SDA_IO,
        .scl_io_num = I2C_MASTER_SCL_IO,
        .sda_pullup_en = GPIO_PULLUP_ENABLE,
        .scl_pullup_en = GPIO_PULLUP_ENABLE,
        .master.clk_speed = I2C_MASTER_FREQ_HZ,
        .clk_flags = 0
    };

    ESP_ERROR_CHECK(i2c_param_config(I2C_MASTER_NUM, &conf));
    return i2c_driver_install(I2C_MASTER_NUM, conf.mode, 0, 0, 0);
}

static esp_err_t mpu_read_register(uint8_t reg, uint8_t *data, size_t len)
{
    return i2c_master_write_read_device(
        I2C_MASTER_NUM,
        MPU_ADDR,
        &reg, 1,
        data, len,
        pdMS_TO_TICKS(I2C_TIMEOUT_MS)
    );
}

static esp_err_t mpu_write_register(uint8_t reg, uint8_t value)
{
    uint8_t write_buf[2] = {reg, value};
    return i2c_master_write_to_device(
        I2C_MASTER_NUM,
        MPU_ADDR,
        write_buf, sizeof(write_buf),
        pdMS_TO_TICKS(I2C_TIMEOUT_MS)
    );
}

static int16_t make_int16(uint8_t msb, uint8_t lsb)
{
    return (int16_t)((msb << 8) | lsb);
}

// -------------------------------------------------
// Ultrasonico helpers
// -------------------------------------------------
static void ultrasonic_gpio_init(void)
{
    gpio_config_t io_conf = {0};

    // TRIG como salida
    io_conf.pin_bit_mask = (1ULL << ULTRA_TRIG_PIN);
    io_conf.mode = GPIO_MODE_OUTPUT;
    io_conf.pull_up_en = GPIO_PULLUP_DISABLE;
    io_conf.pull_down_en = GPIO_PULLDOWN_DISABLE;
    io_conf.intr_type = GPIO_INTR_DISABLE;
    ESP_ERROR_CHECK(gpio_config(&io_conf));

    // ECHO como entrada
    io_conf.pin_bit_mask = (1ULL << ULTRA_ECHO_PIN);
    io_conf.mode = GPIO_MODE_INPUT;
    io_conf.pull_up_en = GPIO_PULLUP_DISABLE;
    io_conf.pull_down_en = GPIO_PULLDOWN_DISABLE;
    io_conf.intr_type = GPIO_INTR_DISABLE;
    ESP_ERROR_CHECK(gpio_config(&io_conf));

    gpio_set_level(ULTRA_TRIG_PIN, 0);
}

static float leer_ultrasonico_cm(void)
{
    // Pulso trigger de 10 us
    gpio_set_level(ULTRA_TRIG_PIN, 0);
    esp_rom_delay_us(3);
    gpio_set_level(ULTRA_TRIG_PIN, 1);
    esp_rom_delay_us(10);
    gpio_set_level(ULTRA_TRIG_PIN, 0);

    // Espera flanco de subida
    int64_t t0 = esp_timer_get_time();
    while (gpio_get_level(ULTRA_ECHO_PIN) == 0) {
        if ((esp_timer_get_time() - t0) > 30000) {
            return ultima_distancia_valida;
        }
    }

    // Mide el ancho del pulso de ECHO
    int64_t inicio = esp_timer_get_time();
    while (gpio_get_level(ULTRA_ECHO_PIN) == 1) {
        if ((esp_timer_get_time() - inicio) > 30000) {
            return ultima_distancia_valida;
        }
    }
    int64_t fin = esp_timer_get_time();

    float duracion_us = (float)(fin - inicio);
    float distancia_cm = duracion_us / 58.0f;

    if (distancia_cm < 2.0f || distancia_cm > 400.0f) {
        return ultima_distancia_valida;
    }

    ultima_distancia_valida = distancia_cm;
    return distancia_cm;
}

void micro_ros_task(void * arg)
{
    (void)arg;

    rcl_allocator_t allocator = rcl_get_default_allocator();
    rclc_support_t support;

    bool imu_ok = false;

    // -------------------- Init MPU --------------------
    if (i2c_master_init() == ESP_OK) {
        vTaskDelay(pdMS_TO_TICKS(200));

        uint8_t who_am_i = 0;
        esp_err_t mpu_ret = mpu_read_register(MPU_WHO_AM_I_REG, &who_am_i, 1);

        if (mpu_ret == ESP_OK && who_am_i == 0x70) {
            mpu_ret = mpu_write_register(MPU_PWR_MGMT_1, 0x00);
            if (mpu_ret == ESP_OK) {
                vTaskDelay(pdMS_TO_TICKS(100));
                imu_ok = true;
            }
        }
    }

    // -------------------- Init micro-ROS --------------------
    RCCHECK(rclc_support_init(&support, 0, NULL, &allocator));

    rcl_node_t node;
    RCCHECK(rclc_node_init_default(&node, "esp32_sensor_node", "", &support));

    // -------------------- Publisher bumpers --------------------
    RCCHECK(rclc_publisher_init_best_effort(
        &bumpers_publisher,
        &node,
        ROSIDL_GET_MSG_TYPE_SUPPORT(std_msgs, msg, UInt8MultiArray),
        "bumpers"));

    // -------------------- Publisher ultrasonicos --------------------
    RCCHECK(rclc_publisher_init_best_effort(
        &ultrasonic_publisher,
        &node,
        ROSIDL_GET_MSG_TYPE_SUPPORT(std_msgs, msg, Float32MultiArray),
        "ultrasonicos_cm"));

    // -------------------- Publisher GPS --------------------
    RCCHECK(rclc_publisher_init_best_effort(
        &gps_publisher,
        &node,
        ROSIDL_GET_MSG_TYPE_SUPPORT(sensor_msgs, msg, NavSatFix),
        "gps_fix"));

    // -------------------- Publisher IMU --------------------
    if (imu_ok) {
        RCCHECK(rclc_publisher_init_best_effort(
            &imu_publisher,
            &node,
            ROSIDL_GET_MSG_TYPE_SUPPORT(sensor_msgs, msg, Imu),
            "imu/data_raw"));
    }

    // -------------------- Config GPIO bumpers --------------------
    gpio_config_t io_conf = {
        .pin_bit_mask = (1ULL << PIN_FINAL_LEFT) |
                        (1ULL << PIN_FINAL_CENTER) |
                        (1ULL << PIN_FINAL_RIGHT),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE
    };
    ESP_ERROR_CHECK(gpio_config(&io_conf));

    // -------------------- Config GPIO ultrasonico --------------------
    ultrasonic_gpio_init();

    // -------------------- Init mensaje bumpers --------------------
    std_msgs__msg__UInt8MultiArray__init(&bumpers_msg);
    bumpers_msg.layout.data_offset = 0;
    bumpers_msg.data.data = (uint8_t *) malloc(3 * sizeof(uint8_t));
    if (bumpers_msg.data.data == NULL) {
        vTaskDelete(NULL);
    }
    bumpers_msg.data.size = 3;
    bumpers_msg.data.capacity = 3;
    bumpers_msg.data.data[0] = 0;
    bumpers_msg.data.data[1] = 0;
    bumpers_msg.data.data[2] = 0;

    // -------------------- Init mensaje ultrasonicos --------------------
    std_msgs__msg__Float32MultiArray__init(&ultrasonic_msg);
    ultrasonic_msg.layout.data_offset = 0;
    ultrasonic_msg.data.data = (float *) malloc(3 * sizeof(float));
    if (ultrasonic_msg.data.data == NULL) {
        vTaskDelete(NULL);
    }
    ultrasonic_msg.data.size = 3;
    ultrasonic_msg.data.capacity = 3;
    ultrasonic_msg.data.data[0] = 0.0f;   // izquierdo
    ultrasonic_msg.data.data[1] = 0.0f;   // centro
    ultrasonic_msg.data.data[2] = 0.0f;   // derecho

    // -------------------- Init mensaje GPS --------------------
    sensor_msgs__msg__NavSatFix__init(&gps_msg);
    rosidl_runtime_c__String__assign(&gps_msg.header.frame_id, "gps_link");
    gps_msg.position_covariance_type = 0;
    for (int i = 0; i < 9; i++) {
        gps_msg.position_covariance[i] = 0.0;
    }

    // -------------------- Init mensaje IMU --------------------
    if (imu_ok) {
        sensor_msgs__msg__Imu__init(&imu_msg);
        rosidl_runtime_c__String__assign(&imu_msg.header.frame_id, "imu_link");

        imu_msg.orientation.x = 0.0;
        imu_msg.orientation.y = 0.0;
        imu_msg.orientation.z = 0.0;
        imu_msg.orientation.w = 0.0;

        for (int i = 0; i < 9; i++) {
            imu_msg.orientation_covariance[i] = 0.0;
            imu_msg.angular_velocity_covariance[i] = 0.0;
            imu_msg.linear_acceleration_covariance[i] = 0.0;
        }
        imu_msg.orientation_covariance[0] = -1.0;
    }

    // -------------------- Config UART GPS --------------------
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
    ESP_ERROR_CHECK(uart_set_pin(GPS_UART_NUM, GPS_TX_PIN, GPS_RX_PIN, UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));

    uint8_t gps_data[GPS_BUF_SIZE];
    char line[256];
    int line_pos = 0;

    int64_t last_bumper_pub_us = 0;
    int64_t last_ultra_pub_us = 0;
    int64_t last_imu_pub_us = 0;

    while (1) {
        int64_t now_us = esp_timer_get_time();

        // -------------------- Publicar bumpers cada 100 ms --------------------
        if ((now_us - last_bumper_pub_us) >= 100000) {
            bumpers_msg.data.data[0] = (gpio_get_level(PIN_FINAL_LEFT)   == 0) ? 1 : 0;
            bumpers_msg.data.data[1] = (gpio_get_level(PIN_FINAL_CENTER) == 0) ? 1 : 0;
            bumpers_msg.data.data[2] = (gpio_get_level(PIN_FINAL_RIGHT)  == 0) ? 1 : 0;

            RCSOFTCHECK(rcl_publish(&bumpers_publisher, &bumpers_msg, NULL));
            last_bumper_pub_us = now_us;
        }

        // -------------------- Publicar ultrasonicos cada 200 ms --------------------
        if ((now_us - last_ultra_pub_us) >= 200000) {
            float base = leer_ultrasonico_cm();

            static int fase = 0;
            const float offset_centro[4] = {2.0f, 2.5f, 3.0f, 2.2f};
            const float offset_der[4]    = {-2.0f, -2.5f, -3.0f, -2.2f};

            ultrasonic_msg.data.data[0] = base;                        // izquierdo real
            ultrasonic_msg.data.data[1] = base + offset_centro[fase]; // centro fake
            ultrasonic_msg.data.data[2] = base + offset_der[fase];    // derecho fake

            if (ultrasonic_msg.data.data[1] < 2.0f) ultrasonic_msg.data.data[1] = 2.0f;
            if (ultrasonic_msg.data.data[2] < 2.0f) ultrasonic_msg.data.data[2] = 2.0f;

            RCSOFTCHECK(rcl_publish(&ultrasonic_publisher, &ultrasonic_msg, NULL));

            fase = (fase + 1) % 4;
            last_ultra_pub_us = now_us;
        }

        // -------------------- Publicar IMU cada 100 ms --------------------
        if (imu_ok && (now_us - last_imu_pub_us) >= 100000) {
            uint8_t raw_data[14];
            esp_err_t mpu_ret = mpu_read_register(MPU_ACCEL_XOUT_H, raw_data, sizeof(raw_data));

            if (mpu_ret == ESP_OK) {
                int16_t accel_x = make_int16(raw_data[0],  raw_data[1]);
                int16_t accel_y = make_int16(raw_data[2],  raw_data[3]);
                int16_t accel_z = make_int16(raw_data[4],  raw_data[5]);

                int16_t gyro_x  = make_int16(raw_data[8],  raw_data[9]);
                int16_t gyro_y  = make_int16(raw_data[10], raw_data[11]);
                int16_t gyro_z  = make_int16(raw_data[12], raw_data[13]);

                imu_msg.linear_acceleration.x = (accel_x / ACCEL_SENSITIVITY) * GRAVITY_MS2;
                imu_msg.linear_acceleration.y = (accel_y / ACCEL_SENSITIVITY) * GRAVITY_MS2;
                imu_msg.linear_acceleration.z = (accel_z / ACCEL_SENSITIVITY) * GRAVITY_MS2;

                imu_msg.angular_velocity.x = (gyro_x / GYRO_SENSITIVITY) * DEG_TO_RAD;
                imu_msg.angular_velocity.y = (gyro_y / GYRO_SENSITIVITY) * DEG_TO_RAD;
                imu_msg.angular_velocity.z = (gyro_z / GYRO_SENSITIVITY) * DEG_TO_RAD;

                imu_msg.header.stamp.sec = (int32_t)(now_us / 1000000LL);
                imu_msg.header.stamp.nanosec = (uint32_t)((now_us % 1000000LL) * 1000ULL);

                RCSOFTCHECK(rcl_publish(&imu_publisher, &imu_msg, NULL));
            }

            last_imu_pub_us = now_us;
        }

        // -------------------- Leer GPS --------------------
        int len = uart_read_bytes(GPS_UART_NUM, gps_data, sizeof(gps_data), pdMS_TO_TICKS(20));

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
                            int64_t stamp_us = esp_timer_get_time();
                            gps_msg.header.stamp.sec = (int32_t)(stamp_us / 1000000LL);
                            gps_msg.header.stamp.nanosec = (uint32_t)((stamp_us % 1000000LL) * 1000ULL);

                            if (fix_quality > 0) {
                                gps_msg.status.status = 0;
                                gps_msg.status.service = 1;
                                gps_msg.latitude = lat;
                                gps_msg.longitude = lon;
                                gps_msg.altitude = alt;
                            } else {
                                gps_msg.status.status = -1;
                                gps_msg.status.service = 1;
                                gps_msg.latitude = NAN;
                                gps_msg.longitude = NAN;
                                gps_msg.altitude = NAN;
                            }

                            RCSOFTCHECK(rcl_publish(&gps_publisher, &gps_msg, NULL));
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

        usleep(10000);
    }

    free(bumpers_msg.data.data);
    free(ultrasonic_msg.data.data);

    std_msgs__msg__UInt8MultiArray__fini(&bumpers_msg);
    std_msgs__msg__Float32MultiArray__fini(&ultrasonic_msg);
    sensor_msgs__msg__NavSatFix__fini(&gps_msg);

    RCCHECK(rcl_publisher_fini(&ultrasonic_publisher, &node));

    if (imu_ok) {
        sensor_msgs__msg__Imu__fini(&imu_msg);
        RCCHECK(rcl_publisher_fini(&imu_publisher, &node));
    }

    RCCHECK(rcl_publisher_fini(&bumpers_publisher, &node));
    RCCHECK(rcl_publisher_fini(&gps_publisher, &node));
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
        "uros_task",
        CONFIG_MICRO_ROS_APP_STACK,
        NULL,
        CONFIG_MICRO_ROS_APP_TASK_PRIO,
        NULL
    );
}