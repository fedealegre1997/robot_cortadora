/home/angel-alegre/robot_cortadora/SOP_Seguimiento_Y_Operacion.md// Author: Angel Alegre
// Name: 2026_04_16_test_mc33926_arduino.cpp
// Descripcion: Código de prueba para el driver de motores MC33926.
// Version: 1.1 Arduino IDE
// Fecha: 31/05/2026

#include <Arduino.h>
#include "driver/ledc.h"

// =====================================================
// CONEXIONES DEL DRIVER MC33926
// =====================================================
// VDD  -> 3V3 del ESP32-S3
// GND  -> GND común entre ESP32-S3 y fuente de motores
// VIN  -> positivo de la batería/fuente de motores
//
// M1_IN1 = M1_Pwm1 (verde abajo)
// M1_IN2 = M1_Pwm2 (gris abajo)
// M2_IN1 = M2_Pwm1 (verde arriba)
// M2_IN2 = M2_Pwm2 (gris arriba)
// =====================================================

// Pines para ESP32-S3
#define M1_IN1_PIN   GPIO_NUM_4
#define M1_IN2_PIN   GPIO_NUM_5
#define M2_IN1_PIN   GPIO_NUM_6
#define M2_IN2_PIN   GPIO_NUM_7

// =====================================================
// PWM
// =====================================================
#define PWM_FREQ_HZ       1000
#define PWM_RESOLUTION    LEDC_TIMER_8_BIT
#define PWM_MAX_VALUE     255

#define PWM_MODE          LEDC_LOW_SPEED_MODE
#define PWM_TIMER         LEDC_TIMER_0

#define CH_M1_IN1         LEDC_CHANNEL_0
#define CH_M1_IN2         LEDC_CHANNEL_1
#define CH_M2_IN1         LEDC_CHANNEL_2
#define CH_M2_IN2         LEDC_CHANNEL_3

// =====================================================
// PRUEBA
// =====================================================
static const uint32_t tiempo_movimiento_ms = 3000;
static const uint32_t tiempo_pausa_ms      = 1000;
static const uint32_t velocidad_pwm        = 200;

// =====================================================
// AUXILIARES
// =====================================================
static void pwm_write(ledc_channel_t channel, uint32_t duty)
{
    if (duty > PWM_MAX_VALUE) {
        duty = PWM_MAX_VALUE;
    }

    ledc_set_duty(PWM_MODE, channel, duty);
    ledc_update_duty(PWM_MODE, channel);
}

static void set_outputs(uint32_t m1_in1, uint32_t m1_in2, uint32_t m2_in1, uint32_t m2_in2)
{
    pwm_write(CH_M1_IN1, m1_in1);
    pwm_write(CH_M1_IN2, m1_in2);
    pwm_write(CH_M2_IN1, m2_in1);
    pwm_write(CH_M2_IN2, m2_in2);
}

static void stop_motors(void)
{
    set_outputs(0, 0, 0, 0);
}

// =====================================================
// MOVIMIENTOS SEGÚN TU LÓGICA
// =====================================================

// ADELANTE = PWM, 0, 0, PWM
static void move_forward(uint32_t pwm)
{
    set_outputs(pwm, 0, 0, pwm);
}

// ATRÁS = 0, PWM, PWM, 0
static void move_backward(uint32_t pwm)
{
    set_outputs(0, pwm, pwm, 0);
}

// IZQUIERDA = 0, PWM, 0, PWM
static void move_left(uint32_t pwm)
{
    set_outputs(0, pwm, 0, pwm);
}

// DERECHA = PWM, 0, PWM, 0
static void move_right(uint32_t pwm)
{
    set_outputs(pwm, 0, pwm, 0);
}

// =====================================================
// INICIALIZACIÓN LEDC
// =====================================================
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

    ledc_channel_config(&ch_conf);
}

static void motor_hw_init(void)
{
    ledc_timer_config_t timer_conf = {
        .speed_mode       = PWM_MODE,
        .duty_resolution  = PWM_RESOLUTION,
        .timer_num        = PWM_TIMER,
        .freq_hz          = PWM_FREQ_HZ,
        .clk_cfg          = LEDC_AUTO_CLK
    };

    ledc_timer_config(&timer_conf);

    ledc_init_channel(M1_IN1_PIN, CH_M1_IN1);
    ledc_init_channel(M1_IN2_PIN, CH_M1_IN2);
    ledc_init_channel(M2_IN1_PIN, CH_M2_IN1);
    ledc_init_channel(M2_IN2_PIN, CH_M2_IN2);

    stop_motors();
}

// =====================================================
// SETUP - ARDUINO IDE
// =====================================================
void setup()
{
    Serial.begin(115200);
    delay(2000);

    Serial.println();
    Serial.println("--- PRUEBA DE MOTORES MC33926 ---");
    Serial.printf("PWM=%lu | Tiempo movimiento=%lu ms\n",
                  (unsigned long)velocidad_pwm,
                  (unsigned long)tiempo_movimiento_ms);

    motor_hw_init();

    delay(2000);
}

// =====================================================
// LOOP - ARDUINO IDE
// =====================================================
void loop()
{
    Serial.println("ADELANTE");
    move_forward(velocidad_pwm);
    delay(tiempo_movimiento_ms);

    Serial.println("STOP");
    stop_motors();
    delay(tiempo_pausa_ms);

    Serial.println("ATRAS");
    move_backward(velocidad_pwm);
    delay(tiempo_movimiento_ms);

    Serial.println("STOP");
    stop_motors();
    delay(tiempo_pausa_ms);

    Serial.println("IZQUIERDA");
    move_left(velocidad_pwm);
    delay(tiempo_movimiento_ms);

    Serial.println("STOP");
    stop_motors();
    delay(tiempo_pausa_ms);

    Serial.println("DERECHA");
    move_right(velocidad_pwm);
    delay(tiempo_movimiento_ms);

    Serial.println("STOP");
    stop_motors();
    delay(tiempo_pausa_ms);
}