//  Prueba aislada del IMU LSM9DS1 (SparkFun LSM9DS1 Breakout)
//  Placa: ESP32-S3 (N16R8 de prueba) o ESP32 clasico (futuro ESP32_motores, docs/pines.md §2)
//         El target se elige al compilar: build_test_lsm9ds1.sh [esp32s3|esp32]
//
//  Conexion (I2C a 3,3 V):
//      LSM9DS1 VDD -> 3V3 del ESP32   (NUNCA 5 V: la placa no tiene regulador)
//      LSM9DS1 GND -> GND
//      LSM9DS1 SDA -> GPIO 6  (S3) / GPIO 21 (clasico)
//      LSM9DS1 SCL -> GPIO 7  (S3) / GPIO 22 (clasico)
//      El resto de los pines del LSM9DS1 queda sin conectar.
//
//  Que hace:
//      1. Escanea el bus I2C y busca el acel/giro (0x6B/0x6A) y el magnetometro (0x1E/0x1C).
//      2. Verifica WHO_AM_I (AG = 0x68, M = 0x3D) y relee cada registro de configuracion.
//      3. Calibra el bias del giroscopo con el sensor quieto (CALIB_S segundos).
//      4. Integra el eje Z del giroscopo (yaw, positivo = antihorario visto desde arriba)
//         para medir la deriva. Cada segundo imprime una linea; cada minuto, un resumen.
//      5. A los TEST_DURATION_S imprime el resultado y sigue midiendo, para la prueba
//         del magnetometro con la cortadora prendida/apagada. Reset (EN) para repetir.
//      Si no encuentra el sensor, corre un diagnostico de cableado: busca en que GPIO
//      estan los pull-ups del breakout y prueba con SDA/SCL invertidos.
//      Si el sensor se mueve durante la calibracion, la repite. Si durante la medicion el
//      giroscopo deja de entregar datos (p. ej. el LSM9DS1 se reinicio por un falso
//      contacto en VDD/GND), lo informa y reinicia la prueba.
//      Boton BOOT durante la medicion:
//        1 toque  -> calibra el magnetometro (1 vuelta completa en MAG_CAL_S segundos,
//                    ajuste de elipse en X/Y) y toma la referencia al quedar quieto.
//        2 toques -> nueva referencia: YAW GIRO = 0 y YAW MAG = 0 en la posicion actual.
//      Con el magnetometro calibrado, cada segundo se imprime YAW GIRO, YAW MAG (grados
//      girados desde la referencia segun cada sensor), su diferencia y el campo horizontal
//      calibrado (Bh). Supone la placa horizontal (sin compensar inclinacion).
//
//  NOTA: este firmware NO usa micro-ROS. Imprime por UART0 para verlo con el monitor.
//        No levantar el micro-ROS Agent en este puerto.
//
//  Version: 1.5
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
#define TEST_DURATION_S     300     // prueba de deriva: 5 min
#define MAG_PERIOD_MS       100     // lectura de acelerometro + magnetometro
#define SUMMARY_PERIOD_S    60

#define BOOT_BTN            GPIO_NUM_0  // boton BOOT: 1 toque calibra el magnetometro, 2 toques = referencia
#define BOTON_REBOTE_US     30000       // filtro de rebote del boton
#define BOTON_DOBLE_US      400000      // ventana para el segundo toque
#define MAG_CAL_S           20          // calibracion del magnetometro: 1 vuelta completa en este tiempo
#define MAG_CAL_GIRO_MIN    330.0f      // grados que tiene que medir el giroscopo durante esa vuelta
#define MAG_RADIO_MIN_UT    5.0f        // radio minimo del circulo X/Y para aceptar la calibracion
#define MAG_CAL_MAX_MUESTRAS 1000       // muestras X/Y guardadas para el ajuste (20 Hz x 20 s = ~400)
#define RAD_TO_DEG          57.29577951f

// Versus giroscopio / magnetometro: una "parada" es quedar quieto VERSUS_QUIETO_US despues
// de girar mas de VERSUS_GIRO_MIN grados desde la parada anterior
#define VERSUS_MOV_DPS      2.0f        // |gz| mayor -> la placa se esta moviendo
#define VERSUS_QUIETO_US    1500000
#define VERSUS_GIRO_MIN     10.0f

// -------------------------------------------------
// LSM9DS1 — direcciones (dependen de los jumpers SDO)
// -------------------------------------------------
#define AG_ADDR_SDO1        0x6B
#define AG_ADDR_SDO0        0x6A
#define M_ADDR_SDO1         0x1E
#define M_ADDR_SDO0         0x1C

