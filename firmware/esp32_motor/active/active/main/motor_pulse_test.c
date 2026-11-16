// Prueba manual de traccion y bordeadora, maximo1000ms por orden.
// No hay movimiento al arrancar. Potencia apagada durante carga/reset.
#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "driver/uart.h"
#include "driver/ledc.h"
#include "esp_timer.h"

#define DUTY 100
#define PULSE_US 1000000
#define TRIMMER_UART UART_NUM_2
#define TRIMMER_TX GPIO_NUM_17
#define TRIMMER_STOP 64
#define TRIMMER_MIN_START 74
#define TRIMMER_MAX 85
#define TRIMMER_STEP 2
#define TRIMMER_RAMP_MS 30
#define CUTTER_ENABLE GPIO_NUM_18
static esp_timer_handle_t stop_timer;

static void cutter_stop(void)
{
    gpio_set_level(CUTTER_ENABLE, 0);
}

static void trimmer_stop(void)
{
    const uint8_t stop = TRIMMER_STOP;
    uart_write_bytes(TRIMMER_UART, &stop, 1);
    uart_wait_tx_done(TRIMMER_UART, pdMS_TO_TICKS(20));
}

static void motors_stop(void *arg)
{
    (void)arg;
    // Forzar salida LOW como respaldo si falla la actualizacion de duty.
    for (int ch=0;ch<4;ch++) {
        if (ledc_set_duty_and_update(LEDC_LOW_SPEED_MODE,(ledc_channel_t)ch,0,0)!=ESP_OK)
            ledc_stop(LEDC_LOW_SPEED_MODE,(ledc_channel_t)ch,0);
    }
}

static void pulse(char command)
{
    motors_stop(NULL);
    vTaskDelay(pdMS_TO_TICKS(3)); // Todos LOW antes de seleccionar direccion.
    int left=0, right=0;
    const char *name;
    switch (command) {
        case 'i': left=1; name="IZQUIERDO ADELANTE"; break;
        case 'b': left=1; right=1; name="AMBOS ADELANTE"; break;
        case 'r': left=-1; right=-1; name="AMBOS ATRAS"; break;
        case 'l': left=-1; right=1; name="GIRO IZQUIERDA"; break;
        case 'd': left=1; right=-1; name="GIRO DERECHA"; break;
        default: return;
    }
    printf("PULSO %s: PWM=%d/255; maximo1000ms.\n", name, DUTY);
    fflush(stdout);
    const unsigned duty[4] = {left>0 ? DUTY : 0, right>0 ? DUTY : 0,
                              left<0 ? DUTY : 0, right<0 ? DUTY : 0};
    for (int ch=0;ch<4;ch++) {
        esp_err_t channel_rc=ledc_set_duty_and_update(LEDC_LOW_SPEED_MODE,(ledc_channel_t)ch,duty[ch],0);
        if (channel_rc!=ESP_OK) {motors_stop(NULL); ESP_ERROR_CHECK(channel_rc);}
    }
    esp_err_t rc=esp_timer_start_once(stop_timer, PULSE_US);
    if (rc!=ESP_OK) {motors_stop(NULL); ESP_ERROR_CHECK(rc);}
    int64_t started=esp_timer_get_time();
    int64_t deadline=started+PULSE_US;
    // El duty se refleja en el hardware al siguiente periodo PWM (1 ms).
    vTaskDelay(pdMS_TO_TICKS(3));
    printf("PWM APLICADO: izquierda=%lu derecha=%lu\n",
           (unsigned long)(ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_0)+ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_2)),
           (unsigned long)(ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_1)+ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_3)));
    printf("CANALES: GPIO32=%lu GPIO25=%lu GPIO33=%lu GPIO26=%lu\n",
           (unsigned long)ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_0),
           (unsigned long)ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_1),
           (unsigned long)ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_2),
           (unsigned long)ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_3));
    fflush(stdout);
    while (esp_timer_get_time()<deadline && esp_timer_is_active(stop_timer)) {
        uint8_t c;
        if (uart_read_bytes(UART_NUM_0,&c,1,pdMS_TO_TICKS(10))==1 && (c=='s'||c=='S')) break;
    }
    motors_stop(NULL);
    esp_timer_stop(stop_timer); // Puede haber vencido normalmente.
    uart_flush_input(UART_NUM_0); // No encadenar comandos acumulados durante el pulso.
    vTaskDelay(pdMS_TO_TICKS(3)); // Esperar el latch del duty cero antes de comprobarlo.
    printf("PARADO: izquierda=%lu derecha=%lu duracion_ms=%lld. i=izquierdo b=adelante r=atras l=giro_izq d=giro_der (+Enter); s=stop.\n",
           (unsigned long)(ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_0)+ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_2)),
           (unsigned long)(ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_1)+ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_3)),
           (long long)((esp_timer_get_time()-started)/1000));
    fflush(stdout);
}

