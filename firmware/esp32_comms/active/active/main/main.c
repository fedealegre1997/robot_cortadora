// ------------------------------------------------------------
// ESP32-S3 COMMS — enlace BLE con la app <-> sistema (micro-ROS)
//
// Rol: placa dedicada a la app. Recibe comandos de la app por BLE
// y los publica en /app_cmd; mas adelante relay de telemetria a la app.
// NO toma decisiones (eso es el Brain en la Raspberry) ni maneja
// actuadores (eso es el ESP motor).
//
// /app_cmd  (Int32MultiArray, 9 campos) — equivalen a /sensores[15-23]
//   del contrato BLE, pero en su topic propio:
//   [0] app_connected   (0/1, enlace cifrado y autenticado)
//   [1] app_state       (0 STOP, 1 MANUAL, 2 AUTO_RUN, 3 AUTO_PAUSE)
//   [2] app_dir         (0 nada,1 adel,2 atras,3 izq,4 der)
//   [3] app_speed       (0-100 %)
//   [4] app_cutter      (0/1)
//   [5] app_trimmer     (0/1)
//   [6] app_seq         (0-65535, eco)
//   [7] app_cmd_age_ms  (-1 = nunca llego comando)
//   [8] app_polygon_id  (0 = sin area)
//
// ETAPA A (bring-up): sin BLE todavia. Publica /app_cmd a 10 Hz con el
// estado "sin app" (connected=0, age=-1) y un contador de vida en seq,
// para validar toolchain + USB-JTAG + agente en esta placa.
//
// Version: 0.1 (bring-up)
// Fecha: 2026-11-15
// ------------------------------------------------------------

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#include <math.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "nvs_flash.h"
#include "driver/uart.h"
#include "sensor_nmea.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include <rcl/rcl.h>
#include <rcl/error_handling.h>
#include <rclc/rclc.h>
#include <std_msgs/msg/int32_multi_array.h>
#include <rmw_microros/rmw_microros.h>

#include <uxr/client/transport.h>
#include "esp32_serial_transport.h"

#define APP_CMD_SIZE   9

static size_t uart_port = 0;   // ignorado por el transporte USB-JTAG

#define RCCHECK(fn) { \
    rcl_ret_t temp_rc = fn; \
    if ((temp_rc != RCL_RET_OK)) { \
        ESP_LOGE("ROS", "Error en %s: %d", #fn, (int)temp_rc); \
        vTaskDelay(pdMS_TO_TICKS(1000)); \
        esp_restart(); \
    } \
}

// ====================================================================
// BLE (NimBLE) — ETAPA B paso 1: solo anuncia. Sin GATT ni seguridad aun.
// Servicio del contrato §2: d4d28957-613f-4007-8a1d-1deab4080779
// (NimBLE guarda el UUID 128-bit en little-endian: bytes invertidos.)
// ====================================================================
static const char *BLE_NAME = "Cortadora-E7";
static uint8_t g_ble_addr_type;
static volatile int g_ble_connected = 0;   // 1 cuando hay un central conectado (todavia sin cifrado)
static uint16_t g_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t g_tx_val_handle;            // handle de la caracteristica de notificaciones

// Ultimo comando CRUDO recibido por BLE (lo que mando la app). El estado
// EFECTIVO publicado en /app_cmd se calcula en la tarea micro-ROS aplicando
// las reglas de seguridad (recorte 300 ms, STOP retenido, AUTO tras STOP).
static volatile int32_t g_app_state = 0, g_app_dir = 0, g_app_speed = 0;
static volatile int32_t g_app_cutter = 0, g_app_trimmer = 0, g_app_seq = 0;
static volatile int64_t g_last_cmd_us = 0;  // 0 = nunca llego comando valido en esta conexion
static volatile int g_auto_unlocked = 0;    // un state:0 valido habilito AUTO en esta conexion (§8.2)
static volatile int g_auto_retained = 0;    // STOP retenido tras un corte en AUTO (§6.5)
static int64_t g_last_estop_us = 0;         // rate-limit del aviso ESTOP (1/s)

// Poligono VIGENTE (doble buffer: se parsea en temp y solo uno valido pasa a vigente).
static portMUX_TYPE g_poly_mux = portMUX_INITIALIZER_UNLOCKED;
static int32_t g_poly_id = 0;               // 0 = sin area (indice 23 / app_polygon_id)
static int32_t g_poly_pts[20];              // hasta 10 vertices (lat,lon) en 1e-7
static int g_poly_n = 0;                    // cantidad de vertices vigentes
static volatile int g_area_changed = 0;     // pedir republicacion inmediata de /app/working_area

// GPS (puente de la TX del GPS a un RX libre del comms; solo escucha).
#define GPS_UART_NUM   UART_NUM_1
#define GPS_RX_PIN     18
#define GPS_BAUD       9600
static volatile int32_t g_gps_fix = 0;       // 0 sin fix, 1 GPS, 2 DGPS
static volatile int32_t g_gps_lat_e7 = 0;    // 1e-7 grados
static volatile int32_t g_gps_lon_e7 = 0;
static volatile int     g_gps_has_pos = 0;
static volatile int32_t g_gps_sats = -1;
static volatile float   g_gps_hdop = -1.0f;

