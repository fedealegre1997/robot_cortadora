cmake_minimum_required(VERSION 3.5)

option(MOTOR_DIAGNOSTICS "Diagnostico IMU sin micro-ROS y traccion en LOW" OFF)
option(MOTOR_PULSE_TEST "Pulso manual breve de traccion izquierda" OFF)
if(NOT MOTOR_DIAGNOSTICS AND NOT MOTOR_PULSE_TEST)
    set(EXTRA_COMPONENT_DIRS "/home/angel-alegre/esp/micro_ros_espidf_component")
endif()

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(int32_publisher)
