#!/usr/bin/env bash
set -e

PORT=${1:-/dev/ttyUSB0}
VERBOSE=${2:--v4}
AGENT_SETUP="$HOME/robot_cortadora/tools/microros_agent_ws/install/local_setup.bash"

source /opt/ros/jazzy/setup.bash

if [ ! -f "$AGENT_SETUP" ]; then
  echo "No existe el entorno del micro-ROS Agent:"
  echo "  $AGENT_SETUP"
  echo "Primero hay que compilar el workspace del agent."
  exit 1
fi

source "$AGENT_SETUP"

echo "Iniciando micro-ROS Agent en $PORT con $VERBOSE"
ros2 run micro_ros_agent micro_ros_agent serial --dev "$PORT" "$VERBOSE"