// Servicio del contrato §2: d4d28957-613f-4007-8a1d-1deab4080779
static const ble_uuid128_t SVC_UUID = BLE_UUID128_INIT(
    0x79, 0x07, 0x08, 0xb4, 0xea, 0x1d, 0x1d, 0x8a,
    0x07, 0x40, 0x3f, 0x61, 0x57, 0x89, 0xd2, 0xd4);
// RX (app -> ESP, write): 5a38f5bc-797e-4e23-97e6-efc129c921d5
static const ble_uuid128_t RX_UUID = BLE_UUID128_INIT(
    0xd5, 0x21, 0xc9, 0x29, 0xc1, 0xef, 0xe6, 0x97,
    0x23, 0x4e, 0x7e, 0x79, 0xbc, 0xf5, 0x38, 0x5a);
// TX (ESP -> app, notify): 9d803301-5ae6-4c4a-ab5a-8f783c540282
static const ble_uuid128_t TX_UUID = BLE_UUID128_INIT(
    0x82, 0x02, 0x54, 0x3c, 0x78, 0x8f, 0x5a, 0xab,
    0x4a, 0x4c, 0xe6, 0x5a, 0x01, 0x33, 0x80, 0x9d);

static void ble_advertise(void);

// ============ Parser ESTRICTO del CMD (contrato §5.1, casos CMD-1..19) ============
#define JKEY_MAX   48
#define JKEYS_MAX  16

static const char *json_skip_ws(const char *p)
{
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    return p;
}

// Decodifica una cadena JSON (incluye \uXXXX, \", \\, \/, \b\f\n\r\t) a UTF-8.
// p apunta a la comilla de apertura. Devuelve el puntero tras la de cierre, o NULL.
static const char *json_string(const char *p, char *out, size_t outsz)
{
    if (*p != '"') return NULL;
    p++;
    size_t o = 0;
    while (*p && *p != '"') {
        if (*p == '\\') {
            p++;
            char esc = *p;
            switch (esc) {
                case '"': case '\\': case '/':
                    if (o < outsz - 1) out[o++] = esc;
                    p++;
                    break;
                case 'b': if (o < outsz-1) { out[o++]='\b'; } p++; break;
                case 'f': if (o < outsz-1) { out[o++]='\f'; } p++; break;
                case 'n': if (o < outsz-1) { out[o++]='\n'; } p++; break;
                case 'r': if (o < outsz-1) { out[o++]='\r'; } p++; break;
                case 't': if (o < outsz-1) { out[o++]='\t'; } p++; break;
                case 'u': {
                    unsigned cp = 0;
                    for (int i = 0; i < 4; i++) {
                        p++;
                        char h = *p; int d;
                        if (h >= '0' && h <= '9') d = h - '0';
                        else if (h >= 'a' && h <= 'f') d = h - 'a' + 10;
                        else if (h >= 'A' && h <= 'F') d = h - 'A' + 10;
                        else return NULL;
                        cp = (cp << 4) | d;
                    }
                    p++;
                    if (cp < 0x80) { if (o<outsz-1) out[o++]=(char)cp; }
                    else if (cp < 0x800) { if (o<outsz-2){ out[o++]=0xC0|(cp>>6); out[o++]=0x80|(cp&0x3F);} }
                    else { if (o<outsz-3){ out[o++]=0xE0|(cp>>12); out[o++]=0x80|((cp>>6)&0x3F); out[o++]=0x80|(cp&0x3F);} }
                    break;
                }
                default: return NULL;
            }
        } else {
            if (o < outsz - 1) out[o++] = *p;
            p++;
        }
    }
    if (*p != '"') return NULL;
    out[o] = '\0';
    return p + 1;
}

// Valor entero JSON: - opcional + digitos, terminado en delimitador.
// Rechaza decimales (50.5), notacion cientifica y strings ("50").
static const char *json_int(const char *p, int32_t *out)
{
    p = json_skip_ws(p);
    const char *start = p;
    if (*p == '-') p++;
    if (!(*p >= '0' && *p <= '9')) return NULL;
    while (*p >= '0' && *p <= '9') p++;
    char c = *p;
    if (c != ',' && c != '}' && c != ' ' && c != '\t' && c != '\r' && c != '\n') return NULL;
    *out = (int32_t)strtol(start, NULL, 10);
    return p;
}

// Salta cualquier valor JSON (string/numero/literal/array/objeto). NULL si malformado.
static const char *json_skip_value(const char *p)
{
    p = json_skip_ws(p);
    if (!*p) return NULL;
    if (*p == '"') {
        p++;
        while (*p && *p != '"') { if (*p == '\\') { p++; if (!*p) return NULL; } p++; }
        return (*p == '"') ? p + 1 : NULL;
    }
    if (*p == '[' || *p == '{') {
        int depth = 0;
        while (*p) {
            if (*p == '"') {
                p++;
                while (*p && *p != '"') { if (*p == '\\') { p++; if (!*p) return NULL; } p++; }
                if (*p != '"') return NULL;
                p++;
                continue;
            }
            if (*p == '[' || *p == '{') depth++;
            else if (*p == ']' || *p == '}') { depth--; if (depth == 0) return p + 1; }
            p++;
        }
        return NULL;
    }
    const char *start = p;
    while (*p && *p != ',' && *p != '}' && *p != ']' &&
           *p != ' ' && *p != '\t' && *p != '\r' && *p != '\n') p++;
    return (p > start) ? p : NULL;
}

