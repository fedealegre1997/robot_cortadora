# esp32_sensor active

Proyecto ESP-IDF activo del ESP32 sensor.

## Función

Desde esta carpeta se compila, flashea y monitorea el firmware actual del sensor.

## Archivo principal

- `main/main.c`

## Uso

### Compilar
```bash
. ~/esp/esp-idf/export.sh
cd ~/robot_cortadora/firmware/esp32_sensor/active
idf.py build

### Flashear
idf.py -p /dev/ttyUSB1 flash

### MOnitor
idf.py -p /dev/ttyUSB1 monitor
