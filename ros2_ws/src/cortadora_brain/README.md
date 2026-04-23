
---

## 3. `~/robot_cortadora/ros2_ws/src/cortadora_brain/README.md`

```md
# cortadora_brain

Paquete ROS 2 Python del nodo principal de toma de decisiones.

## Función

Este paquete contiene el nodo que recibe datos de sensores y envía comandos al ESP32 motor.

## Archivo activo principal

- `cortadora_brain/bumper_decision_node.py`

## Suscribe
bumpers
motion_status

##Publica
motion_cmd

## Versions

La carpeta `versions/` guarda versiones anteriores del nodo principal.

## Uso

### Ejecutar nodo principal
```bash
source /opt/ros/jazzy/setup.bash
source ~/robot_cortadora/ros2_ws/install/setup.bash
ros2 run cortadora_brain bumper_decision_node