// Registros del acelerometro/giroscopio (AG)
#define WHO_AM_I_XG         0x0F
#define CTRL_REG1_G         0x10
#define OUT_TEMP_L          0x15
#define STATUS_REG          0x17    // bit0 XLDA (acel nuevo), bit1 GDA (giro nuevo)
#define OUT_X_L_G           0x18
#define CTRL_REG4           0x1E
#define CTRL_REG5_XL        0x1F
#define CTRL_REG6_XL        0x20
#define CTRL_REG8           0x22
#define OUT_X_L_XL          0x28

// Registros del magnetometro (M)
#define WHO_AM_I_M          0x0F
#define CTRL_REG1_M         0x20
#define CTRL_REG2_M         0x21
#define CTRL_REG3_M         0x22
#define CTRL_REG4_M         0x23
#define CTRL_REG5_M         0x24
#define STATUS_REG_M        0x27    // bit3 ZYXDA (dato nuevo en los 3 ejes)
#define OUT_X_L_M           0x28
#define M_AUTO_INC          0x80    // el magnetometro necesita el MSB en 1 para leer varios bytes seguidos

#define WHO_AM_I_AG_OK      0x68
#define WHO_AM_I_M_OK       0x3D

// Configuracion elegida
#define CFG_CTRL_REG8       0x44    // BDU=1, IF_ADD_INC=1
#define CFG_CTRL_REG1_G     0x60    // giro: ODR 119 Hz, 245 dps
#define CFG_CTRL_REG4       0x38    // giro: ejes X, Y, Z habilitados
#define CFG_CTRL_REG5_XL    0x38    // acel: ejes X, Y, Z habilitados
#define CFG_CTRL_REG6_XL    0x70    // acel: ODR 119 Hz, +-4 g
#define CFG_CTRL_REG1_M     0xF4    // mag: compensacion de temperatura, XY ultra alto rendimiento, 20 Hz
#define CFG_CTRL_REG2_M     0x00    // mag: +-4 gauss
#define CFG_CTRL_REG3_M     0x00    // mag: modo continuo, I2C habilitado
#define CFG_CTRL_REG4_M     0x0C    // mag: Z ultra alto rendimiento
#define CFG_CTRL_REG5_M     0x40    // mag: BDU=1

// Sensibilidades (hoja de datos del LSM9DS1)
#define GYRO_SENS_DPS       0.00875f    // 245 dps   -> 8.75 mdps/LSB
#define ACC_SENS_G          0.000122f   // +-4 g     -> 0.122 mg/LSB
#define MAG_SENS_UT         0.014f      // +-4 gauss -> 0.14 mgauss/LSB = 0.014 uT/LSB

static uint8_t ag_addr = 0;
static uint8_t m_addr = 0;
static uint32_t i2c_errores = 0;
static float bias_g[3] = {0};

// Calibracion X/Y del magnetometro: b = W * (m - centro). El centro corrige el hard iron
// (campo propio de la placa) y W (2x2) el soft iron: lleva la elipse medida a un circulo.
static bool mag_cal = false;
static float mag_c[2] = {0};
static float mag_w[2][2] = {{1, 0}, {0, 1}};
static float cal_x[MAG_CAL_MAX_MUESTRAS], cal_y[MAG_CAL_MAX_MUESTRAS];

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

