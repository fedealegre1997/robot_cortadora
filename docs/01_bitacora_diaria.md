# Bitácora Diaria

Este documento condensa el progreso general del proyecto a alto nivel día a día. Refleja objetivos concretos logrados, decisiones arquitectónicas o de diseño clave y cambios estructurales importantes.
**REGLA ESTRICTA:** NUNCA modificar ni borrar entradas pasadas. Este documento actúa como un diario de desarrollo. Las nuevas entradas deben añadirse siempre al final.

---

## [18 de Mayo de 2026]
- **Hito Principal:** Se logró integrar por completo el control del motor de la bordeadora (HANPOSE 775) con la placa Sabertooth 2x25 v2 desde el ESP32 maestro de motores y ROS 2.
- **Decisiones Arquitectónicas y Hallazgos Físicos:**
  - Se eligió el **Modo Serial Simplificado** del driver Sabertooth (vía el pin UART TX2 del ESP32). Esto aísla por completo el ruido PWM o análogo del motor y utiliza una señal digital pura y robusta que es vital para la seguridad.
  - Se desacopló conceptualmente la máquina de estados del motor de tracción (ruedas) respecto a la herramienta (cuchilla de corte). Ahora la bordeadora posee "memoria de estado" y funciona independientemente de si las ruedas paran o cambian de dirección temporalmente.
  - **Descubrimiento y Solución del Cogging Magnético (Par de Retención):** Durante las pruebas físicas de arranque con rampa suave (Soft-Start), se observó un comportamiento anómalo donde el motor 775 giraba en reversa unos ~200ms antes de avanzar. 
    * *La Física del Fenómeno:* Un motor con escobillas de alta potencia como el HANPOSE 775 posee imanes permanentes muy fuertes y un rotor con ranuras de hierro (armadura dentada). Cuando el ESP32 iniciaba la rampa desde 0 (byte 64) aplicando pasos muy bajos de PWM (ej. byte 66 que equivale a ~3% de potencia), el campo electromagnético inducido en las bobinas era extremadamente débil. Al no poder superar la atracción estática de los imanes permanentes contra los dientes del rotor (fuerza de detención o *cogging torque*), el rotor se alineaba bruscamente con el polo magnético pasivo más cercano, lo que causaba un "tirón" físico o retroceso de acomodo.
    * *La Solución de Ingeniería:* En lugar de arrancar linealmente desde 0%, se diseñó un arranque con **Salto Inicial (Kick-Start)** a un umbral seguro de potencia del 15% (`TRIMMER_SPEED_MIN_START = 74`). Este pulso instantáneo provee el torque electromagnético exacto para romper el par de retención magnético de manera limpia y silenciosa, permitiendo que la rampa continúe su aceleración progresiva de forma 100% directa y hacia adelante.
- **Seguridad Integrada:** Se instauró un mecanismo de apagado de emergencia (byte `64`) en caso de choque o frenado duro desde ROS 2.

## [31 de Mayo de 2026] — Sesión Tarde

- **Hito Principal:** Migración del firmware de motores (`esp32_motor`) a la placa **ESP32-S3** y cambio de driver a **MC33926** (puente H de 4 entradas).
- **Decisiones Arquitectónicas y Mapeo Físico:**
  - El driver original PWM+DIR fue reemplazado físicamente por el módulo MC33926 tras un incidente eléctrico con el convertidor buck.
  - Para controlar el MC33926 se utilizaron 4 canales LEDC independientes (2 canales por motor) para generar señales PWM en ambos sentidos en lugar de usar salidas digitales fijas para la dirección.
  - Se mapearon pines físicos seguros y libres de conflicto en el ESP32-S3: GPIO 4 y 5 para el Motor Izquierdo, GPIO 6 y 7 para el Motor Derecho.
  - La lógica de dirección física se adaptó en software (dentro de `apply_motor_command`) para que el nodo central de ROS 2 siga enviando la misma trama `/motion_cmd` sin necesidad de realizar modificaciones del lado del host.
  - Se reconfiguró el target de compilación a `esp32s3` de manera exitosa en el proyecto activo.

## [31 de Mayo de 2026] — Sesión Noche

- **Hito Principal:** Integración del control de cortadora central (BLDC) al firmware de motores, resolución del acceso al ESP32-S3 por puerto COM, y cierre de documentación técnica.
- **Identificación del Puerto USB en ESP32-S3 N8R2:**
  - El ESP32-S3 N8R2 tiene dos conectores USB-C: **COM** (para programación/serial) y **USB** (OTG nativo). El conector a usar para flash y micro-ROS es siempre el **COM**.
  - El chip CH343 del puerto COM enumera en Linux como `/dev/ttyACM0` (CDC-ACM), no como `/dev/ttyUSBx`. Los scripts existentes se invocan pasando `/dev/ttyACM0` como argumento.
- **Fix de Flash Size (sdkconfig):**
  - El `sdkconfig` del proyecto motor tenía `CONFIG_ESPTOOLPY_FLASHSIZE="2MB"`, mientras que el ESP32-S3 N8R2 tiene 8 MB físicos. Se corrigió a `CONFIG_ESPTOOLPY_FLASHSIZE="8MB"` para que esptool no rechace el dispositivo por incompatibilidad.
- **Extensión del Protocolo `/motion_cmd` a 8 campos — Cortadora Central:**
  - Se agregó el campo `cortadora_on` en el índice 7: `[cmd_id, L_dir, L_pwm, R_dir, R_pwm, T_ms, bordeadora_on, cortadora_on]`.
  - La cortadora central es un BLDC controlado por el driver **AMC CBE12A1C**. El ESP32 la habilita/inhibe via **GPIO 18 → P1-9 (INHIBIT̄)**. HIGH = motor habilitado, LOW = inhibido. El 3.3 V del ESP32 es suficiente (VIH mínimo del driver = 2.2 V, sin level-shifter necesario).
  - El GND del ESP32 debe conectarse al **P1-11 (GND)** del driver para referencia común.
- **Bug Fix — Accesorios independientes del stop:**
  - Se detectó que al enviar un comando con `l_pwm = r_pwm = 0` y `cortadora_on = 1`, el firmware entraba al bloque de stop antes de aplicar el estado de la cortadora. El accesorio quedaba indeterminado.
  - Solución: se movió la aplicación de accesorios (`bordeadora_on`, `cortadora_on`) **antes** de la verificación de stop en `motion_cmd_callback`. Los accesorios se aplican siempre, sin importar si los motores se mueven o no.
- **Sensor ESP32 — Eliminación de printf corrupto:**
  - Se encontró y eliminó un `printf` en `ultrasonic_task` (v6.0) que enviaba datos a UART0, el mismo canal que usa micro-ROS. Esto podía corromper el transporte serial silenciosamente. Firmware actualizado a v6.1. Compilado exitosamente; no se flasheó porque el sensor estaba desconectado.
- **Documentación Técnica Cerrada:**
  - `docs/arquitectura.md` completado con las secciones de ESP32 Sensor y ESP32 Motor: formatos de topics, tablas de pines, ejemplos de comandos copy-paste, y reglas de comportamiento del sistema.
