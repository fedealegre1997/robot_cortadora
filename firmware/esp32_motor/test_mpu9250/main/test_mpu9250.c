//  Prueba aislada del IMU de la placa 3 (serigrafia "MPU-9250/6500/9255", chip marcado "MP92")
//  Placa: ESP32-S3 (N16R8 de prueba) o ESP32 clasico (futuro ESP32_motores)
//         El target se elige al compilar: build_test_mpu9250.sh [esp32s3|esp32]
//
//  Conexion (I2C a 3,3 V):
//      VCC -> 3V3 del ESP32
//      GND -> GND
//      SDA -> GPIO 6  (S3) / GPIO 21 (clasico)
//      SCL -> GPIO 7  (S3) / GPIO 22 (clasico)
//      AD0 -> GND o sin conectar (direccion 0x68); a 3V3 queda en 0x69
//      NCS -> a 3V3 si el chip no responde (en bajo queda en modo SPI)
//      El LSM9DS1 puede quedar en el mismo bus: no hay choque de direcciones.
//
//  Que hace:
//      1. Escanea el bus I2C y busca el MPU en 0x68/0x69.
//      2. Identifica el chip por WHO_AM_I (0x70 MPU-6500, 0x71 MPU-9250, 0x73 MPU-9255; otro
//         valor = posible clon) y si tiene magnetometro AK8963 (bypass I2C: 0x0C, WIA = 0x48).
//      3. Igual que test_lsm9ds1: calibra el bias del giroscopo con el sensor quieto, integra el
//         eje Z (yaw, positivo = antihorario visto desde arriba) durante TEST_DURATION_S,
//         imprime una linea por segundo (mismo formato) y un resumen por minuto, y vigila que
//         el sensor no se reinicie. Si no encuentra el MPU, corre un diagnostico de cableado.
//      4. Modo giro (boton BOOT durante la medicion, para validar la escala con giros a mano):
//           2 toques -> YAW = 0 en la posicion actual (al quedar quieto)
//           1 toque  -> recalibracion de parada, como hara el robot: espera a quedar quieto,
//                       calibra RECAL_S segundos, rechaza la ventana si tiene tendencia o si el
//                       bias salta, y pone YAW = 0
//         Desde ahi cada segundo se imprime YAW VERTICAL (giro alrededor de la vertical del
//         acelerometro: compensa la inclinacion del sensor) y YAW Z (solo gz). Al quedar quieto
//         despues de girar, una linea PARADA con los dos y la inclinacion del eje de giro medida
//         con el giroscopo y con el acelerometro (si coinciden, la inclinacion es real).
//
//  NOTA: este firmware NO usa micro-ROS. Imprime por UART0 para verlo con el monitor.
//        No levantar el micro-ROS Agent en este puerto.
//
//  Version: 1.2
//  Fecha: 02/11/2026

#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>
#include <inttypes.h>
#include <math.h>

#include "sdkconfig.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "driver/gpio.h"
#include "driver/i2c.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_rom_sys.h"
#include "esp_timer.h"

// -------------------------------------------------
// Configuracion de la prueba
// -------------------------------------------------
// pines_diag: GPIO que revisa el diagnostico de cableado. Se excluyen flash/PSRAM,
// USB, consola UART0, strapping y los que no tienen pull-down interno.
#if CONFIG_IDF_TARGET_ESP32S3
#define I2C_MASTER_SDA_IO   GPIO_NUM_6      // el S3 no tiene GPIO 22
#define I2C_MASTER_SCL_IO   GPIO_NUM_7
static const int pines_diag[] = {1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
                                 21, 38, 39, 40, 41, 42, 47, 48};
#else
#define I2C_MASTER_SDA_IO   GPIO_NUM_21
#define I2C_MASTER_SCL_IO   GPIO_NUM_22
static const int pines_diag[] = {4, 13, 14, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33};
#endif
#define I2C_MASTER_NUM      I2C_NUM_0
#define I2C_MASTER_FREQ_HZ  100000
#define I2C_TIMEOUT         pdMS_TO_TICKS(50)

#define CALIB_S             3       // calibracion del bias del giroscopo (sensor quieto)
#define CALIB_RUIDO_MAX_DPS 0.5f    // ruido mayor en algun eje -> el sensor se movio, se repite
#define GIRO_TIMEOUT_US     250000  // sin muestras nuevas del giroscopo -> sensor caido
#define HUECO_LARGO_MS      20      // hueco entre muestras que se cuenta como largo (normal: 8 ms)
#define TEST_DURATION_S     300     // prueba de deriva: 5 min
#define MAG_PERIOD_MS       100     // lectura del magnetometro
#define SUMMARY_PERIOD_S    60

#define BOOT_BTN            GPIO_NUM_0  // boton BOOT: 1 toque recalibra, 2 toques = referencia
#define BOTON_REBOTE_US     30000       // filtro de rebote del boton
#define BOTON_DOBLE_US      400000      // ventana para el segundo toque