// Lee 3 ejes de 16 bits (little-endian) a partir de reg
static esp_err_t leer_xyz(uint8_t dev, uint8_t reg, int16_t out[3])
{
    uint8_t b[6];
    esp_err_t err = leer_regs(dev, reg, b, 6);
    if (err != ESP_OK) return err;
    for (int i = 0; i < 3; i++) {
        out[i] = (int16_t)((b[2 * i + 1] << 8) | b[2 * i]);
    }
    return ESP_OK;
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

static uint8_t buscar(const uint8_t cand[2], uint8_t reg_id, uint8_t id_ok, const char *nombre)
{
    for (int i = 0; i < 2; i++) {
        uint8_t id = 0;
        if (!responde(cand[i]) || leer_regs(cand[i], reg_id, &id, 1) != ESP_OK) continue;
        printf("  %-3s en 0x%02X: WHO_AM_I = 0x%02X (esperado 0x%02X) -> %s\n",
               nombre, cand[i], id, id_ok, id == id_ok ? "OK" : "FALLA");
        if (id == id_ok) return cand[i];
    }
    printf("  %-3s no encontrado\n", nombre);
    return 0;
}

static bool detectar_lsm9ds1(void)
{
    const uint8_t ag_cand[2] = {AG_ADDR_SDO1, AG_ADDR_SDO0};
    const uint8_t m_cand[2] = {M_ADDR_SDO1, M_ADDR_SDO0};

    ag_addr = buscar(ag_cand, WHO_AM_I_XG, WHO_AM_I_AG_OK, "AG");
    m_addr = buscar(m_cand, WHO_AM_I_M, WHO_AM_I_M_OK, "M");
    return ag_addr != 0 && m_addr != 0;
}

// Se corre cuando no responde nada. El breakout tiene pull-ups de 10k a VDD en SDA y SCL
// (jumper "I2C PU"): con el pull-down interno (~45k), un GPIO conectado a una de esas
// lineas, con el breakout alimentado, lee 1. Despues prueba con SDA y SCL invertidos.
static void diagnosticar_cableado(void)
{
    bool sda_ok = false, scl_ok = false;
    int n = 0;

    i2c_driver_delete(I2C_MASTER_NUM);

    printf("Diagnostico: GPIO con pull-up externo (lineas de un breakout alimentado):");
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
        printf("  -> El breakout no esta alimentado (VDD a 3V3 y GND) o SDA/SCL no llegan a la placa\n");
    } else if (sda_ok && scl_ok) {
        printf("\n  -> SDA y SCL llegan a los GPIO %d y %d con el breakout alimentado\n",
               I2C_MASTER_SDA_IO, I2C_MASTER_SCL_IO);
    } else {
        printf("\n  -> Las lineas no estan (las dos) en los GPIO %d (SDA) y %d (SCL): mover los cables\n",
               I2C_MASTER_SDA_IO, I2C_MASTER_SCL_IO);
    }

    // Prueba con SDA y SCL invertidos
    init_i2c_pines(I2C_MASTER_SCL_IO, I2C_MASTER_SDA_IO);
    bool invertido = responde(AG_ADDR_SDO1) || responde(AG_ADDR_SDO0)
                     || responde(M_ADDR_SDO1) || responde(M_ADDR_SDO0);
    i2c_driver_delete(I2C_MASTER_NUM);
    init_i2c();

    if (invertido) {
        printf("  -> Con SDA y SCL invertidos SI responde: intercambiar los cables de los GPIO %d y %d\n",
               I2C_MASTER_SDA_IO, I2C_MASTER_SCL_IO);
    } else {
        printf("  Con SDA y SCL invertidos tampoco responde\n");
    }
}

static bool configurar_lsm9ds1(void)
{
    // Reset por software de los dos bloques
    escribir_reg(ag_addr, CTRL_REG8, 0x05);     // SW_RESET + IF_ADD_INC
    escribir_reg(m_addr, CTRL_REG2_M, 0x0C);    // REBOOT + SOFT_RST
    vTaskDelay(pdMS_TO_TICKS(50));

    const uint8_t cfg[][3] = {
        {ag_addr, CTRL_REG8,    CFG_CTRL_REG8},
        {ag_addr, CTRL_REG1_G,  CFG_CTRL_REG1_G},
        {ag_addr, CTRL_REG4,    CFG_CTRL_REG4},
        {ag_addr, CTRL_REG5_XL, CFG_CTRL_REG5_XL},
        {ag_addr, CTRL_REG6_XL, CFG_CTRL_REG6_XL},
        {m_addr,  CTRL_REG1_M,  CFG_CTRL_REG1_M},
        {m_addr,  CTRL_REG2_M,  CFG_CTRL_REG2_M},
        {m_addr,  CTRL_REG3_M,  CFG_CTRL_REG3_M},
        {m_addr,  CTRL_REG4_M,  CFG_CTRL_REG4_M},
        {m_addr,  CTRL_REG5_M,  CFG_CTRL_REG5_M},
    };

    bool ok = true;
    for (size_t i = 0; i < sizeof(cfg) / sizeof(cfg[0]); i++) {
        uint8_t leido = 0;
        escribir_reg(cfg[i][0], cfg[i][1], cfg[i][2]);
        leer_regs(cfg[i][0], cfg[i][1], &leido, 1);
        if (leido != cfg[i][2]) {
            printf("  Disp. 0x%02X reg 0x%02X: escrito 0x%02X, leido 0x%02X -> FALLA\n",
                   cfg[i][0], cfg[i][1], cfg[i][2], leido);
            ok = false;
        }
    }
    printf("  Configuracion: %s\n", ok ? "OK" : "con errores");
    return ok;
}

