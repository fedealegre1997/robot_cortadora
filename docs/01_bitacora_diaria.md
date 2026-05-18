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