// Modo giro: una "parada" es quedar quieto GIRO_QUIETO_US despues de girar mas de
// GIRO_PARADA_MIN grados desde la parada anterior
#define GIRO_MOV_DPS        2.0f        // |giro vertical| mayor -> la placa se esta moviendo
#define GIRO_QUIETO_US      1500000
#define GIRO_PARADA_MIN     10.0f
#define RAD_TO_DEG          57.29577951f

// Recalibracion de parada (1 toque de BOOT): espera a quedar quieto y rechaza ventanas dudosas
#define RECAL_S                 5           // duracion (afinado 02/11/26: 3 -> 5 s, p95 a 60 s -15 %)
#define RECAL_QUIETO_DPS        1.0f        // giro sin bias por debajo de esto en los 3 ejes...
#define RECAL_QUIETO_PREVIO_US  1000000     // ...durante este tiempo antes de calibrar
#define RECAL_ESPERA_MAX_US     10000000
#define RECAL_TENDENCIA_MAX_DPS 0.015f      // ~3 sigma de la diferencia entre mitades de 2,5 s
#define RECAL_SALTO_MAX_DPS     0.03f       // el bias normal cambia ~0,002-0,013 dps en minutos
#define RECAL_CAMBIO_ACEL_G     0.03f       // cambio de gravedad (~1,7 grados) que cuenta como otra inclinacion

// -------------------------------------------------
// MPU-6500/9250/9255 y AK8963
// -------------------------------------------------
#define MPU_ADDR_AD0_0      0x68
#define MPU_ADDR_AD0_1      0x69
#define AK8963_ADDR         0x0C

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

#define AK_WIA              0x00    // responde 0x48
#define AK_ST1              0x02    // bit0 DRDY
#define AK_HXL              0x03    // 6 bytes little-endian + ST2 (0x09): leer ST2 libera el dato
#define AK_CNTL1            0x0A
#define AK_CNTL2            0x0B    // bit0 SRST
#define AK_WIA_OK           0x48

// Configuracion elegida
#define CFG_USER_CTRL       0x00    // maestro I2C interno apagado (necesario para el bypass)
#define CFG_PWR_MGMT_1      0x01    // reloj PLL del giroscopo, sin sleep
#define CFG_PWR_MGMT_2      0x00    // todos los ejes habilitados
#define CFG_SMPLRT_DIV      0x07    // 1 kHz / (1 + 7) = 125 Hz
#define CFG_CONFIG          0x03    // filtro del giro: 41 Hz
#define CFG_GYRO_CONFIG     0x00    // +-250 dps
#define CFG_ACCEL_CONFIG    0x08    // +-4 g
#define CFG_ACCEL_CONFIG2   0x03    // filtro del acel: 41 Hz
#define CFG_INT_PIN_CFG     0x02    // BYPASS_EN: el AK8963 queda visible en el bus principal
#define CFG_INT_ENABLE      0x01    // RAW_RDY_EN
#define CFG_AK_CNTL1        0x16    // 16 bits, medicion continua 2 (100 Hz)

// Sensibilidades (hojas de datos del MPU-9250 y del AK8963)
#define GYRO_SENS_DPS       (1.0f / 131.0f)     // +-250 dps -> 131 LSB/dps
#define ACC_SENS_G          (1.0f / 8192.0f)    // +-4 g     -> 8192 LSB/g
#define MAG_SENS_UT         0.15f               // AK8963 a 16 bits (sin el ajuste ASA de fabrica)
#define TEMP_SENS           333.87f             // T = raw / 333.87 + 21 C

static uint8_t mpu_addr = 0;
static uint8_t mpu_id = 0;
static bool hay_mag = false;
static uint32_t i2c_errores = 0;
static float bias_g[3] = {0};
static float up[3] = {0, 0, 1};     // vertical (hacia arriba) en ejes del sensor, del acelerometro

// -------------------------------------------------
// Acceso I2C
// -------------------------------------------------
static void init_i2c_pines(int sda, int scl)
{
    i2c_config_t i2c_c = {
        .mode = I2C_MODE_MASTER,
        .sda_io_num = sda,
        .scl_io_num = scl,
        .sda_pullup_en = GPIO_PULLUP_ENABLE,
        .scl_pullup_en = GPIO_PULLUP_ENABLE,
        .master.clk_speed = I2C_MASTER_FREQ_HZ
    };

    i2c_param_config(I2C_MASTER_NUM, &i2c_c);
    i2c_driver_install(I2C_MASTER_NUM, I2C_MODE_MASTER, 0, 0, 0);
}

static void init_i2c(void)
{
    init_i2c_pines(I2C_MASTER_SDA_IO, I2C_MASTER_SCL_IO);
}

static esp_err_t leer_regs(uint8_t dev, uint8_t reg, uint8_t *buf, size_t len)
{
    esp_err_t err = i2c_master_write_read_device(I2C_MASTER_NUM, dev, &reg, 1, buf, len, I2C_TIMEOUT);
    if (err != ESP_OK) i2c_errores++;
    return err;
}

