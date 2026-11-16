#!/usr/bin/env bash
set -euo pipefail
PORT=${1:?Uso: flash_motor_diagnostics.sh /dev/ttyUSBx}
source "$HOME/esp/esp-idf/export.sh"
cd "$HOME/robot_cortadora/firmware/esp32_motor/active/active"
idf.py -B build_diagnostics -D MOTOR_DIAGNOSTICS=ON -D IDF_TARGET=esp32 -D SDKCONFIG=sdkconfig.diagnostics -p "$PORT" flash
