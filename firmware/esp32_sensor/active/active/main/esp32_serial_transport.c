// Transporte micro-ROS para ESP32-S3 por USB-Serial-JTAG nativo.
// En esta placa el conector COM (CH343) no esta cableado a UART0, asi que
// micro-ROS viaja por el USB nativo (303a:1001). Un solo cable flashea y
// comunica. El driver USB-Serial-JTAG reemplaza al UART; transport->args se
// ignora. La consola secundaria USB-JTAG debe quedar deshabilitada
// (CONFIG_ESP_CONSOLE_SECONDARY_NONE) para no mezclarse con los datos.

#include <uxr/client/transport.h>

#include "driver/usb_serial_jtag.h"
#include "freertos/FreeRTOS.h"

#define USJ_RX_BUFFER_SIZE (1024)
#define USJ_TX_BUFFER_SIZE (1024)

bool esp32_serial_open(struct uxrCustomTransport * transport){
    (void) transport;

    usb_serial_jtag_driver_config_t cfg = {
        .rx_buffer_size = USJ_RX_BUFFER_SIZE,
        .tx_buffer_size = USJ_TX_BUFFER_SIZE,
    };

    return usb_serial_jtag_driver_install(&cfg) == ESP_OK;
}

bool esp32_serial_close(struct uxrCustomTransport * transport){
    (void) transport;
    return true;
}

size_t esp32_serial_write(struct uxrCustomTransport* transport, const uint8_t * buf, size_t len, uint8_t * err){
    (void) transport;
    (void) err;
    const int txBytes = usb_serial_jtag_write_bytes((const char*) buf, len, portMAX_DELAY);
    return txBytes < 0 ? 0 : (size_t) txBytes;
}

size_t esp32_serial_read(struct uxrCustomTransport* transport, uint8_t* buf, size_t len, int timeout, uint8_t* err){
    (void) transport;
    (void) err;
    const int rxBytes = usb_serial_jtag_read_bytes(buf, len, pdMS_TO_TICKS(timeout));
    return rxBytes < 0 ? 0 : (size_t) rxBytes;
}