// Parsea y valida un CMD completo. Si es valido, actualiza los globales crudos
// y devuelve true. Rechaza claves duplicadas (decodificadas), campos faltantes,
// tipos/ rangos incorrectos y t != "CMD".
static bool parse_cmd_strict(const char *line)
{
    char seen[JKEYS_MAX][JKEY_MAX];
    int nseen = 0;
    const char *p = json_skip_ws(line);
    if (*p != '{') return false;
    p++;

    bool h_t=false,h_state=false,h_dir=false,h_speed=false,h_cut=false,h_trim=false,h_seq=false;
    bool t_ok = false;
    int32_t state=0,dir=0,speed=0,cutter=0,trimmer=0,seq=0;

    p = json_skip_ws(p);
    if (*p == '}') return false;   // objeto vacio: faltan campos

    while (1) {
        p = json_skip_ws(p);
        char key[JKEY_MAX];
        const char *np = json_string(p, key, sizeof(key));
        if (!np) return false;
        p = json_skip_ws(np);
        if (*p != ':') return false;
        p++;

        for (int i = 0; i < nseen; i++) if (strcmp(seen[i], key) == 0) return false;  // duplicada
        if (nseen < JKEYS_MAX) { strncpy(seen[nseen], key, JKEY_MAX-1); seen[nseen][JKEY_MAX-1]='\0'; nseen++; }

        const char *after;
        if (strcmp(key, "t") == 0) {
            char val[16];
            after = json_string(json_skip_ws(p), val, sizeof(val));
            if (!after) return false;         // t debe ser string
            t_ok = (strcmp(val, "CMD") == 0);
            h_t = true;
        } else if (strcmp(key, "state") == 0)   { if (!(after = json_int(p, &state)))   return false; h_state = true; }
        else if (strcmp(key, "dir") == 0)       { if (!(after = json_int(p, &dir)))     return false; h_dir = true; }
        else if (strcmp(key, "speed") == 0)     { if (!(after = json_int(p, &speed)))   return false; h_speed = true; }
        else if (strcmp(key, "cutter") == 0)    { if (!(after = json_int(p, &cutter)))  return false; h_cut = true; }
        else if (strcmp(key, "trimmer") == 0)   { if (!(after = json_int(p, &trimmer))) return false; h_trim = true; }
        else if (strcmp(key, "seq") == 0)       { if (!(after = json_int(p, &seq)))     return false; h_seq = true; }
        else { if (!(after = json_skip_value(p))) return false; }   // clave desconocida: se ignora

        p = json_skip_ws(after);
        if (*p == ',') { p++; continue; }
        if (*p == '}') break;
        return false;
    }
    p = json_skip_ws(p + 1);
    if (*p != '\0') return false;   // basura despues del objeto

    if (!(h_t && h_state && h_dir && h_speed && h_cut && h_trim && h_seq)) return false;
    if (!t_ok) return false;
    if (state < 0 || state > 3) return false;
    if (dir < 0 || dir > 4) return false;
    if (speed < 0 || speed > 100) return false;
    if (cutter < 0 || cutter > 1) return false;
    if (trimmer < 0 || trimmer > 1) return false;
    if (seq < 0 || seq > 65535) return false;

    g_app_state = state; g_app_dir = dir; g_app_speed = speed;
    g_app_cutter = cutter; g_app_trimmer = trimmer; g_app_seq = seq;
    g_last_cmd_us = esp_timer_get_time();
    if (state == 0) { g_auto_unlocked = 1; g_auto_retained = 0; }   // STOP habilita AUTO y libera retencion
    return true;
}

// ============ POLY (contrato §5.4-§5.6, casos POLY-1..22) ============
typedef enum { PERR_NONE = 0, PERR_FMT, PERR_IDC, PERR_NVERT, PERR_RANGE } perr_t;

// Entero largo JSON (para id y coordenadas, y detectar fuera de int32).
static const char *json_ll(const char *p, long long *out)
{
    p = json_skip_ws(p);
    const char *start = p;
    if (*p == '-') p++;
    if (!(*p >= '0' && *p <= '9')) return NULL;
    while (*p >= '0' && *p <= '9') p++;
    char c = *p;
    if (c != ',' && c != '}' && c != ']' && c != ' ' && c != '\t' && c != '\r' && c != '\n') return NULL;
    *out = strtoll(start, NULL, 10);
    return p;
}

// Devuelve el valor de "t" (primer nivel) en out, o false si no lo encuentra / JSON malo.
static bool json_get_t(const char *line, char *out, size_t outsz)
{
    const char *p = json_skip_ws(line);
    if (*p != '{') return false;
    p++;
    while (1) {
        p = json_skip_ws(p);
        if (*p == '}') return false;
        char key[JKEY_MAX];
        const char *np = json_string(p, key, sizeof(key));
        if (!np) return false;
        p = json_skip_ws(np);
        if (*p != ':') return false;
        p++;
        if (strcmp(key, "t") == 0) {
            const char *after = json_string(json_skip_ws(p), out, outsz);
            return (after != NULL);
        }
        const char *after = json_skip_value(p);
        if (!after) return false;
        p = json_skip_ws(after);
        if (*p == ',') { p++; continue; }
        return false;
    }
}

