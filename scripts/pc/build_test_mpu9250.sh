#!/usr/bin/env bash
set -e
TARGET=${1:-esp32s3}
. ~/esp/esp-idf/export.sh
cd ~/robot_cortadora/firmware/esp32_motor/test_mpu9250
idf.py set-target "$TARGET"
idf.py build