static esp_err_t escribir_reg(uint8_t dev, uint8_t reg, uint8_t val)
{
    uint8_t buf[2] = {reg, val};
    esp_err_t err = i2c_master_write_to_device(I2C_MASTER_NUM, dev, buf, 2, I2C_TIMEOUT);
    if (err != ESP_OK) i2c_errores++;
    return err;
}

// true si algun dispositivo responde ACK en esa direccion
static bool responde(uint8_t dev)
{
    i2c_cmd_handle_t cmd = i2c_cmd_link_create();
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (dev << 1) | I2C_MASTER_WRITE, true);
    i2c_master_stop(cmd);
    esp_err_t err = i2c_master_cmd_begin(I2C_MASTER_NUM, cmd, I2C_TIMEOUT);
    i2c_cmd_link_delete(cmd);
    return err == ESP_OK;
}

// Lee acel (g), temperatura (C) y giro (dps, sin bias) en una sola transaccion
static esp_err_t leer_mpu(float acc[3], float *temp, float giro[3])
{
    uint8_t b[14];
    esp_err_t err = leer_regs(mpu_addr, MPU_ACCEL_XOUT_H, b, 14);
    if (err != ESP_OK) return err;
    for (int i = 0; i < 3; i++) {
        acc[i] = (int16_t)((b[2 * i] << 8) | b[2 * i + 1]) * ACC_SENS_G;
        giro[i] = (int16_t)((b[8 + 2 * i] << 8) | b[9 + 2 * i]) * GYRO_SENS_DPS;
    }
    *temp = (int16_t)((b[6] << 8) | b[7]) / TEMP_SENS + 21.0f;
    return ESP_OK;
}

// true si hay dato nuevo del MPU (bit RAW_DATA_RDY)
static bool dato_nuevo_mpu(void)
{
    uint8_t st;
    return leer_regs(mpu_addr, MPU_INT_STATUS, &st, 1) == ESP_OK && (st & 0x01);
}

// Lee el magnetometro si tiene dato nuevo. Devuelve false si no hay dato o hubo desborde.
static bool leer_mag(float mag[3])
{
    uint8_t st1, b[7];
    if (leer_regs(AK8963_ADDR, AK_ST1, &st1, 1) != ESP_OK || !(st1 & 0x01)) return false;
    if (leer_regs(AK8963_ADDR, AK_HXL, b, 7) != ESP_OK) return false;  // incluye ST2
    if (b[6] & 0x08) return false;                                      // HOFL: desborde
    for (int i = 0; i < 3; i++) {
        mag[i] = (int16_t)((b[2 * i + 1] << 8) | b[2 * i]) * MAG_SENS_UT;
    }
    return true;
}

// -------------------------------------------------
// Pasos de la prueba
// -------------------------------------------------
static void escanear_bus(void)
{
    int n = 0;
    printf("Escaneo I2C (SDA %d, SCL %d):", I2C_MASTER_SDA_IO, I2C_MASTER_SCL_IO);
    for (uint8_t a = 0x08; a < 0x78; a++) {
        if (responde(a)) {
            printf(" 0x%02X", a);
            n++;
        }
    }
    if (n == 0) {
        printf(" ningun dispositivo\n");
    } else {
        printf("\n");
    }
}

static const char *nombre_chip(uint8_t id)
{
    switch (id) {
    case 0x70: return "MPU-6500 (6 ejes, sin magnetometro)";
    case 0x71: return "MPU-9250 (9 ejes)";
    case 0x73: return "MPU-9255 (9 ejes)";
    case 0x68: return "familia MPU-6050/9150 (no es 6500/9250)";
    default:   return "desconocido: posible clon";
    }
}

static bool detectar_mpu(void)
{
    const uint8_t cand[2] = {MPU_ADDR_AD0_0, MPU_ADDR_AD0_1};
    mpu_addr = 0;
    for (int i = 0; i < 2; i++) {
        uint8_t id = 0;
        if (!responde(cand[i]) || leer_regs(cand[i], MPU_WHO_AM_I, &id, 1) != ESP_OK) continue;
        printf("  MPU en 0x%02X: WHO_AM_I = 0x%02X -> %s\n", cand[i], id, nombre_chip(id));
        mpu_addr = cand[i];
        mpu_id = id;
        return true;
    }
    printf("  MPU no encontrado en 0x68 ni en 0x69\n");
    return false;
}

