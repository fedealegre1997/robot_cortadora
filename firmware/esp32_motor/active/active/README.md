# esp32_motor active

Proyecto ESP-IDF activo del ESP32 motor.

## Función

Desde esta carpeta se compila, flashea y monitorea el firmware actual del motor.

## Archivo principal

- `main/main.c`

## Uso

### Compilar
```bash
. ~/esp/esp-idf/export.sh
cd ~/robot_cortadora/firmware/esp32_motor/active
idf.py build
### flashear
idf.py -p /dev/ttyUSB0 flash
### monitor
idf.py -p /dev/ttyUSB0 monitor

