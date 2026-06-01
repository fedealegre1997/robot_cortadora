#!/usr/bin/env bash
set -e
. ~/esp/esp-idf/export.sh
cd ~/robot_cortadora/firmware/esp32_motor/test_s3_motor
idf.py set-target esp32s3
idf.py build