static bool calibrar_giro(void)
{
    double s[3] = {0}, s2[3] = {0}, sa[3] = {0};
    uint32_t n = 0, na = 0;

    printf("\nCalibrando el giroscopo: dejar el sensor QUIETO durante %d s...\n", CALIB_S);
    vTaskDelay(pdMS_TO_TICKS(200));     // descartar las primeras muestras tras el reset

    int64_t t_fin = esp_timer_get_time() + (int64_t)CALIB_S * 1000000;
    while (esp_timer_get_time() < t_fin) {
        uint8_t st;
        int16_t r[3];
        if (leer_regs(ag_addr, STATUS_REG, &st, 1) == ESP_OK) {
            if ((st & 0x02) && leer_xyz(ag_addr, OUT_X_L_G, r) == ESP_OK) {
                for (int i = 0; i < 3; i++) {
                    double v = r[i] * GYRO_SENS_DPS;
                    s[i] += v;
                    s2[i] += v * v;
                }
                n++;
            }
            if ((st & 0x01) && leer_xyz(ag_addr, OUT_X_L_XL, r) == ESP_OK) {
                for (int i = 0; i < 3; i++) sa[i] += r[i] * ACC_SENS_G;
                na++;
            }
        }
        vTaskDelay(pdMS_TO_TICKS(2));
    }

    if (n < 10 || na < 10) {
        printf("  FALLA: pocas muestras (giro %" PRIu32 ", acel %" PRIu32 ")\n", n, na);
        return false;
    }

    float ruido[3], a[3];
    for (int i = 0; i < 3; i++) {
        bias_g[i] = s[i] / n;
        double var = s2[i] / n - (double)bias_g[i] * bias_g[i];
        ruido[i] = var > 0 ? sqrt(var) : 0;
        a[i] = sa[i] / na;
    }
    float a_mod = sqrtf(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);

    printf("  Muestras de giro: %" PRIu32 " (%.0f Hz)\n", n, n / (float)CALIB_S);
    printf("  Bias giro  [dps]:     x=%+.3f y=%+.3f z=%+.3f\n", bias_g[0], bias_g[1], bias_g[2]);
    printf("  Ruido giro [dps RMS]: x=%.3f y=%.3f z=%.3f\n", ruido[0], ruido[1], ruido[2]);
    printf("  Acel en reposo [g]:   x=%+.3f y=%+.3f z=%+.3f |A|=%.3f -> %s\n",
           a[0], a[1], a[2], a_mod, (a_mod > 0.95f && a_mod < 1.05f) ? "OK" : "REVISAR (esperado ~1 g)");

    for (int i = 0; i < 3; i++) {
        if (ruido[i] > CALIB_RUIDO_MAX_DPS) {
            printf("  FALLA: ruido del giro mayor a %.1f dps -> el sensor se movio. Dejarlo QUIETO\n",
                   CALIB_RUIDO_MAX_DPS);
            return false;
        }
    }
    return true;
}

static float envolver_180(float a)
{
    while (a > 180.0f) a -= 360.0f;
    while (a <= -180.0f) a += 360.0f;
    return a;
}

static void mag_corregido(const float m[3], float *bx, float *by)
{
    float dx = m[0] - mag_c[0], dy = m[1] - mag_c[1];
    *bx = mag_w[0][0] * dx + mag_w[0][1] * dy;
    *by = mag_w[1][0] * dx + mag_w[1][1] * dy;
}

// Rumbo magnetico en grados, positivo antihorario visto desde arriba (igual que el yaw),
// con la placa horizontal. Los ejes X/Y del magnetometro se toman tal cual: el 02/11/26
// la prueba de 90 grados mostro que suponer X invertido (x_AG = -mx) daba el signo al reves.
static float rumbo_mag_deg(const float m[3])
{
    float bx, by;
    mag_corregido(m, &bx, &by);
    return atan2f(-by, bx) * RAD_TO_DEG;
}

// Campo horizontal calibrado (uT): casi constante si la calibracion es buena y no hay
// perturbaciones cerca
static float campo_h_cal(const float m[3])
{
    float bx, by;
    mag_corregido(m, &bx, &by);
    return sqrtf(bx * bx + by * by);
}

