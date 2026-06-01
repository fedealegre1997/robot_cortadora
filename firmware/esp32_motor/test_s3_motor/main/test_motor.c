#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"

// Pines de prueba física para la placa ESP32-S3 (Motor Izquierdo de Propulsión)
#define PWM_PIN     GPIO_NUM_4
#define DIR_PIN     GPIO_NUM_5

void app_main(void)
{
    printf("=========================================================\n");
    printf("   PRUEBA SUPER SIMPLE DEL MOTOR (GPIO PURO - SIN PWM)\n");
    printf("   Pines: PWM (Velocidad) -> GPIO %d | DIR (Direccion) -> GPIO %d\n", PWM_PIN, DIR_PIN);
    printf("=========================================================\n");

    // Configurar pines como salidas digitales simples
    gpio_reset_pin(PWM_PIN);
    gpio_set_direction(PWM_PIN, GPIO_MODE_OUTPUT);

    gpio_reset_pin(DIR_PIN);
    gpio_set_direction(DIR_PIN, GPIO_MODE_OUTPUT);

    while (1) {
        // 1. Giro hacia adelante (DIR = 1, PWM = 1) durante 3 segundos
        printf("\n>>> Giro Adelante (DIR = 1) - 3 segundos...\n");
        gpio_set_level(DIR_PIN, 1);
        gpio_set_level(PWM_PIN, 1); // 100% velocidad
        vTaskDelay(pdMS_TO_TICKS(3000));

        // Parada de seguridad (PWM = 0) durante 1 segundo
        printf("Deteniendo motor (Pausa de 1 segundo)...\n");
        gpio_set_level(PWM_PIN, 0);
        vTaskDelay(pdMS_TO_TICKS(1000));

        // 2. Giro hacia atrás (DIR = 0, PWM = 1) durante 3 segundos
        printf("\n>>> Giro Atras (DIR = 0) - 3 segundos...\n");
        gpio_set_level(DIR_PIN, 0);
        gpio_set_level(PWM_PIN, 1); // 100% velocidad
        vTaskDelay(pdMS_TO_TICKS(3000));

        // Parada de seguridad (PWM = 0) antes de reiniciar el ciclo
        printf("Deteniendo motor (Pausa de 1 segundo)...\n");
        gpio_set_level(PWM_PIN, 0);
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
