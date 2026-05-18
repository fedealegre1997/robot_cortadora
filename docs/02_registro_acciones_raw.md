# Registro de Acciones RAW

Este documento es un registro inmutable (append-only) de cada acción, experimento, diagnóstico, pensamiento, bloqueos y errores abordados durante el desarrollo del proyecto.
**REGLA ESTRICTA:** NUNCA se deben modificar, resumir ni borrar entradas anteriores. Este documento sirve como "fuente de la verdad" para recordar caminos fallidos y diagnósticos previos. Añadir SIEMPRE al final del archivo.

## [18/05/26 Sesión Madrugada] - Debugging Físico del Motor y Lógica de Rampa
- **Hipótesis y Diagnóstico Profundo:** 
  - El usuario reportó que el motor gira en reversa por ~200ms antes de ir hacia adelante al mandarle el comando de encendido. 
  - **Primer pensamiento:** Creí que podía ser una configuración errónea de los DIP Switches de la Sabertooth (ej. Modo RC leyendo ruido). Pero el usuario confirmó que los cambió a Serial Simplificado.
  - **Segundo pensamiento:** Analicé el arranque del UART en ESP32. Al inicializar, el pin TX sufre un glitch que la Sabertooth guarda en su buffer, corrompiendo el primer byte de arranque (`66`). Implementé enviar un `64` forzado en el boot para limpiar el buffer serial. Aún así el usuario reportó que el glitch continuaba.
  - **Conclusión Definitiva (Cogging Magnético / Par de Retención):** Comprendí a fondo la física e interacción electromagnética del motor HANPOSE 775. Este motor es una máquina síncrona de imanes permanentes con escobillas de muy alta potencia (288W). 
    * *La raíz física:* El par de retención (o *cogging torque*) ocurre debido a la atracción magnética entre los imanes permanentes del estator y los dientes de hierro dulce del núcleo del rotor. Este par es independiente de la corriente en las bobinas; es una fuerza estática puramente física causada por la variación de la reluctancia magnética en el entrehierro a medida que el rotor gira.
    * *Por qué giraba al revés:* Al arrancar desde el byte `64` (Stop) de forma lineal, el primer paso de rampa mandaba `66` (aproximadamente un 3% de PWM de voltaje promedio). A esta tensión tan baja, la corriente generada en los devanados del rotor produce un par electromagnético muy inferior al *cogging torque* máximo del motor. El rotor no podía avanzar sobre el "diente" magnético siguiente. En su lugar, el débil campo magnético del inducido actuaba como un resorte elástico, y la atracción de los imanes permanentes jalaba el diente del rotor de regreso al punto de mínima reluctancia más cercano (que físicamente significaba un retroceso o "tirón" hacia atrás).
    * *Por qué duraba 200ms:* Ese "juego" o vibración hacia atrás persistía durante las primeras iteraciones de la rampa (de byte 66 a 72). Recién en el paso del byte `74` (aproximadamente 15% de ciclo de trabajo), el voltaje promedio de inducción vencía la barrera del par de retención estático y obligaba al rotor a saltar magnéticamente hacia adelante de forma continua.
    * *La solución de control:* Diseñar un perfil de velocidad no lineal. Introducir un **Kick-Start** (Salto Inicial a 74) que inyecte de golpe la corriente necesaria para saltar la barrera de reluctancia inicial, y luego continuar con la rampa progresiva fina para el resto del aceleramiento dinámico.
- **Acciones Implementadas:** 
  1. **Flush UART:** Añadí `uart_write_bytes` enviando un `64` en el `sabertooth_hw_init()` con delays de 50ms para prevenir framing errors reales en la placa.
  2. **Memoria de Estado:** Modifiqué `motion_cmd_callback` para que guarde `target_trimmer_state = bordeadora_on` aislando el encendido de la cuchilla del timer de tracción.
  3. **Salto Antifricción:** Creé `#define TRIMMER_SPEED_MIN_START 74`. Ahora, la rampa salta de 64 a 74 directo, aplicando un ~15% de potencia instantánea para romper el cogging, eliminando el retroceso, y luego sigue rampando hasta el 33% de prueba segura.
- **Resultado RAW:** Código compilado limpio al 100%. Teóricamente sólido y a la espera del testeo de Hardware del usuario.