static void trimmer_test(void)
{
    motors_stop(NULL);
    trimmer_stop();
    const int64_t started = esp_timer_get_time();
    const int64_t deadline = started + PULSE_US;
    int speed = TRIMMER_MIN_START;

    printf("BORDEADORA: rampa %d->%d, maximo1000ms; s=stop inmediato.\n",
           TRIMMER_MIN_START, TRIMMER_MAX);
    fflush(stdout);

    while (esp_timer_get_time() < deadline) {
        const uint8_t value = (uint8_t)speed;
        uart_write_bytes(TRIMMER_UART, &value, 1);
        uart_wait_tx_done(TRIMMER_UART, pdMS_TO_TICKS(20));
        printf("BORDEADORA comando=%d\n", speed);
        fflush(stdout);

        const int64_t wait_until = esp_timer_get_time() + TRIMMER_RAMP_MS * 1000LL;
        while (esp_timer_get_time() < wait_until && esp_timer_get_time() < deadline) {
            uint8_t c;
            if (uart_read_bytes(UART_NUM_0, &c, 1, pdMS_TO_TICKS(5)) == 1 &&
                (c == 's' || c == 'S')) {
                trimmer_stop();
                uart_flush_input(UART_NUM_0);
                printf("BORDEADORA PARADA por usuario.\n");
                fflush(stdout);
                return;
            }
        }
        if (speed < TRIMMER_MAX) {
            speed += TRIMMER_STEP;
            if (speed > TRIMMER_MAX) speed = TRIMMER_MAX;
        }
    }

    trimmer_stop();
    uart_flush_input(UART_NUM_0);
    printf("BORDEADORA PARADA: comando=%d duracion_ms=%lld.\n",
           TRIMMER_STOP, (long long)((esp_timer_get_time() - started) / 1000));
    fflush(stdout);
}

static void cutter_test(void)
{
    motors_stop(NULL);
    trimmer_stop();
    cutter_stop();
    vTaskDelay(pdMS_TO_TICKS(10));

    const int64_t started = esp_timer_get_time();
    const int64_t deadline = started + PULSE_US;
    gpio_set_level(CUTTER_ENABLE, 1);
    printf("CORTADORA CENTRAL HABILITADA: GPIO18=HIGH, maximo1000ms; s=stop inmediato.\n");
    fflush(stdout);

    while (esp_timer_get_time() < deadline) {
        uint8_t c;
        if (uart_read_bytes(UART_NUM_0, &c, 1, pdMS_TO_TICKS(5)) == 1 &&
            (c == 's' || c == 'S')) {
            break;
        }
    }

    cutter_stop();
    uart_flush_input(UART_NUM_0);
    printf("CORTADORA CENTRAL INHIBIDA: GPIO18=LOW duracion_ms=%lld.\n",
           (long long)((esp_timer_get_time() - started) / 1000));
    fflush(stdout);
}

