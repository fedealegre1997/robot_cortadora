// Diagnostico actual: solo los bumpers, usando la misma cache que el firmware.
static void diagnostic_usb_write(const char *text)
{
    size_t sent = 0, length = strlen(text);
    int64_t deadline = esp_timer_get_time() + 200000;
    while (sent < length && esp_timer_get_time() < deadline) {
        size_t n = usb_serial_jtag_ll_write_txfifo((const uint8_t *)text + sent,
                                                 length - sent);
        if (n) {
            sent += n;
            usb_serial_jtag_ll_txfifo_flush();
        } else {
            vTaskDelay(1);
        }
    }
}

static void diagnostic_task(void *arg)
{
    (void)arg;
    usb_serial_jtag_ll_disable_intr_mask(USB_SERIAL_JTAG_LL_INTR_MASK);
    const char *names[] = {"IZQUIERDO", "CENTRAL", "DERECHO"};
    const int pins[] = {PIN_B_L, PIN_B_C, PIN_B_R};
    int previous[] = {-1, -1, -1};
    unsigned presses[3] = {0}, changes[3] = {0};
    int64_t last_status = 0;
    char text[256];
    // Se repite la cabecera para que aparezca aunque se abra tarde el monitor.
    while (1) {
        int state[3];
        xSemaphoreTake(g_data_mutex, portMAX_DELAY);
        state[0] = g_bumper_l > 0.5f;
        state[1] = g_bumper_c > 0.5f;
        state[2] = g_bumper_r > 0.5f;
        xSemaphoreGive(g_data_mutex);
        int64_t now = esp_timer_get_time();
        bool summary = !last_status || now - last_status >= 2000000;
        if (summary) {
            diagnostic_usb_write("\r\nSOLO BUMPERS | pull-up interno | CENTRAL HIGH=presionado | IZQ/DER LOW=presionado\r\n");
            last_status = now;
        }
        for (int i = 0; i < 3; i++) {
            bool changed = previous[i] >= 0 && state[i] != previous[i];
            if (changed) {
                changes[i]++;
                if (state[i]) presses[i]++;
            }
            if (summary || changed || previous[i] < 0) {
                snprintf(text, sizeof(text),
                    "[%7.2fs] %-9s GPIO%d=%d %-10s | pulsaciones=%u cambios=%u%s\r\n",
                    now / 1000000.0, names[i], pins[i], i == 1 ? state[i] : !state[i],
                    state[i] ? "PRESIONADO" : "LIBRE", presses[i], changes[i],
                    changed ? " <-- CAMBIO" : "");
                diagnostic_usb_write(text);
            }
            previous[i] = state[i];
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}
