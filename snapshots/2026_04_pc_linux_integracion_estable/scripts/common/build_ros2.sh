#!/usr/bin/env bash
set -e
source ~/robot_cortadora/scripts/common/env.sh
cd ~/robot_cortadora/ros2_ws
colcon build