// Parsea POLY. Prioridad de validacion: formato -> id -> nvert -> rango.
// En OK devuelve PERR_NONE + id + pts[2*n] + n. En error, el codigo; *id_echo=1
// si el PERR debe llevar id (con *id_out), 0 si se omite.
static perr_t parse_poly(const char *line, int32_t *id_out, int *id_echo,
                         int32_t pts[20], int *n_out)
{
    *id_echo = 0; *id_out = 0; *n_out = 0;
    long long id_ll = 0; bool h_id = false;
    bool h_t = false, t_ok = false;
    bool p_present = false, p_bad = false;
    long long coords[32]; int n = 0;

    const char *p = json_skip_ws(line);
    if (*p != '{') return PERR_FMT;
    p++;
    p = json_skip_ws(p);
    if (*p == '}') return PERR_FMT;

    while (1) {
        p = json_skip_ws(p);
        char key[JKEY_MAX];
        const char *np = json_string(p, key, sizeof(key));
        if (!np) return PERR_FMT;
        p = json_skip_ws(np);
        if (*p != ':') return PERR_FMT;
        p++;
        const char *after;
        if (strcmp(key, "t") == 0) {
            char val[16];
            after = json_string(json_skip_ws(p), val, sizeof(val));
            if (!after) return PERR_FMT;
            h_t = true; t_ok = (strcmp(val, "POLY") == 0);
        } else if (strcmp(key, "id") == 0) {
            after = json_ll(p, &id_ll);
            if (!after) return PERR_FMT;        // id presente pero no entero
            h_id = true;
        } else if (strcmp(key, "p") == 0) {
            p_present = true;
            const char *q = json_skip_ws(p);
            if (*q != '[') { after = json_skip_value(p); if (!after) return PERR_FMT; p_bad = true; }
            else {
                q++; q = json_skip_ws(q);
                if (*q == ']') { after = q + 1; }
                else {
                    while (1) {
                        q = json_skip_ws(q);
                        if (*q != '[') { p_bad = true; break; }
                        q++;
                        long long a, b;
                        const char *r = json_ll(q, &a); if (!r) { p_bad = true; break; }
                        r = json_skip_ws(r); if (*r != ',') { p_bad = true; break; } r++;
                        r = json_ll(r, &b); if (!r) { p_bad = true; break; }
                        r = json_skip_ws(r); if (*r != ']') { p_bad = true; break; } r++;
                        if (n < 16) { coords[2*n] = a; coords[2*n+1] = b; }
                        n++;
                        r = json_skip_ws(r);
                        if (*r == ',') { q = r + 1; continue; }
                        if (*r == ']') { after = r + 1; break; }
                        p_bad = true; break;
                    }
                    if (p_bad) { after = json_skip_value(p); if (!after) return PERR_FMT; }
                }
            }
        } else {
            after = json_skip_value(p); if (!after) return PERR_FMT;
        }
        p = json_skip_ws(after);
        if (*p == ',') { p++; continue; }
        if (*p == '}') break;
        return PERR_FMT;
    }
    p = json_skip_ws(p + 1);
    if (*p != '\0') return PERR_FMT;

    // Formato
    if (!h_t || !t_ok || !h_id || !p_present || p_bad) {
        if (h_id && id_ll >= 1 && id_ll <= 65535) { *id_out = (int32_t)id_ll; *id_echo = 1; }
        return PERR_FMT;
    }
    // id
    if (id_ll < 1 || id_ll > 65535) {
        if (id_ll >= INT_MIN && id_ll <= INT_MAX) { *id_out = (int32_t)id_ll; *id_echo = 1; }
        return PERR_IDC;
    }
    *id_out = (int32_t)id_ll; *id_echo = 1;
    // nvert
    if (n < 3 || n > 10) return PERR_NVERT;
    // rango int32 de las coordenadas
    for (int i = 0; i < 2 * n; i++) {
        if (coords[i] < INT_MIN || coords[i] > INT_MAX) return PERR_RANGE;
    }
    for (int i = 0; i < 2 * n; i++) pts[i] = (int32_t)coords[i];
    *n_out = n;
    return PERR_NONE;
}

static void ble_notify_line(const char *line)
{
    if (g_conn_handle == BLE_HS_CONN_HANDLE_NONE) return;
    struct os_mbuf *om = ble_hs_mbuf_from_flat(line, strlen(line));
    if (om) ble_gatts_notify_custom(g_conn_handle, g_tx_val_handle, om);
}

static void ble_send_area(void)
{
    portENTER_CRITICAL(&g_poly_mux);
    int32_t id = g_poly_id;
    portEXIT_CRITICAL(&g_poly_mux);
    char area[24];
    snprintf(area, sizeof(area), "{\"t\":\"AREA\",\"id\":%ld}\n", (long)id);
    ble_notify_line(area);
}

