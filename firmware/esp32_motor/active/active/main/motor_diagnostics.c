// ESP32 clasico: solo diagnostico I2C. Sin micro-ROS, PWM ni ordenes de movimiento.
#include <stdio.h>
#include <stdint.h>
#include <math.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "driver/i2c.h"
#include "esp_timer.h"

#define BUS I2C_NUM_0
#define SDA GPIO_NUM_27
#define SCL GPIO_NUM_14
#define WAIT pdMS_TO_TICKS(50)

static esp_err_t read_regs(uint8_t addr, uint8_t reg, uint8_t *out, size_t len)
{
    return i2c_master_write_read_device(BUS, addr, &reg, 1, out, len, WAIT);
}
static esp_err_t write_reg(uint8_t addr, uint8_t reg, uint8_t val)
{
    uint8_t data[] = {reg, val};
    return i2c_master_write_to_device(BUS, addr, data, 2, WAIT);
}
static int16_t sample(const uint8_t *data)
{
    return (int16_t)(((uint16_t)data[0] << 8) | data[1]);
}
void app_main(void)
{
    // Precargar LOW antes de habilitar las salidas. La potencia debe seguir apagada.
    const gpio_num_t outputs[] = {GPIO_NUM_32, GPIO_NUM_33, GPIO_NUM_25,
                                 GPIO_NUM_26, GPIO_NUM_18};
    uint64_t mask = 0;
    for (unsigned i=0; i<sizeof(outputs)/sizeof(outputs[0]); i++) {
        ESP_ERROR_CHECK(gpio_set_level(outputs[i], 0));
        mask |= 1ULL << outputs[i];
    }
    gpio_config_t pins = {.pin_bit_mask=mask, .mode=GPIO_MODE_OUTPUT,
                         .pull_down_en=GPIO_PULLDOWN_ENABLE, .intr_type=GPIO_INTR_DISABLE};
    ESP_ERROR_CHECK(gpio_config(&pins));
    printf("\nDIAGNOSTICO MOTOR: IN1/IN2 GPIO32/33/25/26 LOW; cortadora GPIO18 LOW. Potencia apagada.\n");
    i2c_config_t cfg = {.mode=I2C_MODE_MASTER, .sda_io_num=SDA, .scl_io_num=SCL,
                       .sda_pullup_en=GPIO_PULLUP_ENABLE, .scl_pullup_en=GPIO_PULLUP_ENABLE,
                       .master.clk_speed=100000};
    ESP_ERROR_CHECK(i2c_param_config(BUS, &cfg));
    ESP_ERROR_CHECK(i2c_driver_install(BUS, cfg.mode, 0, 0, 0));
    uint8_t addr=0, id=0;
    for (uint8_t candidate=0x68; candidate<=0x69; candidate++) {
        esp_err_t rc=read_regs(candidate, 0x75, &id, 1);
        printf("IMU SDA27/SCL14: addr=0x%02X resultado=%s WHO=0x%02X\n",candidate,esp_err_to_name(rc),id);
        if (rc==ESP_OK && id!=0 && id!=0xff) {addr=candidate; break;}
    }
    if (!addr) {
        while (1) {printf("IMU SIN RESPUESTA en 0x68/0x69. Salidas de traccion siguen LOW.\n"); vTaskDelay(pdMS_TO_TICKS(1000));}
    }
    const uint8_t config[][2]={{0x6b,1},{0x1a,3},{0x19,7},{0x1b,0},{0x1c,0},{0x1d,3}};
    for (unsigned i=0;i<sizeof(config)/sizeof(config[0]);i++) {
        ESP_ERROR_CHECK(write_reg(addr,config[i][0],config[i][1]));
        if (i==0) vTaskDelay(pdMS_TO_TICKS(100));
    }
    unsigned ok=0, errors=0;
    while (1) {
        uint8_t r[14];
        esp_err_t rc=read_regs(addr,0x3b,r,sizeof(r));
        if (rc==ESP_OK) {
            ok++;
            float ax=sample(r)/16384.0f, ay=sample(r+2)/16384.0f, az=sample(r+4)/16384.0f;
            printf("IMU addr=0x%02X WHO=0x%02X | OK=%u ERROR=%u | A[g]=%+.4f %+.4f %+.4f modulo=%.4f | G[dps RAW]=%+.4f %+.4f %+.4f\n",
                   addr,id,ok,errors,ax,ay,az,sqrtf(ax*ax+ay*ay+az*az),
                   sample(r+8)/131.0f,sample(r+10)/131.0f,sample(r+12)/131.0f);
        } else {errors++; printf("IMU ERROR=%s OK=%u ERROR=%u\n",esp_err_to_name(rc),ok,errors);}
        vTaskDelay(pdMS_TO_TICKS(250));
    }
}
