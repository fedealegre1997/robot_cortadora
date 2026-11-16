#!/usr/bin/env bash
# Levanta los dos agentes micro-ROS y el Brain en un solo comando.
# Ctrl+C mata los tres procesos limpiamente.
set -e

source /opt/ros/lyrical/setup.bash
source ~/microros_agent_ws/install/local_setup.bash
source ~/robot_cortadora/ros2_ws/install/local_setup.bash

AGENT=~/microros_agent_ws/install/micro_ros_agent/lib/micro_ros_agent/micro_ros_agent
DEV_SENSOR="/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_7C:E8:B1:A2:8E:24-if00"
DEV_MOTOR="/dev/serial/by-id/usb-Silicon_Labs_CP2102_USB_to_UART_Bridge_Controller_0001-if00-port0"

cleanup() {
    echo ""
    echo "Deteniendo robot..."
    timeout 3 ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray \
        "{data: [9999, 0, 0, 0, 0]}" >/dev/null 2>&1 || true
    kill $PID_SENSOR $PID_MOTOR $PID_BRAIN 2>/dev/null || true
    wait $PID_SENSOR $PID_MOTOR $PID_BRAIN 2>/dev/null || true
    echo "Todo detenido."
}
trap cleanup EXIT INT TERM

# Matar agentes y nodos previos
EXISTING=$(ps -eo pid,cmd | grep '[m]icro_ros_agent' | awk '{print $1}')
if [ -n "$EXISTING" ]; then
    echo "Matando agentes previos: $EXISTING"
    kill -TERM $EXISTING 2>/dev/null || true
    sleep 1
fi
EXISTING_BRAIN=$(ps -eo pid,cmd | grep '[b]rain_node' | awk '{print $1}')
if [ -n "$EXISTING_BRAIN" ]; then
    echo "Matando brain previo: $EXISTING_BRAIN"
    kill -TERM $EXISTING_BRAIN 2>/dev/null || true
    sleep 1
fi

# Verificar dispositivos
for DEV in "$DEV_SENSOR" "$DEV_MOTOR"; do
    if [ ! -e "$DEV" ]; then
        echo "No se encuentra: $DEV"
        exit 1
    fi
done

echo "=== Iniciando agente SENSOR ==="
$AGENT serial --dev "$DEV_SENSOR" -v4 &
PID_SENSOR=$!

echo "=== Iniciando agente MOTOR ==="
$AGENT serial --dev "$DEV_MOTOR" -v4 &
PID_MOTOR=$!

# Reset del ESP32 motor vía DTR (CP2102 hace reset con toggle DTR)
sleep 1
echo "=== Reseteando ESP32 motor vía DTR ==="
python3 -c "
import serial, time
try:
    s = serial.Serial('$DEV_MOTOR', 115200)
    s.dtr = False; time.sleep(0.1)
    s.dtr = True;  time.sleep(0.1)
    s.close()
    print('  Reset DTR enviado')
except Exception as e:
    print(f'  No se pudo resetear: {e}')
" 2>/dev/null || echo "  pyserial no disponible, resetear manualmente"

# Esperar a que ambos topics existan (max 60 s)
echo "=== Esperando que ambos ESP32 conecten... ==="
WAITED=0
SENSOR_OK=0
MOTOR_OK=0
while [ $WAITED -lt 60 ]; do
    TOPICS=$(ros2 topic list 2>/dev/null || true)
    if echo "$TOPICS" | grep -q "/sensores"; then
        if [ $SENSOR_OK -eq 0 ]; then
            echo "  ✓ Sensor conectado"
            SENSOR_OK=1
        fi
    fi
    if echo "$TOPICS" | grep -q "/motion_status"; then
        if [ $MOTOR_OK -eq 0 ]; then
            echo "  ✓ Motor conectado"
            MOTOR_OK=1
        fi
    fi
    if [ $SENSOR_OK -eq 1 ] && [ $MOTOR_OK -eq 1 ]; then
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    if [ $((WAITED % 10)) -eq 0 ]; then
        PENDING=""
        [ $SENSOR_OK -eq 0 ] && PENDING="sensor "
        [ $MOTOR_OK -eq 0 ] && PENDING="${PENDING}motor"
        echo "  Esperando: ${PENDING}... (${WAITED}s)"
        echo "  Si no conecta, pulsá EN/RST en el ESP32 que falta."
    fi
done

if [ $SENSOR_OK -eq 0 ] || [ $MOTOR_OK -eq 0 ]; then
    echo "ERROR: timeout de 60 s esperando los ESP32."
    [ $SENSOR_OK -eq 0 ] && echo "  ✗ Sensor NO conectó"
    [ $MOTOR_OK -eq 0 ] && echo "  ✗ Motor NO conectó"
    exit 1
fi

echo "=== Ambos ESP32 listos, iniciando BRAIN ==="
ros2 run cortadora_brain brain_node &
PID_BRAIN=$!

echo ""
echo "Todo corriendo:"
echo "  Agente sensor  PID=$PID_SENSOR"
echo "  Agente motor   PID=$PID_MOTOR"
echo "  Brain          PID=$PID_BRAIN"
echo ""
echo "Ctrl+C para detener todo (envía STOP al robot primero)."
echo ""

wait