static void ble_send_gps(void)
{
    int32_t fix = g_gps_fix, sats = g_gps_sats;
    int has_pos = g_gps_has_pos;
    int32_t lat = g_gps_lat_e7, lon = g_gps_lon_e7;
    float hdop = g_gps_hdop;
    char msg[96];
    char hdop_s[12];
    if (hdop < 0) snprintf(hdop_s, sizeof(hdop_s), "-1");
    else snprintf(hdop_s, sizeof(hdop_s), "%.1f", hdop);

    if (fix > 0 && has_pos) {
        snprintf(msg, sizeof(msg),
                 "{\"t\":\"GPS\",\"fix\":%ld,\"lat\":%ld,\"lon\":%ld,\"sats\":%ld,\"hdop\":%s}\n",
                 (long)fix, (long)lat, (long)lon, (long)sats, hdop_s);
    } else {   // sin fix: se omiten lat/lon (§5.3)
        snprintf(msg, sizeof(msg),
                 "{\"t\":\"GPS\",\"fix\":%ld,\"sats\":%ld,\"hdop\":%s}\n",
                 (long)fix, (long)sats, hdop_s);
    }
    ble_notify_line(msg);
}

static const char *perr_code_str(perr_t e)
{
    switch (e) {
        case PERR_FMT:   return "FMT";
        case PERR_IDC:   return "ID";
        case PERR_NVERT: return "NVERT";
        case PERR_RANGE: return "RANGE";
        default:         return "FMT";
    }
}

// Procesa una linea completa recibida por BLE (ya sin '\n'). `overlong` = la
// linea supero el buffer de 512 B (regla LEN del contrato §4).
static void process_line(const char *line, bool overlong)
{
    char type[16];

    if (overlong) {
        // Linea > 512 B: solo se responde PERR LEN si empieza como POLY.
        const char *q = json_skip_ws(line);
        if (strncmp(q, "{\"t\":\"POLY\"", 11) == 0)
            ble_notify_line("{\"t\":\"PERR\",\"e\":\"LEN\"}\n");
        return;
    }

    if (!json_get_t(line, type, sizeof(type))) return;   // JSON malo o sin "t": se ignora

    if (strcmp(type, "CMD") == 0) {
        if (parse_cmd_strict(line)) {
            char ack[32];
            snprintf(ack, sizeof(ack), "{\"t\":\"ACK\",\"seq\":%ld}\n", (long)g_app_seq);
            ble_notify_line(ack);
        }
    } else if (strcmp(type, "POLY") == 0) {
        int32_t id, pts[20], n; int id_echo;
        perr_t e = parse_poly(line, &id, &id_echo, pts, &n);
        if (e == PERR_NONE) {
            portENTER_CRITICAL(&g_poly_mux);
            g_poly_id = id; g_poly_n = n;
            for (int i = 0; i < 2 * n; i++) g_poly_pts[i] = pts[i];
            portEXIT_CRITICAL(&g_poly_mux);
            char pok[24];
            snprintf(pok, sizeof(pok), "{\"t\":\"POK\",\"id\":%ld}\n", (long)id);
            ble_notify_line(pok);
            ble_send_area();         // AREA va DESPUES del POK (§5.8)
            g_area_changed = 1;      // republicar /app/working_area ya
        } else {
            char perr[48];
            if (id_echo)
                snprintf(perr, sizeof(perr), "{\"t\":\"PERR\",\"id\":%ld,\"e\":\"%s\"}\n", (long)id, perr_code_str(e));
            else
                snprintf(perr, sizeof(perr), "{\"t\":\"PERR\",\"e\":\"%s\"}\n", perr_code_str(e));
            ble_notify_line(perr);
        }
    } else if (strcmp(type, "PCLR") == 0) {
        portENTER_CRITICAL(&g_poly_mux);
        g_poly_id = 0; g_poly_n = 0;
        portEXIT_CRITICAL(&g_poly_mux);
        ble_send_area();            // tras PCLR: AREA id:0 (sin POK/PERR)
        g_area_changed = 1;
    }
    // Tipo desconocido: se ignora (sin respuesta).
}

// Acumula fragmentos de la caracteristica RX hasta '\n' e interpreta la linea.
static int gatt_rx_access(uint16_t conn, uint16_t attr,
                          struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn; (void)attr; (void)arg;
    static char buf[520];
    static size_t len = 0;
    static bool overlong = false;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return 0;

    uint8_t tmp[540];
    uint16_t copied = 0;
    ble_hs_mbuf_to_flat(ctxt->om, tmp, sizeof(tmp), &copied);

    for (uint16_t i = 0; i < copied; i++) {
        char c = (char)tmp[i];
        if (c == '\n') {
            buf[len] = '\0';
            process_line(buf, overlong);
            len = 0;
            overlong = false;
        } else if (c != '\r') {
            if (len < 512) buf[len++] = c;
            else overlong = true;   // > 512 B: regla LEN (§4)
        }
    }
    return 0;
}

static const struct ble_gatt_svc_def gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &SVC_UUID.u,
        .characteristics = (struct ble_gatt_chr_def[]){
            {
                .uuid = &RX_UUID.u,
                .access_cb = gatt_rx_access,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {
                .uuid = &TX_UUID.u,
                .access_cb = gatt_rx_access,   // no se lee; notify
                .flags = BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &g_tx_val_handle,
            },
            { 0 }
        },
    },
    { 0 }
};