void app_main(void)
{
    const gpio_num_t pins[]={GPIO_NUM_32,GPIO_NUM_33,GPIO_NUM_25,GPIO_NUM_26,GPIO_NUM_18};
    uint64_t mask=0;
    for (unsigned i=0;i<sizeof(pins)/sizeof(pins[0]);i++) {
        ESP_ERROR_CHECK(gpio_set_level(pins[i],0)); mask |= 1ULL<<pins[i];
    }
    gpio_config_t safe={.pin_bit_mask=mask,.mode=GPIO_MODE_OUTPUT,
                        .pull_down_en=GPIO_PULLDOWN_ENABLE,.intr_type=GPIO_INTR_DISABLE};
    ESP_ERROR_CHECK(gpio_config(&safe));
    ledc_timer_config_t timer={.speed_mode=LEDC_LOW_SPEED_MODE,.duty_resolution=LEDC_TIMER_8_BIT,
                              .timer_num=LEDC_TIMER_0,.freq_hz=1000,.clk_cfg=LEDC_AUTO_CLK};
    ESP_ERROR_CHECK(ledc_timer_config(&timer));
    ledc_channel_config_t channel={.gpio_num=GPIO_NUM_32,.speed_mode=LEDC_LOW_SPEED_MODE,
                                  .channel=LEDC_CHANNEL_0,.timer_sel=LEDC_TIMER_0,.duty=0,.hpoint=0};
    ESP_ERROR_CHECK(ledc_channel_config(&channel));
    channel.gpio_num=GPIO_NUM_25;
    channel.channel=LEDC_CHANNEL_1;
    ESP_ERROR_CHECK(ledc_channel_config(&channel));
    channel.gpio_num=GPIO_NUM_33;
    channel.channel=LEDC_CHANNEL_2;
    ESP_ERROR_CHECK(ledc_channel_config(&channel));
    channel.gpio_num=GPIO_NUM_26;
    channel.channel=LEDC_CHANNEL_3;
    ESP_ERROR_CHECK(ledc_channel_config(&channel));
    // ledc_set_duty_and_update requiere este servicio incluso sin usar rampas.
    ESP_ERROR_CHECK(ledc_fade_func_install(0));
    esp_timer_create_args_t args={.callback=motors_stop,.name="motors_stop"};
    ESP_ERROR_CHECK(esp_timer_create(&args,&stop_timer));
    ESP_ERROR_CHECK(uart_driver_install(UART_NUM_0,256,0,0,NULL,0));
    ESP_ERROR_CHECK(uart_flush_input(UART_NUM_0));
    uart_config_t trimmer_uart = {
        .baud_rate = 9600,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    ESP_ERROR_CHECK(uart_driver_install(TRIMMER_UART, 256, 0, 0, NULL, 0));
    ESP_ERROR_CHECK(uart_param_config(TRIMMER_UART, &trimmer_uart));
    ESP_ERROR_CHECK(uart_set_pin(TRIMMER_UART, TRIMMER_TX, UART_PIN_NO_CHANGE,
                                 UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));
    vTaskDelay(pdMS_TO_TICKS(50));
    trimmer_stop();
    printf("\nPRUEBA MANUAL LISTA Y PARADA. Traccion PWM100/255; bordeadora comando64; cortadora central GPIO18 LOW.\n");
    printf("i/b/r/l/d=traccion; e=bordeadora; c=cortadora central; s=stop inmediato. Orden + Enter; maximo1000ms. Sin micro-ROS.\n");
    fflush(stdout);
    char line[16]; unsigned len=0; bool overflow=false; int64_t last_status=0;
    while (1) {
        uint8_t c;
        if (uart_read_bytes(UART_NUM_0,&c,1,pdMS_TO_TICKS(20))==1) {
            if (c=='s'||c=='S') {motors_stop(NULL);trimmer_stop();cutter_stop();len=0;overflow=false;printf("TODO PARADO.\n");}
            else if (c=='\r'||c=='\n') {
                line[len]='\0';
                char command=!overflow && len==1 ? line[0] : '\0';
                bool fire=command && strchr("ibrldec",command)!=NULL;
                len=0;overflow=false;
                if (fire && command=='c') cutter_test();
                else if (fire && command=='e') trimmer_test();
                else if (fire) pulse(command);
            } else if (len<sizeof(line)-1) line[len++]=(char)c;
            else overflow=true;
        }
        if (esp_timer_get_time()-last_status>=3000000) {
            printf("TODO PARADO | traccion izq PWM=%lu der PWM=%lu | e=bordeadora c=cortadora central; i/b/r/l/d=traccion (+Enter), 1000ms; s=stop\n",
                   (unsigned long)(ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_0)+ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_2)),
                   (unsigned long)(ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_1)+ledc_get_duty(LEDC_LOW_SPEED_MODE,LEDC_CHANNEL_3)));
            fflush(stdout);last_status=esp_timer_get_time();
        }
    }
}
