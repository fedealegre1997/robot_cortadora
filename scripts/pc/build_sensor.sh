#!/usr/bin/env bash
set -e
TARGET=${1:-}
. ~/esp/esp-idf/export.sh
cd ~/robot_cortadora/firmware/esp32_sensor/active/active
if [ -n "$TARGET" ] && ! grep -q "^CONFIG_IDF_TARGET=\"$TARGET\"" sdkconfig 2>/dev/null; then
    idf.py set-target "$TARGET"
fi
idf.py build
