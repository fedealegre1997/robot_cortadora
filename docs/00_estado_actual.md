# Estado Actual del Proyecto

**NOTA:** Este es un documento **VIVO**. Siempre debe representar con exactitud milimétrica el estado actual del código, pruebas e integraciones. A diferencia de las bitácoras, este documento **SÍ se edita y sobrescribe** permanentemente. Antes de empezar cualquier tarea o después de terminarla, se debe revisar y actualizar este archivo.

---

## 1. Estado General de los Subsistemas

### 🧠 Cerebro ROS 2 (Host / Raspberry Pi)
- **Estado:** ✅ Integrado y Compilando.
- **Detalle:** El nodo `bumper_decision_node.py` despacha arreglos de 7 enteros (`cmd_id`, `l_dir`, `l_pwm`, `r_dir`, `r_pwm`, `T_ms`, `bordeadora_on`). Maneja detenciones y retrocesos lógicos ante presiones físicas simuladas.

### 🔌 Firmware Sensores (ESP32)
- **Estado:** ✅ Estable y testeado.
- **Detalle:** La base de micro-ROS lee exitosamente información del ambiente.

### 🚜 Firmware Motores (ESP32)
- **Estado:** ⏳ Pendiente validación física.
- **Detalle:** 
  - La comunicación con el Sabertooth 2x25 v2 está programada vía UART (TX GPIO 17) en Modo Serial Simplificado.
  - La lógica de desacople (ruedas vs bordeadora) está escrita.
  - La "Rampa Suave" o Soft-Start ha sido programada con un salto térmico/magnético de arranque mínimo (de byte 64 a byte 74) para superar el cogging del motor 775 de 288W, llegando a un máximo súper conservador para pruebas de 85 (33% de potencia).
  - El código fue recompilado sin errores y está listo en la PC Linux.

---

## 2. Bloqueos Actuales o Advertencias
- Ninguno por software. Únicamente precaución eléctrica para la prueba manual del hardware. Se aconsejó realizar pruebas sin el motor conectado (ver LEDs) o a baja potencia (33%).

---

## 3. Próximas Tareas y Pasos Naturales
1. **Flasheo y Pruebas del Motor (Hardware):** Cargar el archivo `.bin` actual en el ESP32 de motores. Probar los comandos de ROS 2 directos desde la terminal en la máquina Linux para certificar el encendido y el apagado silencioso/limpio del Sabertooth.
2. **Incrementar Potencia de Trabajo:** Una vez validado el arranque suave al 33%, subir el valor de la variable de compilación `TRIMMER_SPEED_MAX` a ~115 (90% potencia) para pruebas de corte real con carga aerodinámica/pasto.
3. **Manejo Dinámico desde Nodo ROS 2:** Probar la integración combinada de todos los sistemas desde un launch o ejecución secuencial completa con lógica autónoma de navegación.
