# esp32_sensor active

Proyecto **ESP-IDF** activo del **ESP32 sensor**.

## Función

Desde esta carpeta se compila, flashea, monitorea y mantiene la versión actual del firmware encargado de la adquisición y publicación de sensores del robot.

Actualmente este firmware integra:

- finales de carrera
- MPU-6500
- ultrasonidos
- GPS FSTR2
- publicación mediante **micro-ROS**

## Archivo principal

- `main/main.c`

---

## Arquitectura actual

El firmware está dividido en tareas FreeRTOS para separar responsabilidades y facilitar mantenimiento, depuración y futuras ampliaciones.

### Tareas implementadas

- `bumper_task`
  - lectura de finales de carrera

- `imu_task`
  - lectura y procesamiento del MPU-6500

- `ultrasonic_task`
  - lectura secuencial de los 3 ultrasonidos

- `gps_task`
  - lectura y parseo de tramas NMEA del GPS FSTR2

- `micro_ros_task`
  - publicación de todos los datos en un topic array

### Distribución por core

#### Core 0
Tareas lentas o más bloqueantes:

- `ultrasonic_task`
- `gps_task`

#### Core 1
Tareas rápidas:

- `bumper_task`
- `imu_task`
- `micro_ros_task`

---

## Topic publicado

El firmware publica un `Float32MultiArray` en el topic:

- `sensores`

## Convenciones del topic `sensores`

### Orden del vector

    [bumper_izq, bumper_centro, bumper_der,
     ultra_izq, ultra_centro, ultra_der,
     roll, pitch, yaw,
     gps_lat, gps_lon, gps_alt, gps_fix]

### Índices del vector

- `data[0]`  = bumper izquierdo
- `data[1]`  = bumper centro
- `data[2]`  = bumper derecho

- `data[3]`  = ultrasonido izquierdo
- `data[4]`  = ultrasonido centro
- `data[5]`  = ultrasonido derecho

- `data[6]`  = roll
- `data[7]`  = pitch
- `data[8]`  = yaw

- `data[9]`  = latitud GPS
- `data[10]` = longitud GPS
- `data[11]` = altitud GPS
- `data[12]` = calidad de fix GPS

---

## Convenciones de interpretación para el nodo principal

### 1. Finales de carrera

Los bumpers se publican como `float` por uniformidad dentro del arreglo.

#### Valores posibles
- `1.0` = activado
- `0.0` = no activado

#### Interpretación recomendada
- `1.0` implica contacto detectado
- `0.0` implica estado libre

---

### 2. Ultrasonidos

Los ultrasonidos se leen de forma secuencial para reducir interferencias entre ecos.

Las lecturas válidas se publican en **centímetros**.

#### Valores válidos
- cualquier valor `> 0` = distancia válida en cm

#### Valores especiales de ultrasonidos
- `-1` = timeout esperando flanco de subida del ECHO, o dato no disponible / vencido
- `-2` = timeout esperando flanco de bajada del ECHO
- `-3` = medición fuera de rango válido
- `-4` = el pin ECHO ya estaba en alto antes del disparo

#### Rango esperado
- rango útil aproximado: `2 cm` a `400 cm`

#### Interpretación recomendada para el nodo principal
- si `ultra_x > 0` → usar la distancia medida
- si `ultra_x < 0` → tratar la lectura como inválida o no confiable

#### Observación importante
El valor `-1` **no significa necesariamente camino libre**.

Puede indicar:
1. que no apareció el eco
2. que el dato quedó viejo y fue invalidado antes de publicarse

Por lo tanto, el nodo principal debe interpretar `-1` como **lectura inválida o no disponible**.

---

### 3. IMU

Los valores publicados son:

- `roll`
- `pitch`
- `yaw`

Estos valores representan la orientación estimada a partir del MPU-6500.

#### Interpretación recomendada
Usar estos datos como referencia de inclinación y orientación del robot, no como posición absoluta.

---

### 4. GPS

El GPS FSTR2 se basa en lectura de tramas NMEA y parseo de mensajes GGA.

#### Campos publicados
- `gps_lat`  = latitud
- `gps_lon`  = longitud
- `gps_alt`  = altitud
- `gps_fix`  = calidad de fix

#### Valores especiales y casos posibles del GPS

##### Caso A: GPS no conectado o sin datos recientes
- `gps_lat = NaN`
- `gps_lon = NaN`
- `gps_alt = NaN`
- `gps_fix = -1`

##### Caso B: GPS conectado pero sin fix
- `gps_lat = NaN`
- `gps_lon = NaN`
- `gps_alt = NaN`
- `gps_fix = 0`

##### Caso C: GPS con fix válido
- `gps_lat = valor real`
- `gps_lon = valor real`
- `gps_alt = valor real`
- `gps_fix >= 1`

#### Interpretación recomendada para el nodo principal
- si `gps_fix >= 1` → posición GPS válida
- si `gps_fix = 0` → GPS encendido pero sin fix
- si `gps_fix = -1` → GPS sin datos o no disponible
- si `gps_lat`, `gps_lon` o `gps_alt` son `NaN` → dato no válido

#### Regla práctica recomendada
- no usar posición GPS mientras `gps_fix < 1`
- usar posición GPS solo cuando `gps_fix >= 1`
- si hay `NaN` en latitud, longitud o altitud, considerar el dato inválido

---

## Resumen de interpretación rápida

### Bumpers
- `1.0` = activado
- `0.0` = libre

### Ultrasonidos
- `> 0` = distancia válida en cm
- `-1` = timeout de subida o dato vencido
- `-2` = timeout de bajada
- `-3` = fuera de rango
- `-4` = ECHO ya estaba alto
- cualquier valor `< 0` = error o dato inválido

### IMU
- `roll`, `pitch`, `yaw` = orientación estimada

### GPS
- `gps_fix >= 1` = posición válida
- `gps_fix = 0` = GPS sin fix
- `gps_fix = -1` = GPS sin datos o no disponible
- `gps_lat`, `gps_lon`, `gps_alt = NaN` = dato no válido

---

## Mapa de pines actual

### Finales de carrera
- `GPIO18` = bumper izquierdo
- `GPIO22` = bumper centro
- `GPIO19` = bumper derecho

### Ultrasonidos
- Izquierdo:
  - `TRIG = GPIO25`
  - `ECHO = GPIO32`

- Centro:
  - `TRIG = GPIO26`
  - `ECHO = GPIO27`

- Derecho:
  - `TRIG = GPIO33`
  - `ECHO = GPIO35`

### MPU-6500
- `GPIO21` = SDA
- `GPIO23` = SCL
- Dirección I2C: `0x69`

### GPS FSTR2
- `UART2`
- `GPIO17` = TX del ESP32 hacia RX del GPS
- `GPIO16` = RX del ESP32 desde TX del GPS
- Baud rate: `9600`

### micro-ROS / USB
- `UART0` reservada para comunicación serial principal y micro-ROS

---

## Uso

### Compilar

```bash
. ~/esp/esp-idf/export.sh
cd ~/robot_cortadora/firmware/esp32_sensor/active
idf.py build