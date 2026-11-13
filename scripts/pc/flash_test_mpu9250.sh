#!/usr/bin/env bash
set -e
PORT=${1:-/dev/ttyUSB0}
. ~/esp/esp-idf/export.sh
cd ~/robot_cortadora/firmware/esp32_motor/test_mpu9250
idf.py -p "$PORT" flash
