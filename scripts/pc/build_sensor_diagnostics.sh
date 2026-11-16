#!/usr/bin/env bash
set -euo pipefail
source "$HOME/esp/esp-idf/export.sh"
cd "$HOME/robot_cortadora/firmware/esp32_sensor/active/active"
idf.py -B build_diagnostics -D SENSOR_DIAGNOSTICS=ON \
    -D IDF_TARGET=esp32s3 -D SDKCONFIG=sdkconfig.diagnostics build