// Resuelve A x = b (5x5) por eliminacion gaussiana con pivoteo parcial
static bool resolver_5x5(double A[5][5], double b[5], double x[5])
{
    for (int c = 0; c < 5; c++) {
        int p = c;
        for (int f = c + 1; f < 5; f++) {
            if (fabs(A[f][c]) > fabs(A[p][c])) p = f;
        }
        if (fabs(A[p][c]) < 1e-12) return false;
        if (p != c) {
            for (int k = 0; k < 5; k++) {
                double t = A[c][k]; A[c][k] = A[p][k]; A[p][k] = t;
            }
            double t = b[c]; b[c] = b[p]; b[p] = t;
        }
        for (int f = c + 1; f < 5; f++) {
            double m = A[f][c] / A[c][c];
            for (int k = c; k < 5; k++) A[f][k] -= m * A[c][k];
            b[f] -= m * b[c];
        }
    }
    for (int f = 4; f >= 0; f--) {
        double s = b[f];
        for (int k = f + 1; k < 5; k++) s -= A[f][k] * x[k];
        x[f] = s / A[f][f];
    }
    return true;
}

// Ajuste de elipse por minimos cuadrados (A u^2 + B uv + C v^2 + D u + E v = 1) sobre las
// muestras normalizadas. Devuelve el centro, la matriz W que lleva la elipse a un circulo
// de radio = media geometrica de los semiejes, los semiejes y el angulo del eje mayor.
static bool ajustar_elipse(int n, float centro[2], float W[2][2], float *radio,
                           float *semi_min, float *semi_max, float *angulo)
{
    double mx = 0, my = 0, vx = 0, vy = 0;
    for (int i = 0; i < n; i++) { mx += cal_x[i]; my += cal_y[i]; }
    mx /= n; my /= n;
    for (int i = 0; i < n; i++) {
        vx += (cal_x[i] - mx) * (cal_x[i] - mx);
        vy += (cal_y[i] - my) * (cal_y[i] - my);
    }
    double s = sqrt((vx > vy ? vx : vy) / n);   // escala de normalizacion
    if (s < 1e-6) return false;

    double M[5][5] = {{0}}, v[5] = {0}, p[5];
    for (int i = 0; i < n; i++) {
        double u = (cal_x[i] - mx) / s, w = (cal_y[i] - my) / s;
        double phi[5] = {u * u, u * w, w * w, u, w};
        for (int r = 0; r < 5; r++) {
            v[r] += phi[r];
            for (int c = 0; c < 5; c++) M[r][c] += phi[r] * phi[c];
        }
    }
    if (!resolver_5x5(M, v, p)) return false;

    double A = p[0], B = p[1], C = p[2], D = p[3], E = p[4];
    double det = 4 * A * C - B * B;
    if (det <= 0) return false;                  // la conica no es una elipse
    double u0 = (-2 * C * D + B * E) / det;      // centro (normalizado)
    double v0 = (-2 * A * E + B * D) / det;
    double k = 1 + A * u0 * u0 + B * u0 * v0 + C * v0 * v0;
    if (k <= 0) return false;

    // Elipse centrada: x' N x = 1, con N en uT^-2
    double n11 = A / k / (s * s), n12 = B / 2 / k / (s * s), n22 = C / k / (s * s);
    double raiz = sqrt((n11 - n22) * (n11 - n22) / 4 + n12 * n12);
    double l1 = (n11 + n22) / 2 + raiz, l2 = (n11 + n22) / 2 - raiz;
    if (l2 <= 0) return false;
    double th = 0.5 * atan2(2 * n12, n11 - n22);  // direccion del autovector de l1 (eje menor)

    double a_min = 1 / sqrt(l1), a_max = 1 / sqrt(l2);
    double R = sqrt(a_min * a_max);
    double c = cos(th), sn = sin(th), q1 = sqrt(l1) * R, q2 = sqrt(l2) * R;
    W[0][0] = c * c * q1 + sn * sn * q2;
    W[0][1] = c * sn * (q1 - q2);
    W[1][0] = W[0][1];
    W[1][1] = sn * sn * q1 + c * c * q2;
    centro[0] = mx + s * u0;
    centro[1] = my + s * v0;
    *radio = R;
    *semi_min = a_min;
    *semi_max = a_max;
    *angulo = envolver_180((th * RAD_TO_DEG) + 90.0f);  // eje mayor = perpendicular al de l1
    return true;
}

