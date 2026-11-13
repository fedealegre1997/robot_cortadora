# scripts pc

Scripts específicos de la PC Linux.

## Scripts

- `build_motor.sh [esp32|esp32s3]`: compila firmware del motor. `esp32` = ESP32 clásico del robot; `esp32s3` = banco de prueba (S3 N16R8 con el IMU en el I2C 6/7). Sin argumento usa el target actual; cambiar de target recompila todo
- `build_sensor.sh`: compila firmware del sensor
- `flash_motor.sh`: flashea ESP32 motor
- `flash_sensor.sh`: flashea ESP32 sensor
- `monitor_motor.sh`: abre monitor serial del motor
- `monitor_sensor.sh`: abre monitor serial del sensor
- `build_test_lsm9ds1.sh [esp32s3|esp32]`: compila la prueba aislada del IMU LSM9DS1 (por defecto para ESP32-S3)
- `flash_test_lsm9ds1.sh`: flashea la prueba del LSM9DS1
- `monitor_test_lsm9ds1.sh`: abre el monitor serial de la prueba del LSM9DS1
- `build_test_mpu9250.sh [esp32s3|esp32]`: compila la prueba aislada del IMU de la placa 3 (MPU-9250/6500/9255)
- `flash_test_mpu9250.sh`: flashea la prueba de la placa 3
- `monitor_test_mpu9250.sh`: abre el monitor serial de la prueba de la placa 3
