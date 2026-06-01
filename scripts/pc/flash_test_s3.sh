#!/usr/bin/env bash
set -e
PORT=${1:-/dev/ttyUSB0}
. ~/esp/esp-idf/export.sh
cd ~/robot_cortadora/firmware/esp32_motor/test_s3_motor
idf.py -p "$PORT" flash