// Se corre cuando no responde nada. Las placas GY-9250 tienen pull-ups en SDA y SCL:
// con el pull-down interno (~45k), un GPIO conectado a una de esas lineas, con la placa
// alimentada, lee 1. Despues prueba con SDA y SCL invertidos.
static void diagnosticar_cableado(void)
{
    bool sda_ok = false, scl_ok = false;
    int n = 0;

    i2c_driver_delete(I2C_MASTER_NUM);

    printf("Diagnostico: GPIO con pull-up externo (lineas de una placa alimentada):");
    for (size_t i = 0; i < sizeof(pines_diag) / sizeof(pines_diag[0]); i++) {
        int p = pines_diag[i];
        gpio_config_t c = {
            .pin_bit_mask = 1ULL << p,
            .mode = GPIO_MODE_INPUT,
            .pull_up_en = GPIO_PULLUP_DISABLE,
            .pull_down_en = GPIO_PULLDOWN_ENABLE,
            .intr_type = GPIO_INTR_DISABLE
        };
        gpio_config(&c);
        esp_rom_delay_us(500);
        if (gpio_get_level(p)) {
            printf(" %d", p);
            n++;
            if (p == I2C_MASTER_SDA_IO) sda_ok = true;
            if (p == I2C_MASTER_SCL_IO) scl_ok = true;
        }
        gpio_reset_pin(p);
    }

    if (n == 0) {
        printf(" ninguno\n");
        printf("  -> La placa no esta alimentada (VCC a 3V3 y GND) o SDA/SCL no llegan al ESP\n");
    } else if (sda_ok && scl_ok) {
        printf("\n  -> SDA y SCL llegan a los GPIO %d y %d con la placa alimentada."
               " Si igual no responde: NCS a 3V3\n", I2C_MASTER_SDA_IO, I2C_MASTER_SCL_IO);
    } else {
        printf("\n  -> Las lineas no estan (las dos) en los GPIO %d (SDA) y %d (SCL): mover los cables\n",
               I2C_MASTER_SDA_IO, I2C_MASTER_SCL_IO);
    }

    // Prueba con SDA y SCL invertidos
    init_i2c_pines(I2C_MASTER_SCL_IO, I2C_MASTER_SDA_IO);
    bool invertido = responde(MPU_ADDR_AD0_0) || responde(MPU_ADDR_AD0_1);
    i2c_driver_delete(I2C_MASTER_NUM);
    init_i2c();

    if (invertido) {
        printf("  -> Con SDA y SCL invertidos SI responde: intercambiar los cables de los GPIO %d y %d\n",
               I2C_MASTER_SDA_IO, I2C_MASTER_SCL_IO);
    } else {
        printf("  Con SDA y SCL invertidos tampoco responde\n");
    }
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
        leer_regs(mpu_addr, cfg[i][0], &leido, 1);
        if (leido != cfg[i][1]) {
            printf("  Reg 0x%02X: escrito 0x%02X, leido 0x%02X -> FALLA\n", cfg[i][0], cfg[i][1], leido);
            ok = false;
        }
    }
    printf("  Configuracion: %s\n", ok ? "OK" : "con errores");

    // Magnetometro: con el bypass activo, el AK8963 aparece en 0x0C si el chip lo tiene
    uint8_t wia = 0;
    hay_mag = false;
    vTaskDelay(pdMS_TO_TICKS(10));
    if (responde(AK8963_ADDR) && leer_regs(AK8963_ADDR, AK_WIA, &wia, 1) == ESP_OK && wia == AK_WIA_OK) {
        uint8_t cntl1 = 0;
        escribir_reg(AK8963_ADDR, AK_CNTL2, 0x01);  // reset del AK8963
        vTaskDelay(pdMS_TO_TICKS(10));
        escribir_reg(AK8963_ADDR, AK_CNTL1, CFG_AK_CNTL1);
        vTaskDelay(pdMS_TO_TICKS(10));
        leer_regs(AK8963_ADDR, AK_CNTL1, &cntl1, 1);
        hay_mag = true;
        printf("  Magnetometro AK8963 en 0x0C: WIA = 0x%02X -> PRESENTE (9 ejes). Modo %s\n",
               wia, cntl1 == CFG_AK_CNTL1 ? "continuo OK" : "con errores");
    } else if (responde(AK8963_ADDR)) {
        printf("  Algo responde en 0x0C pero WIA = 0x%02X (esperado 0x48) -> no es un AK8963\n", wia);
    } else {
        printf("  Magnetometro AK8963: NO responde en 0x0C -> el chip no tiene magnetometro (6 ejes)\n");
    }
    return ok;
}

// Espera hasta que el giro (sin bias) quede debajo de RECAL_QUIETO_DPS en los 3 ejes durante
// RECAL_QUIETO_PREVIO_US. Devuelve false si no se logra en RECAL_ESPERA_MAX_US.
static bool esperar_quieto(void)
{
    int64_t t0 = esp_timer_get_time(), quieto_desde = t0;
    while (esp_timer_get_time() - t0 < RECAL_ESPERA_MAX_US) {
        float a[3], g[3], t;
        int64_t ahora = esp_timer_get_time();
        if (dato_nuevo_mpu() && leer_mpu(a, &t, g) == ESP_OK) {
            for (int i = 0; i < 3; i++) {
                if (fabsf(g[i] - bias_g[i]) > RECAL_QUIETO_DPS) quieto_desde = ahora;
            }
        }
        if (ahora - quieto_desde > RECAL_QUIETO_PREVIO_US) return true;
        vTaskDelay(pdMS_TO_TICKS(2));
    }
    return false;
}