// Calibracion del magnetometro: el usuario gira la placa una vuelta completa apoyada en la
// mesa. Con las muestras X/Y se ajusta una elipse (si falla, se usa minimo/maximo por eje).
// El giroscopo verifica que la vuelta haya sido completa.
static bool calibrar_mag(void)
{
    float mn[2] = {INFINITY, INFINITY}, mx[2] = {-INFINITY, -INFINITY};
    int n = 0;
    double giro = 0.0;
    int64_t t_ult = esp_timer_get_time();
    int64_t t_print = t_ult;
    int64_t t_fin = t_ult + (int64_t)MAG_CAL_S * 1000000;
    int s = 0;

    printf("\n>>> CALIBRACION DEL MAGNETOMETRO: girar la placa 1 vuelta completa (360 grados),\n");
    printf("    despacio y apoyada en la mesa, durante los proximos %d s\n", MAG_CAL_S);

    while (esp_timer_get_time() < t_fin) {
        int64_t ahora = esp_timer_get_time();
        uint8_t st, stm;
        int16_t r[3];

        if (leer_regs(ag_addr, STATUS_REG, &st, 1) == ESP_OK && (st & 0x02)
            && leer_xyz(ag_addr, OUT_X_L_G, r) == ESP_OK) {
            giro += (r[2] * GYRO_SENS_DPS - bias_g[2]) * (ahora - t_ult) / 1e6;
            t_ult = ahora;
        }
        if (leer_regs(m_addr, STATUS_REG_M, &stm, 1) == ESP_OK && (stm & 0x08)
            && leer_xyz(m_addr, OUT_X_L_M | M_AUTO_INC, r) == ESP_OK) {
            for (int i = 0; i < 2; i++) {
                float v = r[i] * MAG_SENS_UT;
                if (v < mn[i]) mn[i] = v;
                if (v > mx[i]) mx[i] = v;
            }
            if (n < MAG_CAL_MAX_MUESTRAS) {
                cal_x[n] = r[0] * MAG_SENS_UT;
                cal_y[n] = r[1] * MAG_SENS_UT;
                n++;
            }
        }
        if (ahora - t_print >= 1000000) {
            t_print += 1000000;
            printf("    %2d s | vuelta medida por el giroscopo: %+6.1f grados\n", ++s, giro);
        }
        vTaskDelay(pdMS_TO_TICKS(2));
    }

    float rx = (mx[0] - mn[0]) / 2.0f, ry = (mx[1] - mn[1]) / 2.0f;
    printf("  Vuelta medida: %+.1f grados | radios X/Y: %.1f / %.1f uT\n", giro, rx, ry);
    if (fabs(giro) < MAG_CAL_GIRO_MIN) {
        printf("  FALLA: la vuelta tiene que ser de al menos %.0f grados. Apretar BOOT para repetir\n",
               MAG_CAL_GIRO_MIN);
        return false;
    }
    if (rx < MAG_RADIO_MIN_UT || ry < MAG_RADIO_MIN_UT) {
        printf("  FALLA: radios demasiado chicos. Apretar BOOT para repetir\n");
        return false;
    }

    float radio, a_min, a_max, ang;
    if (ajustar_elipse(n, mag_c, mag_w, &radio, &a_min, &a_max, &ang)) {
        printf("  Ajuste de elipse (%d muestras): centro %+.1f / %+.1f uT | semiejes %.1f / %.1f uT"
               " (relacion %.2f, eje mayor a %+.0f grados)\n",
               n, mag_c[0], mag_c[1], a_max, a_min, a_max / a_min, ang);
    } else {
        radio = (rx + ry) / 2.0f;
        mag_c[0] = (mx[0] + mn[0]) / 2.0f;
        mag_c[1] = (mx[1] + mn[1]) / 2.0f;
        mag_w[0][0] = radio / rx;
        mag_w[1][1] = radio / ry;
        mag_w[0][1] = mag_w[1][0] = 0;
        printf("  El ajuste de elipse fallo: se usa minimo/maximo por eje (centro %+.1f / %+.1f uT)\n",
               mag_c[0], mag_c[1]);
    }

    // Calidad: dispersion del campo calibrado sobre las mismas muestras
    double suma = 0, suma2 = 0;
    for (int i = 0; i < n; i++) {
        float m[3] = {cal_x[i], cal_y[i], 0};
        double b = campo_h_cal(m);
        suma += b;
        suma2 += b * b;
    }
    double media = suma / n, desv = sqrt(fmax(suma2 / n - media * media, 0));
    mag_cal = true;
    printf("  OK: campo horizontal %.1f uT | dispersion tras calibrar %.1f %% (bueno < 3 %%)\n",
           media, 100 * desv / media);
    printf("  Desde ahora cada segundo: YAW GIRO y YAW MAG (grados girados desde la referencia segun"
           " cada sensor), su diferencia y Bh (campo calibrado: tiene que quedar casi constante)\n\n");
    return true;
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
    float acc[3] = {0}, mag[3] = {0}, b_mod = 0;
    float b_min = INFINITY, b_max = 0;
    bool resultado_impreso = false;

    // Versus giroscopio / magnetometro (despues de calibrar el magnetometro con BOOT).
    // Si ya habia calibracion (la prueba se reinicio), se vuelve a tomar la referencia.
    bool ref_pendiente = mag_cal;
    double yaw_ref = 0.0, giro_ult_parada = 0.0, mag_unw = 0.0;   // mag_unw: rumbo mag desenvuelto
    float rumbo_ant = 0.0f;
    int64_t quieto_desde = t_ult_giro;
    int paradas = 0;

    printf("\nPrueba de deriva: %d s con el sensor QUIETO. Cada %d s se imprime un resumen.\n",
           TEST_DURATION_S, SUMMARY_PERIOD_S);
    printf("Columnas: giro medio del ultimo segundo, sin bias | acel | mag | temp | yaw integrado\n");
    printf("Boton BOOT: 1 toque = calibrar el magnetometro | 2 toques = nueva referencia (yaw = 0)\n\n");

    while (1) {
        int64_t ahora = esp_timer_get_time();
        uint8_t st;
        int16_t r[3];

        // Giroscopo: cada muestra nueva (119 Hz) se integra con el dt real
        if (leer_regs(ag_addr, STATUS_REG, &st, 1) == ESP_OK && (st & 0x02)
            && leer_xyz(ag_addr, OUT_X_L_G, r) == ESP_OK) {
            float gz = 0;
            for (int i = 0; i < 3; i++) {
                float g = r[i] * GYRO_SENS_DPS - bias_g[i];
                sg[i] += g;
                if (i == 2) gz = g;
            }
            ng++;
            yaw += gz * (ahora - t_ult_giro) / 1e6;
            t_ult_giro = ahora;
            if (fabsf(gz) > VERSUS_MOV_DPS) quieto_desde = ahora;
        } else if (ahora - t_ult_giro > GIRO_TIMEOUT_US) {
            uint8_t cfg = 0;
            printf("\n[%4d s] ALERTA: el giroscopo dejo de entregar datos\n", seg);
            if (leer_regs(ag_addr, CTRL_REG1_G, &cfg, 1) != ESP_OK) {
                printf("  -> El LSM9DS1 no responde por I2C: revisar SDA, SCL y GND\n");
            } else if (cfg != CFG_CTRL_REG1_G) {
                printf("  -> CTRL_REG1_G = 0x%02X (esperado 0x%02X): el LSM9DS1 se reinicio y perdio"
                       " la configuracion. Falso contacto en VDD o GND\n", cfg, CFG_CTRL_REG1_G);
            } else {
                printf("  -> La configuracion sigue bien (CTRL_REG1_G = 0x%02X): revisar SDA y SCL\n", cfg);
            }
            return;
        }

        // Acelerometro + magnetometro cada MAG_PERIOD_MS
        if (ahora - t_ult_mag >= MAG_PERIOD_MS * 1000) {
            uint8_t stm;
            t_ult_mag = ahora;
            if (leer_xyz(ag_addr, OUT_X_L_XL, r) == ESP_OK) {
                for (int i = 0; i < 3; i++) acc[i] = r[i] * ACC_SENS_G;
            }
            if (leer_regs(m_addr, STATUS_REG_M, &stm, 1) == ESP_OK && (stm & 0x08)
                && leer_xyz(m_addr, OUT_X_L_M | M_AUTO_INC, r) == ESP_OK) {
                for (int i = 0; i < 3; i++) mag[i] = r[i] * MAG_SENS_UT;
                b_mod = sqrtf(mag[0] * mag[0] + mag[1] * mag[1] + mag[2] * mag[2]);
                if (b_mod < b_min) b_min = b_mod;
                if (b_mod > b_max) b_max = b_mod;
                if (mag_cal && !ref_pendiente) {
                    float rm = rumbo_mag_deg(mag);
                    mag_unw += envolver_180(rm - rumbo_ant);
                    rumbo_ant = rm;
                }
            }
        }

        // Versus: referencia al quedar quieto tras calibrar, y una linea PARADA en cada posicion
        if (mag_cal && ahora - quieto_desde > VERSUS_QUIETO_US) {
            if (ref_pendiente) {
                rumbo_ant = rumbo_mag_deg(mag);
                mag_unw = 0.0;
                yaw_ref = yaw;
                giro_ult_parada = 0.0;
                ref_pendiente = false;
                printf("==> REFERENCIA: YAW GIRO = 0 y YAW MAG = 0 en esta posicion (grados, positivo"
                       " = antihorario). Girar la placa y dejarla quieta en cada posicion\n");
            } else {
                double d_giro = yaw - yaw_ref;
                if (fabs(d_giro - giro_ult_parada) > VERSUS_GIRO_MIN) {
                    printf("==> PARADA %d:  YAW GIRO = %+7.1f  |  YAW MAG = %+7.1f  |  diferencia = %+5.1f"
                           "  |  Bh = %.1f uT\n",
                           ++paradas, d_giro, mag_unw, d_giro - mag_unw, campo_h_cal(mag));
                    giro_ult_parada = d_giro;
                }
            }
        }

        int toques = leer_boton(ahora);

        // 2 toques de BOOT: nueva referencia en la posicion actual
        if (toques >= 2) {
            if (mag_cal) {
                ref_pendiente = true;
                paradas = 0;
                printf("\n>>> NUEVA REFERENCIA: dejar la placa QUIETA...\n");
            } else {
                printf("\n>>> Primero calibrar el magnetometro (1 toque de BOOT)\n");
            }
        }

        // 1 toque de BOOT: calibrar el magnetometro (invalida la prueba de deriva en curso)
        if (toques == 1) {
            if (!resultado_impreso) {
                printf("\n(La prueba de deriva en curso queda invalidada)\n");
                resultado_impreso = true;
            }
            calibrar_mag();
            // Durante la calibracion el yaw no se integro y la placa se movio: siempre se
            // vuelve a tomar la referencia (con la calibracion nueva o con la anterior)
            ref_pendiente = mag_cal;
            paradas = 0;
            if (mag_cal) printf("Dejar la placa QUIETA en la posicion inicial para tomar la referencia...\n");
            t_ult_giro = esp_timer_get_time();      // no integrar el hueco de la calibracion
            t_ult_print = t_ult_giro;
            quieto_desde = t_ult_giro;
            continue;
        }

        // Linea por segundo, resumen por minuto, resultado al final
        if (ahora - t_ult_print >= 1000000) {
            uint8_t tb[2];
            float temp = NAN;
            t_ult_print += 1000000;
            seg++;

            if (leer_regs(ag_addr, OUT_TEMP_L, tb, 2) == ESP_OK) {
                temp = (int16_t)((tb[1] << 8) | tb[0]) / 16.0f + 25.0f;
            }
            float a_mod = sqrtf(acc[0] * acc[0] + acc[1] * acc[1] + acc[2] * acc[2]);

            if (mag_cal && !ref_pendiente) {
                // Versus: solo los dos yaw desde la referencia
                double d_giro = yaw - yaw_ref;
                printf("[%4d s]  YAW GIRO = %+7.1f  |  YAW MAG = %+7.1f  |  diferencia = %+5.1f"
                       "  |  Bh = %4.1f uT\n", seg, d_giro, mag_unw, d_giro - mag_unw, campo_h_cal(mag));
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
                       " | |B| min/max %.1f/%.1f uT | errores I2C %" PRIu32 " ----\n",
                       seg / SUMMARY_PERIOD_S, yaw - yaw_resumen_ant, yaw, b_min, b_max, i2c_errores);
                yaw_resumen_ant = yaw;
                b_min = INFINITY;
                b_max = 0;
            }

            if (!resultado_impreso && seg >= TEST_DURATION_S) {
                printf("\n================ RESULTADO DE LA DERIVA ================\n");
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
    printf("   PRUEBA AISLADA DEL IMU LSM9DS1 (SparkFun Breakout)\n");
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
            printf("\n--- Buscando el LSM9DS1 ---\n");
            escanear_bus();
            if (detectar_lsm9ds1() && configurar_lsm9ds1() && calibrar_giro()) break;
            if (ag_addr == 0 && m_addr == 0) diagnosticar_cableado();
            printf("Reintentando en 3 s (revisar cableado y que VDD este en 3V3)...\n");
            vTaskDelay(pdMS_TO_TICKS(3000));
        }

        medir();
        printf("Reiniciando la prueba en 3 s...\n");
        vTaskDelay(pdMS_TO_TICKS(3000));
    }
}
