#!/usr/bin/env bash
# Uso: build_motor.sh [esp32|esp32s3]
#   sin argumento: compila con el target actual del sdkconfig
#   esp32   = ESP32 clasico del robot (docs/pines.md §2)
#   esp32s3 = banco de prueba ESP32-S3 N16R8 con el IMU en el I2C 6/7
set -e
TARGET=${1:-}
. ~/esp/esp-idf/export.sh
cd ~/robot_cortadora/firmware/esp32_motor/active/active
if [ -n "$TARGET" ] && ! grep -q "^CONFIG_IDF_TARGET=\"$TARGET\"" sdkconfig 2>/dev/null; then
  idf.py set-target "$TARGET"
fi
idf.py build
