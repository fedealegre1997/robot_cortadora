
---

## 8. `~/robot_cortadora/firmware/esp32_motor/versions/README.md`

```md
# esp32_motor versions

Reservorio de versiones anteriores del código del ESP32 motor.

## Función

Guardar archivos o respaldos históricos que no deben compilarse directamente.

## Regla

No compilar desde esta carpeta.

Para usar una versión anterior:
1. elegir el archivo deseado
2. copiarlo a `../active/main/main.c`
3. compilar desde `active/`
