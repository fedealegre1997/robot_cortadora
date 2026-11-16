cmake_minimum_required(VERSION 3.5)

option(SENSOR_DIAGNOSTICS "Lecturas USB sin micro-ROS" OFF)
if(NOT SENSOR_DIAGNOSTICS)
    set(EXTRA_COMPONENT_DIRS "/home/angel-alegre/esp/micro_ros_espidf_component")
endif()

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(int32_publisher)
