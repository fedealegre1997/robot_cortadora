#!/usr/bin/env bash
set -euo pipefail
source "$HOME/esp/esp-idf/export.sh"
cd "$HOME/robot_cortadora/firmware/esp32_motor/active/active"
idf.py -B build_pulse_test -D MOTOR_PULSE_TEST=ON -D MOTOR_DIAGNOSTICS=OFF -D IDF_TARGET=esp32 -D SDKCONFIG=sdkconfig.pulse_test build