// Calibra el bias del giroscopo y la vertical (acelerometro) durante 'segundos'.
// robusta = recalibracion de parada: primero espera a que quede quieto y despues rechaza la
// ventana si la media de gz tiene tendencia (primera mitad vs segunda) o si el bias nuevo
// salta mas de RECAL_SALTO_MAX_DPS respecto del anterior (se acepta al segundo rechazo
// seguido por salto, por si el bias cambio de verdad). Si falla, conserva lo anterior.
static bool calibrar_giro_ventana(int segundos, bool robusta)
{
    static int rechazos_salto = 0;
    double s[3] = {0}, s2[3] = {0}, sa[3] = {0}, sz_mitad[2] = {0};
    uint32_t n = 0, n_mitad[2] = {0};

    if (robusta) {
        printf("  Esperando a que quede quieto...\n");
        if (!esperar_quieto()) {
            printf("  FALLA: no quedo quieto en %d s (se conserva el bias anterior)\n",
                   (int)(RECAL_ESPERA_MAX_US / 1000000));
            return false;
        }
    }
    printf("\nCalibrando el giroscopo: dejar el sensor QUIETO durante %d s...\n", segundos);
    vTaskDelay(pdMS_TO_TICKS(200));     // descartar las primeras muestras tras el reset

    int64_t t_ini = esp_timer_get_time();
    int64_t t_fin = t_ini + (int64_t)segundos * 1000000;
    while (esp_timer_get_time() < t_fin) {
        float a[3], g[3], t;
        if (dato_nuevo_mpu() && leer_mpu(a, &t, g) == ESP_OK) {
            int mitad = (esp_timer_get_time() - t_ini) * 2 >= (t_fin - t_ini);
            for (int i = 0; i < 3; i++) {
                s[i] += g[i];
                s2[i] += (double)g[i] * g[i];
                sa[i] += a[i];
            }
            sz_mitad[mitad] += g[2];
            n_mitad[mitad]++;
            n++;
        }
        vTaskDelay(pdMS_TO_TICKS(2));
    }

    if (n < 10 || n_mitad[0] == 0 || n_mitad[1] == 0) {
        printf("  FALLA: pocas muestras (%" PRIu32 ")\n", n);
        return false;
    }

    float bias[3], ruido[3], a[3];
    for (int i = 0; i < 3; i++) {
        bias[i] = s[i] / n;
        double var = s2[i] / n - (double)bias[i] * bias[i];
        ruido[i] = var > 0 ? sqrt(var) : 0;
        a[i] = sa[i] / n;
    }
    float a_mod = sqrtf(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    float tendencia = sz_mitad[1] / n_mitad[1] - sz_mitad[0] / n_mitad[0];
    float salto = bias[2] - bias_g[2];
    float inclinacion = acosf(fminf(fabsf(a[2]) / a_mod, 1.0f)) * RAD_TO_DEG;
    // Cambio de la gravedad medida respecto de la calibracion anterior: si la placa cambio de
    // inclinacion, el bias puede cambiar de verdad (sensibilidad a la orientacion, 02/11/26:
    // ~1 dps/g en esta placa) y el control de salto no se aplica
    float da = sqrtf((a[0] - up[0] * a_mod) * (a[0] - up[0] * a_mod)
                     + (a[1] - up[1] * a_mod) * (a[1] - up[1] * a_mod)
                     + (a[2] - up[2] * a_mod) * (a[2] - up[2] * a_mod));
    bool cambio_inclinacion = da > RECAL_CAMBIO_ACEL_G;

    printf("  Muestras de giro: %" PRIu32 " (%.0f Hz)\n", n, n / (float)segundos);
    printf("  Bias giro  [dps]:     x=%+.3f y=%+.3f z=%+.3f\n", bias[0], bias[1], bias[2]);
    printf("  Ruido giro [dps RMS]: x=%.3f y=%.3f z=%.3f\n", ruido[0], ruido[1], ruido[2]);
    printf("  Acel en reposo [g]:   x=%+.3f y=%+.3f z=%+.3f |A|=%.3f -> %s\n",
           a[0], a[1], a[2], a_mod, (a_mod > 0.95f && a_mod < 1.05f) ? "OK" : "REVISAR (esperado ~1 g)");
    printf("  Inclinacion (acelerometro): %.1f grados | tendencia de gz %+.4f dps", inclinacion, tendencia);
    if (robusta) printf(" | salto de bias z %+.4f dps | cambio de gravedad %.3f g", salto, da);
    printf("\n");

    for (int i = 0; i < 3; i++) {
        if (ruido[i] > CALIB_RUIDO_MAX_DPS) {
            printf("  FALLA: ruido del giro mayor a %.1f dps -> el sensor se movio. Dejarlo QUIETO"
                   " (se conserva el bias anterior)\n", CALIB_RUIDO_MAX_DPS);
            return false;
        }
    }
    if (robusta && fabsf(tendencia) > RECAL_TENDENCIA_MAX_DPS) {
        printf("  RECHAZADA: la media de gz cambio %+.4f dps entre mitades -> se estaba moviendo"
               " lento (se conserva el bias anterior)\n", tendencia);
        return false;
    }
    if (robusta && !cambio_inclinacion && fabsf(salto) > RECAL_SALTO_MAX_DPS) {
        if (rechazos_salto++ == 0) {
            printf("  RECHAZADA: el bias z salto %+.4f dps respecto del anterior sin cambiar la"
                   " inclinacion (se conserva; si se repite, se acepta)\n", salto);
            return false;
        }
        printf("  Salto de bias repetido: se acepta el nuevo\n");
    }
    rechazos_salto = 0;
    for (int i = 0; i < 3; i++) {
        bias_g[i] = bias[i];
        up[i] = a[i] / a_mod;
    }
    // Linea para el analisis de la sensibilidad a la orientacion (bias contra gravedad)
    printf("  CAL_OK bias_x=%+.4f bias_y=%+.4f bias_z=%+.4f acel_x=%+.4f acel_y=%+.4f acel_z=%+.4f"
           " incl=%.1f\n", bias[0], bias[1], bias[2], a[0], a[1], a[2], inclinacion);
    return true;
}

static bool calibrar_giro(void)
{
    return calibrar_giro_ventana(CALIB_S, false);
}

// Boton BOOT sin bloquear la medicion: devuelve 0 (nada), 1 (un toque) o 2+ (toques
// seguidos), BOTON_DOBLE_US despues de soltarlo por ultima vez
static int leer_boton(int64_t ahora)
{
    static bool apretado = false;
    static int64_t t_cambio = 0, t_suelto = 0;
    static int toques = 0;
    bool nivel = gpio_get_level(BOOT_BTN) == 0;

    if (nivel != apretado && ahora - t_cambio > BOTON_REBOTE_US) {
        apretado = nivel;
        t_cambio = ahora;
        if (!apretado) {
            toques++;
            t_suelto = ahora;
        }
    }
    if (toques > 0 && !apretado && ahora - t_suelto > BOTON_DOBLE_US) {
        int t = toques;
        toques = 0;
        return t;
    }
    return 0;
}

// Mide hasta que el giroscopo deja de entregar datos (no vuelve si todo anda bien)
static void medir(void)
{
    int64_t t_ult_giro = esp_timer_get_time();
    int64_t t_ult_print = t_ult_giro;
    int64_t t_ult_mag = 0;
    int seg = 0;

    double yaw = 0.0, yaw_resumen_ant = 0.0;
    double sg[3] = {0};
    uint32_t ng = 0;
    float acc[3] = {0}, mag[3] = {0}, temp = NAN, b_mod = 0;
    float b_min = INFINITY, b_max = 0;
    bool resultado_impreso = false;

    // Modo giro (se activa con el boton BOOT). YAW Z integra solo gz; YAW VERTICAL integra la
    // proyeccion del giro sobre la vertical del acelerometro (compensa la inclinacion).
    // eje_seg: giro integrado en cada eje desde la ultima parada, para medir la inclinacion
    // del eje de giro con el propio giroscopo.
    bool modo_giro = false, ref_pendiente = false;
    double yaw_v = 0.0, yaw_ref = 0.0, yaw_v_ref = 0.0, giro_ult_parada = 0.0;
    double eje_seg[3] = {0};

    // Huecos entre muestras del giroscopo (con 125 Hz lo normal son 8 ms): un hueco largo
    // integra una muestra vieja durante mucho tiempo
    double hueco_max_ms = 0.0;
    uint32_t huecos_largos = 0;
    int64_t quieto_desde = t_ult_giro;
    int paradas = 0;

    printf("\nPrueba de deriva: %d s con el sensor QUIETO. Cada %d s se imprime un resumen.\n",
           TEST_DURATION_S, SUMMARY_PERIOD_S);
    printf("Columnas: giro medio del ultimo segundo, sin bias | acel | mag | temp | yaw integrado\n");
    printf("Boton BOOT (modo giro): 2 toques = YAW 0 aca | 1 toque = recalibrar el giroscopo y YAW 0\n\n");

    while (1) {
        int64_t ahora = esp_timer_get_time();
        float g[3];

        // Giroscopo: cada muestra nueva (125 Hz) se integra con el dt real
        if (dato_nuevo_mpu() && leer_mpu(acc, &temp, g) == ESP_OK) {
            for (int i = 0; i < 3; i++) {
                g[i] -= bias_g[i];
                sg[i] += g[i];
            }
            ng++;
            double dt = (ahora - t_ult_giro) / 1e6;
            if (dt * 1000.0 > hueco_max_ms) hueco_max_ms = dt * 1000.0;
            if (dt * 1000.0 > HUECO_LARGO_MS) huecos_largos++;
            float g_vert = g[0] * up[0] + g[1] * up[1] + g[2] * up[2];
            yaw += g[2] * dt;
            yaw_v += g_vert * dt;
            for (int i = 0; i < 3; i++) eje_seg[i] += g[i] * dt;
            t_ult_giro = ahora;
            if (fabsf(g_vert) > GIRO_MOV_DPS) quieto_desde = ahora;
        } else if (ahora - t_ult_giro > GIRO_TIMEOUT_US) {
            uint8_t div = 0, cfg = 0;
            printf("\n[%4d s] ALERTA: el giroscopo dejo de entregar datos\n", seg);
            if (leer_regs(mpu_addr, MPU_SMPLRT_DIV, &div, 1) != ESP_OK
                || leer_regs(mpu_addr, MPU_CONFIG, &cfg, 1) != ESP_OK) {
                printf("  -> El MPU no responde por I2C: revisar SDA, SCL y GND\n");
            } else if (div != CFG_SMPLRT_DIV || cfg != CFG_CONFIG) {
                printf("  -> SMPLRT_DIV = 0x%02X y CONFIG = 0x%02X (esperado 0x%02X y 0x%02X): el MPU se"
                       " reinicio y perdio la configuracion. Falso contacto en VCC o GND\n",
                       div, cfg, CFG_SMPLRT_DIV, CFG_CONFIG);
            } else {
                printf("  -> La configuracion sigue bien: revisar SDA y SCL\n");
            }
            return;
        }

        // Magnetometro cada MAG_PERIOD_MS (si el chip lo tiene)
        if (hay_mag && ahora - t_ult_mag >= MAG_PERIOD_MS * 1000) {
            t_ult_mag = ahora;
            if (leer_mag(mag)) {
                b_mod = sqrtf(mag[0] * mag[0] + mag[1] * mag[1] + mag[2] * mag[2]);
                if (b_mod < b_min) b_min = b_mod;
                if (b_mod > b_max) b_max = b_mod;
            }
        }

        // Modo giro: referencia al quedar quieto y una linea PARADA en cada posicion
        if (modo_giro && ahora - quieto_desde > GIRO_QUIETO_US) {
            if (ref_pendiente) {
                yaw_ref = yaw;
                yaw_v_ref = yaw_v;
                giro_ult_parada = 0.0;
                eje_seg[0] = eje_seg[1] = eje_seg[2] = 0.0;
                ref_pendiente = false;
                printf("==> REFERENCIA: YAW = 0 en esta posicion (grados, positivo = antihorario)."
                       " Girar la placa y dejarla quieta en cada posicion\n");
            } else {
                double dv = yaw_v - yaw_v_ref;
                if (fabs(dv - giro_ult_parada) > GIRO_PARADA_MIN) {
                    // Inclinacion del eje de giro respecto del eje Z del sensor, medida con el
                    // giroscopo; si el giro fue alrededor de la vertical, tiene que coincidir con
                    // la inclinacion que da el acelerometro
                    double n = sqrt(eje_seg[0] * eje_seg[0] + eje_seg[1] * eje_seg[1]
                                    + eje_seg[2] * eje_seg[2]);
                    double incl_giro = acos(fmin(fabs(eje_seg[2]) / n, 1.0)) * RAD_TO_DEG;
                    double incl_acel = acos(fmin(fabs(up[2]), 1.0)) * RAD_TO_DEG;
                    printf("==> PARADA %d:  YAW VERTICAL = %+7.1f  |  YAW Z = %+7.1f grados"
                           "  |  inclinacion del eje: giroscopo %.1f / acelerometro %.1f grados\n",
                           ++paradas, dv, yaw - yaw_ref, incl_giro, incl_acel);
                    giro_ult_parada = dv;
                    eje_seg[0] = eje_seg[1] = eje_seg[2] = 0.0;
                }
            }
        }

        int toques = leer_boton(ahora);
        if (toques > 0) {
            if (!resultado_impreso) {
                printf("\n(La prueba de deriva en curso queda invalidada)\n");
                resultado_impreso = true;
            }
            modo_giro = true;
            paradas = 0;
            if (toques >= 2) {
                ref_pendiente = true;
                printf("\n>>> NUEVA REFERENCIA: dejar la placa QUIETA...\n");
            } else {
                printf("\n>>> RECALIBRACION (%d s, como en cada parada del robot): soltar la placa"
                       " y no tocarla...\n", RECAL_S);
                if (calibrar_giro_ventana(RECAL_S, true)) printf("  Recalibracion OK\n");
                yaw = yaw_v = 0.0;  // nueva referencia en la misma posicion (la placa estuvo quieta)
                yaw_ref = yaw_v_ref = 0.0;
                giro_ult_parada = 0.0;
                eje_seg[0] = eje_seg[1] = eje_seg[2] = 0.0;
                ref_pendiente = false;
                printf("==> REFERENCIA: YAW = 0 en esta posicion. Girar la placa y dejarla"
                       " quieta en cada posicion\n");
                t_ult_giro = esp_timer_get_time();  // no integrar el hueco de la calibracion
                t_ult_print = t_ult_giro;
                quieto_desde = t_ult_giro;
                continue;
            }
        }

        // Linea por segundo, resumen por minuto, resultado al final
        if (ahora - t_ult_print >= 1000000) {
            t_ult_print += 1000000;
            seg++;
            float a_mod = sqrtf(acc[0] * acc[0] + acc[1] * acc[1] + acc[2] * acc[2]);

            if (modo_giro && !ref_pendiente) {
                printf("[%4d s]  YAW VERTICAL = %+7.1f  |  YAW Z = %+7.1f grados  |  giro z = %+6.2f dps"
                       "  |  T = %.1f C\n", seg, yaw_v - yaw_v_ref, yaw - yaw_ref, ng > 0 ? sg[2] / ng : 0.0, temp);
            } else {
                if (ng > 0) {
                    printf("[%4d s] G(dps) x=%+.3f y=%+.3f z=%+.3f",
                           seg, sg[0] / ng, sg[1] / ng, sg[2] / ng);
                } else {
                    printf("[%4d s] G(dps) sin datos", seg);
                }
                printf(" | A(g) x=%+.3f y=%+.3f z=%+.3f |A|=%.3f", acc[0], acc[1], acc[2], a_mod);
                printf(" | M(uT) x=%+6.1f y=%+6.1f z=%+6.1f |B|=%5.1f", mag[0], mag[1], mag[2], b_mod);
                printf(" | T=%.1fC | yaw=%+8.3f\n", temp, yaw);
            }
            sg[0] = sg[1] = sg[2] = 0;
            ng = 0;

            if (seg % SUMMARY_PERIOD_S == 0) {
                printf("---- Minuto %d: deriva en el minuto %+.3f deg | yaw total %+.3f deg"
                       " | |B| min/max %.1f/%.1f uT | errores I2C %" PRIu32
                       " | hueco max %.1f ms, huecos > %d ms: %" PRIu32 " ----\n",
                       seg / SUMMARY_PERIOD_S, yaw - yaw_resumen_ant, yaw,
                       hay_mag ? b_min : 0, b_max, i2c_errores, hueco_max_ms, HUECO_LARGO_MS,
                       huecos_largos);
                yaw_resumen_ant = yaw;
                b_min = INFINITY;
                b_max = 0;
                hueco_max_ms = 0.0;
                huecos_largos = 0;
            }

            if (!resultado_impreso && seg >= TEST_DURATION_S) {
                printf("\n================ RESULTADO DE LA DERIVA ================\n");
                printf("  Chip: WHO_AM_I 0x%02X (%s), magnetometro %s\n",
                       mpu_id, nombre_chip(mpu_id), hay_mag ? "presente" : "ausente");
                printf("  Yaw acumulado en %d s quieto: %+.3f deg\n", seg, yaw);
                printf("  Deriva media: %+.3f deg/min\n", yaw / (seg / 60.0));
                printf("  Errores I2C: %" PRIu32 "\n", i2c_errores);
                printf("  El programa sigue midiendo. Reset (EN) para repetir la prueba.\n");
                printf("========================================================\n\n");
                resultado_impreso = true;
            }
        }

        vTaskDelay(pdMS_TO_TICKS(2));
    }
}

void app_main(void)
{
    printf("=========================================================\n");
    printf("   PRUEBA AISLADA DEL IMU DE LA PLACA 3 (MPU-9250/6500/9255)\n");
    printf("   I2C: SDA -> GPIO %d | SCL -> GPIO %d | %d kHz\n",
           I2C_MASTER_SDA_IO, I2C_MASTER_SCL_IO, I2C_MASTER_FREQ_HZ / 1000);
    printf("   Calibracion %d s + deriva %d s (sensor quieto)\n", CALIB_S, TEST_DURATION_S);
    printf("=========================================================\n");

    esp_log_level_set("gpio", ESP_LOG_WARN);    // gpio_config del diagnostico imprime un log por pin
    gpio_config_t boot = {
        .pin_bit_mask = 1ULL << BOOT_BTN,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE
    };
    gpio_config(&boot);
    init_i2c();

    while (1) {
        while (1) {
            printf("\n--- Buscando el MPU ---\n");
            escanear_bus();
            if (detectar_mpu() && configurar_mpu() && calibrar_giro()) break;
            if (mpu_addr == 0) diagnosticar_cableado();
            printf("Reintentando en 3 s (revisar cableado y que VCC este en 3V3)...\n");
            vTaskDelay(pdMS_TO_TICKS(3000));
        }

        medir();
        printf("Reiniciando la prueba en 3 s...\n");
        vTaskDelay(pdMS_TO_TICKS(3000));
    }
}
