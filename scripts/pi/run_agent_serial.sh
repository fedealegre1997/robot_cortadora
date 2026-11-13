#!/usr/bin/env bash
# Uso: run_agent_serial.sh /dev/ttyUSBx [-v4]
# Sensor: /dev/ttyUSB0   Motor: /dev/ttyUSB1
# No usar monitor serial y agente en el mismo puerto a la vez.
source ~/robot_cortadora/scripts/pi/env.sh
$MICROROS_AGENT serial --dev "$@"