static int ble_gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
        case BLE_GAP_EVENT_CONNECT:
            ESP_LOGW("BLE", "CONNECT status=%d", event->connect.status);
            if (event->connect.status == 0) {
                g_ble_connected = 1;        // conectado: el ESP deja de anunciar
                g_conn_handle = event->connect.conn_handle;
                g_last_cmd_us = 0;          // conexion nueva: sin comando aun (§8.2)
                g_auto_unlocked = 0;        // AUTO solo tras un state:0
                g_auto_retained = 0;
            } else {
                ble_advertise();            // fallo al conectar: volver a anunciar
            }
            break;
        case BLE_GAP_EVENT_DISCONNECT:
            ESP_LOGW("BLE", "DISCONNECT reason=0x%02x (%d)",
                     event->disconnect.reason, event->disconnect.reason);
            g_ble_connected = 0;
            g_conn_handle = BLE_HS_CONN_HANDLE_NONE;
            g_last_cmd_us = 0;              // conexion nueva arranca sin comando (contrato §8.2)
            g_app_state = g_app_dir = g_app_speed = 0;
            g_app_cutter = g_app_trimmer = g_app_seq = 0;
            g_auto_unlocked = 0;           // AUTO solo tras un state:0 en la conexion nueva
            g_auto_retained = 0;
            ble_advertise();
            break;
        case BLE_GAP_EVENT_ADV_COMPLETE:
            ble_advertise();
            break;
        case BLE_GAP_EVENT_SUBSCRIBE:
            // La app activo las notificaciones (CCCD) en la caracteristica TX:
            // mandar AREA con el area vigente (§5.8 regla 1).
            if (event->subscribe.attr_handle == g_tx_val_handle && event->subscribe.cur_notify)
                ble_send_area();
            break;
        default:
            break;
    }
    return 0;
}

static void ble_advertise(void)
{
    // Paquete de anuncio: flags + UUID de servicio de 128 bits (la app filtra por el).
    struct ble_hs_adv_fields fields;
    memset(&fields, 0, sizeof fields);
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = (ble_uuid128_t *)&SVC_UUID;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    ble_gap_adv_set_fields(&fields);

    // Respuesta de escaneo: el nombre (contrato §2.1).
    struct ble_hs_adv_fields rsp;
    memset(&rsp, 0, sizeof rsp);
    rsp.name = (uint8_t *)BLE_NAME;
    rsp.name_len = strlen(BLE_NAME);
    rsp.name_is_complete = 1;
    ble_gap_adv_rsp_set_fields(&rsp);

    struct ble_gap_adv_params adv_params;
    memset(&adv_params, 0, sizeof adv_params);
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    ble_gap_adv_start(g_ble_addr_type, NULL, BLE_HS_FOREVER,
                      &adv_params, ble_gap_event, NULL);
}

static void ble_on_sync(void)
{
    ble_hs_id_infer_auto(0, &g_ble_addr_type);
    ble_advertise();
}

