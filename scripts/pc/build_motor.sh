#!/usr/bin/env bash
set -e
. ~/esp/esp-idf/export.sh
cd ~/robot_cortadora/firmware/esp32_motor/active/active
idf.py build
