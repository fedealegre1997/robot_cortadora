#!/usr/bin/env bash
set -e
PORT=${1:-/dev/ttyUSB1}
. ~/esp/esp-idf/export.sh
cd ~/robot_cortadora/firmware/esp32_sensor/active/active
idf.py -p "$PORT" flash