static void ble_host_task(void *param)
{
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

static void ble_init(void)
{
    if (nimble_port_init() != ESP_OK) {
        return;
    }
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_gatts_count_cfg(gatt_svcs);
    ble_gatts_add_svcs(gatt_svcs);
    ble_svc_gap_device_name_set(BLE_NAME);
    ble_hs_cfg.sync_cb = ble_on_sync;
    nimble_port_freertos_init(ble_host_task);
}

static void micro_ros_task(void *arg)
{
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(1000));

    rcl_allocator_t allocator = rcl_get_default_allocator();
    rclc_support_t support;

    // Esperar al agente con pings SUAVES (no martillar sesiones): un ping es un
    // solo paquete, y entre intentos dormimos 500 ms. Asi el cliente no satura
    // el USB ni le roba tiempo al stack BLE cuando el agente no esta.
    while (rmw_uros_ping_agent(200, 1) != RMW_RET_OK) {
        vTaskDelay(pdMS_TO_TICKS(500));
    }

    RCCHECK(rclc_support_init(&support, 0, NULL, &allocator));

    vTaskDelay(pdMS_TO_TICKS(500));

    rcl_node_t node;
    RCCHECK(rclc_node_init_default(&node, "esp32_comms_node", "/", &support));

    vTaskDelay(pdMS_TO_TICKS(500));

    rcl_publisher_t pub;
    RCCHECK(rclc_publisher_init_default(
        &pub,
        &node,
        ROSIDL_GET_MSG_TYPE_SUPPORT(std_msgs, msg, Int32MultiArray),
        "app_cmd"
    ));

    rcl_publisher_t pub_area;
    RCCHECK(rclc_publisher_init_default(
        &pub_area,
        &node,
        ROSIDL_GET_MSG_TYPE_SUPPORT(std_msgs, msg, Int32MultiArray),
        "app/working_area"
    ));

    std_msgs__msg__Int32MultiArray area_msg;
    std_msgs__msg__Int32MultiArray__init(&area_msg);
    area_msg.data.data = (int32_t *)malloc(22 * sizeof(int32_t));   // [id, n, lat0, lon0, ...] hasta 2+2*10
    area_msg.data.capacity = 22;
    area_msg.data.size = 2;
    area_msg.layout.dim.size = 0;
    area_msg.layout.dim.capacity = 0;
    int area_ciclos = 0;

    std_msgs__msg__Int32MultiArray msg;
    std_msgs__msg__Int32MultiArray__init(&msg);
    msg.data.data = (int32_t *)malloc(APP_CMD_SIZE * sizeof(int32_t));
    msg.data.size = APP_CMD_SIZE;
    msg.data.capacity = APP_CMD_SIZE;
    msg.layout.dim.size = 0;
    msg.layout.dim.capacity = 0;

    int32_t seq = 0;

    while (1) {
        // ETAPA A: estado "sin app conectada" + contador de vida en seq.
        // ---- Estado EFECTIVO con las reglas de seguridad (contrato §8.1) ----
        int connected = g_ble_connected;
        int64_t now = esp_timer_get_time();
        int64_t last = g_last_cmd_us;
        int32_t age = (last == 0) ? -1 : (int32_t)((now - last) / 1000);
        int cut = (!connected) || (last == 0) || (age > 300);   // 300 vale, 301 corta

        int32_t raw_state = g_app_state;
        int32_t e_state, e_dir, e_cutter, e_trimmer;
        int32_t e_speed = g_app_speed, e_seq = g_app_seq;   // speed y seq se conservan (§T-3)

        if (cut) {
            if (raw_state == 2 || raw_state == 3) {         // se corto en AUTO -> retener
                if (!g_auto_retained) {
                    g_auto_retained = 1;
                    if (connected && last != 0 && age > 300) {  // aviso por timeout con enlace vivo
                        ble_notify_line("{\"t\":\"ESTOP\",\"why\":\"T\"}\n");
                        g_last_estop_us = now;
                    }
                } else if (connected && (now - g_last_estop_us) > 1000000) {
                    ble_notify_line("{\"t\":\"ESTOP\",\"why\":\"T\"}\n");   // max 1/s mientras retiene
                    g_last_estop_us = now;
                }
            }
            e_state = 0; e_dir = 0; e_cutter = 0; e_trimmer = 0;
        } else if (raw_state == 2 || raw_state == 3) {      // AUTO: solo si habilitado y sin retener
            if (g_auto_unlocked && !g_auto_retained) {
                e_state = raw_state; e_dir = g_app_dir;
                e_cutter = g_app_cutter; e_trimmer = g_app_trimmer;
            } else {
                e_state = 0; e_dir = 0; e_cutter = 0; e_trimmer = 0;
            }
        } else {                                            // STOP o MANUAL
            e_state = raw_state; e_dir = g_app_dir;
            e_cutter = g_app_cutter; e_trimmer = g_app_trimmer;
        }

        msg.data.data[0] = connected;   // app_connected
        msg.data.data[1] = e_state;
        msg.data.data[2] = e_dir;
        msg.data.data[3] = e_speed;
        msg.data.data[4] = e_cutter;
        msg.data.data[5] = e_trimmer;
        msg.data.data[6] = e_seq;
        msg.data.data[7] = age;         // app_cmd_age_ms (-1 = nunca llego comando)
        msg.data.data[8] = g_poly_id;   // app_polygon_id (area vigente)

        rcl_publish(&pub, &msg, NULL);

        // ---- /app/working_area: al cambiar el area y cada ~2 s (contrato §5.4) ----
        area_ciclos++;
        if (g_area_changed || area_ciclos >= 40) {   // 40*50ms = 2 s
            g_area_changed = 0;
            area_ciclos = 0;
            portENTER_CRITICAL(&g_poly_mux);
            int32_t pid = g_poly_id, pn = g_poly_n;
            area_msg.data.data[0] = pid;
            area_msg.data.data[1] = pn;
            for (int i = 0; i < 2 * pn && i < 20; i++) area_msg.data.data[2 + i] = g_poly_pts[i];
            portEXIT_CRITICAL(&g_poly_mux);
            area_msg.data.size = 2 + 2 * pn;
            rcl_publish(&pub_area, &area_msg, NULL);
        }

        (void)seq;
        vTaskDelay(pdMS_TO_TICKS(50));   // 20 Hz (recorte de 300 ms mas ajustado)
    }
}

// ============ GPS — parser NMEA GGA (portado del sensor) ============
static double nmea_to_decimal(const char *coord, char hemisphere)
{
    if (coord == NULL || coord[0] == '\0') return NAN;
    char *end;
    double raw = strtod(coord, &end);
    if (*end || !isfinite(raw) || raw < 0 || raw > 18000) return NAN;
    int degrees = (int)(raw / 100.0);
    double minutes = raw - (degrees * 100.0);
    int limit = (hemisphere == 'N' || hemisphere == 'S') ? 90 : 180;
    if (hemisphere != 'N' && hemisphere != 'S' && hemisphere != 'E' && hemisphere != 'W') return NAN;
    if (minutes >= 60 || degrees > limit || (degrees == limit && minutes != 0)) return NAN;
    double decimal = degrees + (minutes / 60.0);
    if (hemisphere == 'S' || hemisphere == 'W') decimal = -decimal;
    return decimal;
}

