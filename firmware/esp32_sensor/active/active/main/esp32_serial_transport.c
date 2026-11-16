// Transporte micro-ROS por USB-Serial-JTAG nativo del ESP32-S3.
// Acceso exclusivo al FIFO: la consola USB debe estar deshabilitada.
// Las esperas ceden al scheduler; usar CONFIG_FREERTOS_HZ=1000.
#include <uxr/client/transport.h>
#include "hal/usb_serial_jtag_ll.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_timer.h"

bool esp32_serial_open(struct uxrCustomTransport *transport)
{
    (void)transport;
    usb_serial_jtag_ll_disable_intr_mask(USB_SERIAL_JTAG_LL_INTR_MASK);
    usb_serial_jtag_ll_clr_intsts_mask(USB_SERIAL_JTAG_LL_INTR_MASK);
    return true;
}

bool esp32_serial_close(struct uxrCustomTransport *transport)
{
    (void)transport;
    return true;
}

size_t esp32_serial_write(struct uxrCustomTransport *transport,
                         const uint8_t *buf, size_t len, uint8_t *err)
{
    (void)transport;
    *err = 0;
    size_t sent = 0;
    const int64_t deadline = esp_timer_get_time() + 1000000;
    while (sent < len) {
        size_t n = usb_serial_jtag_ll_write_txfifo(buf + sent, len - sent);
        if (n) {
            sent += n;
            usb_serial_jtag_ll_txfifo_flush();
        } else {
            if (esp_timer_get_time() >= deadline) {
                *err = 1;
                break;
            }
            vTaskDelay(1);
        }
    }
    return sent;
}

size_t esp32_serial_read(struct uxrCustomTransport *transport,
                        uint8_t *buf, size_t len, int timeout, uint8_t *err)
{
    (void)transport;
    *err = 0;
    const int64_t deadline = esp_timer_get_time() + (int64_t)timeout * 1000;
    if (!len) return 0;
    do {
        size_t n = usb_serial_jtag_ll_read_rxfifo(buf, len);
        if (n) return n;
        if (esp_timer_get_time() >= deadline) break;
        vTaskDelay(1);
    } while (true);
    return 0;
}
