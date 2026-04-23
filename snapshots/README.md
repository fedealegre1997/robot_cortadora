# snapshots

Respaldos globales del proyecto.

## Función

Guardar fotos completas del sistema en momentos importantes.

## Regla

No trabajar directamente desde esta carpeta.

Usar solo como referencia o recuperación.


si rompés el brain y querés volver al estado estable:
rsync -a ~/robot_cortadora/snapshots/2026_04_pc_linux_integracion_estable/ros2_ws_src/cortadora_brain/ \
~/robot_cortadora/ros2_ws/src/cortadora_brain/


Si rompés el firmware del motor:
rsync -a ~/robot_cortadora/snapshots/2026_04_pc_linux_integracion_estable/firmware/esp32_motor_active/ \
~/robot_cortadora/firmware/esp32_motor/active/


Si rompés el firmware del sensor:
rsync -a ~/robot_cortadora/snapshots/2026_04_pc_linux_integracion_estable/firmware/esp32_sensor_active/ \
~/robot_cortadora/firmware/esp32_sensor/active/