static bool parse_gga_line(const char *line, double *lat, double *lon,
                           int *fix_quality, int *satellites, double *hdop)
{
    if (!sensor_nmea_checksum_ok(line)) return false;
    if (strncmp(line, "$GPGGA", 6) != 0 && strncmp(line, "$GNGGA", 6) != 0) return false;

    char buffer[256];
    if (strlen(line) >= sizeof(buffer)) return false;
    strncpy(buffer, line, sizeof(buffer) - 1);
    buffer[sizeof(buffer) - 1] = '\0';
    char *star = strchr(buffer, '*');
    if (star) *star = '\0';

    char lat_str[20]={0}, lon_str[20]={0}, fix_str[8]={0}, sats_str[8]={0}, hdop_str[12]={0};
    char ns='\0', ew='\0';
    char *token = buffer;
    int fi = 0;
    while (token != NULL) {
        char *sep = strchr(token, ',');
        if (sep) *sep = '\0';
        switch (fi) {
            case 2: strncpy(lat_str, token, sizeof(lat_str)-1); break;
            case 3: ns = token[0]; break;
            case 4: strncpy(lon_str, token, sizeof(lon_str)-1); break;
            case 5: ew = token[0]; break;
            case 6: strncpy(fix_str, token, sizeof(fix_str)-1); break;
            case 7: strncpy(sats_str, token, sizeof(sats_str)-1); break;
            case 8: strncpy(hdop_str, token, sizeof(hdop_str)-1); break;
            default: break;
        }
        token = sep ? sep + 1 : NULL;
        fi++;
    }
    if (fi < 15 || !fix_str[0]) return false;
    char *fend;
    long fix = strtol(fix_str, &fend, 10);
    if (*fend || fix < 0 || fix > 8) return false;
    *fix_quality = (int)fix;
    *satellites = (sats_str[0]) ? atoi(sats_str) : -1;
    *hdop = (hdop_str[0]) ? atof(hdop_str) : -1.0;
    if (*fix_quality > 0) {
        *lat = nmea_to_decimal(lat_str, ns);
        *lon = nmea_to_decimal(lon_str, ew);
        if (!isfinite(*lat) || !isfinite(*lon)) return false;
    } else {
        *lat = NAN; *lon = NAN;
    }
    return true;
}

static void init_gps_uart(void)
{
    uart_config_t cfg = {
        .baud_rate = GPS_BAUD,
        .data_bits = UART_DATA_8_BITS,
        .parity    = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    uart_driver_install(GPS_UART_NUM, 2048, 0, 0, NULL, 0);
    uart_param_config(GPS_UART_NUM, &cfg);
    // Solo RX: escuchamos la TX del GPS. TX del comms sin conectar.
    uart_set_pin(GPS_UART_NUM, UART_PIN_NO_CHANGE, GPS_RX_PIN, UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE);
}

static void gps_task(void *arg)
{
    (void)arg;
    init_gps_uart();
    uint8_t rx[512];
    char line[256];
    int pos = 0;
    bool overflow = false;
    int64_t last_emit = 0;

    while (1) {
        int len = uart_read_bytes(GPS_UART_NUM, rx, sizeof(rx), pdMS_TO_TICKS(50));
        for (int i = 0; i < len; i++) {
            char c = (char)rx[i];
            if (c == '\r') continue;
            if (c == '\n') {
                if (overflow) { overflow = false; pos = 0; continue; }
                if (pos > 0) {
                    line[pos] = '\0';
                    double lat, lon; int fix, sats; double hdop;
                    if (parse_gga_line(line, &lat, &lon, &fix, &sats, &hdop)) {
                        g_gps_fix = fix;
                        g_gps_sats = sats;
                        g_gps_hdop = (float)hdop;
                        if (fix > 0 && isfinite(lat) && isfinite(lon)) {
                            g_gps_lat_e7 = (int32_t)llround(lat * 1e7);
                            g_gps_lon_e7 = (int32_t)llround(lon * 1e7);
                            g_gps_has_pos = 1;
                        } else {
                            g_gps_has_pos = 0;
                        }
                    }
                }
                pos = 0;
            } else if (pos < (int)sizeof(line) - 1) {
                line[pos++] = c;
            } else {
                overflow = true;
            }
        }
        // Emitir GPS por BLE ~1 Hz (la app lo espera a ~1 Hz, §5.3).
        int64_t now = esp_timer_get_time();
        if (now - last_emit > 1000000) {
            last_emit = now;
            ble_send_gps();
        }
    }
}

void app_main(void)
{
    esp_log_level_set("*", ESP_LOG_NONE);

    esp_err_t nvs_rc = nvs_flash_init();
    if (nvs_rc == ESP_ERR_NVS_NO_FREE_PAGES || nvs_rc == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_flash_init();
    }

    ble_init();

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

    xTaskCreatePinnedToCore(micro_ros_task, "uros_task", 16384, NULL, 5, NULL, 1);
    xTaskCreatePinnedToCore(gps_task,       "gps_task",   4096, NULL, 4, NULL, 0);
}
