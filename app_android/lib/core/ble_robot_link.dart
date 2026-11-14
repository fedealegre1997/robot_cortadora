// Enlace BLE real con el ESP32 sensor (flutter_blue_plus 2.3.15).
// Dueño: Agente 1.
//
// ESTADO: SIN USO REAL. El firmware BLE del ESP todavía no existe (docs §9,
// fases 2–3), así que los UUID de servicio y características son PENDIENTES.
// Mientras falten, connect() falla con un error claro y no toca la radio.
//
// Estructura:
//   - BleRobotLink: estado del enlace, política de herramientas, cola de
//     comandos con prioridad de STOP, fragmentación por MTU, reensamblado y
//     decodificación de lo que llega. Es lo que se testea.
//   - BleTransport: costura (AUD-05). Solo mueve bytes: abrir, cerrar,
//     escribir UN fragmento, bytes recibidos, aviso de enlace caído.
//   - FlutterBluePlusTransport: implementación real sobre flutter_blue_plus
//     (escaneo, conexión, MTU, descubrimiento, notify). Por defecto.
//
// Esquema GATT PROPUESTO (no decidido, ver docs §4/§5): un servicio con dos
// características, estilo "UART":
//   - RX (App → ESP): write / write without response. La app escribe la línea
//     JSON completa terminada en `\n`, partida en fragmentos de (MTU − 3) bytes;
//     el ESP acumula hasta `\n` (y descarta lo acumulado al conectarse).
//   - TX (ESP → App): notify. El ESP manda líneas terminadas en `\n` (POK,
//     PERR, ACK, GPS); la app las reensambla con LineAssembler.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'app_config.dart';
import 'control_command.dart';
import 'esp_protocol.dart';
import 'robot_link.dart';

/// Parámetros BLE. Todo lo marcado PENDIENTE se define con el firmware.
abstract final class BleConfig {
  /// UUID del servicio del ESP. PENDIENTE (firmware BLE no escrito).
  static const String? serviceUuid = null;

  /// Característica App → ESP (write). PENDIENTE.
  static const String? rxCharacteristicUuid = null;

  /// Característica ESP → App (notify). PENDIENTE.
  static const String? txCharacteristicUuid = null;

  /// Nombre anunciado por el ESP, filtro adicional opcional. PENDIENTE.
  static const String? advertisedName = null;

  /// Licencia de flutter_blue_plus 2.x que exige `connect()`.
  /// Decisión del usuario (13/11/26): proyecto de uso educativo/personal sin
  /// fines de lucro → [License.nonprofit] (FlutterBluePlus License 1.6, §2).
  /// Esto NO habilita la conexión: connect() sigue bloqueado mientras los UUID
  /// sean null (PENDIENTES).
  static const License license = License.nonprofit;

  /// MTU que se pide al conectar (solo Android; en iOS lo negocia el SO).
  /// PROPUESTA: 517 (máximo de Android). Lo mínimo para que un comando entre
  /// en una sola escritura es 80 (77 bytes + 3 de cabecera ATT) y para el peor
  /// POLY, 293. Si se negocia menos, se fragmenta igual (más lento).
  static const int requestedMtu = 517;

  static const Duration scanTimeout = Duration(seconds: 10);
  static const Duration connectTimeout = Duration(seconds: 15);

  /// true cuando están definidos los UUID.
  static bool get isConfigured =>
      serviceUuid != null &&
      rxCharacteristicUuid != null &&
      txCharacteristicUuid != null;
}

/// Error de conexión BLE con mensaje para mostrar al usuario.
class BleLinkException implements Exception {
  final String message;
  const BleLinkException(this.message);

  @override
  String toString() => 'BleLinkException: $message';
}

/// Transporte de bytes BLE (costura para tests, AUD-05). No conoce el
/// protocolo: no arma líneas, no aplica políticas.
abstract class BleTransport {
  /// null si se puede intentar abrir; si no, el motivo (se muestra tal cual).
  String? get unavailableReason;

  /// Escanea, conecta, negocia MTU, descubre y activa notificaciones. Lanza
  /// [BleLinkException] (u otra excepción de la radio) si falla.
  Future<void> open();

  /// Desconecta. Idempotente; también cancela un [open] en curso.
  Future<void> close();

  /// MTU ATT vigente (23 si no se negoció).
  int get mtu;

  /// Escribe UN fragmento (≤ mtu − 3 bytes) en la característica RX.
  Future<void> write(List<int> chunk);

  /// Bytes que llegan por notificación de la característica TX.
  Stream<List<int>> get received;

  /// Emite cuando el enlace se cae sin que la app lo pida.
  Stream<void> get linkLost;
}

class BleRobotLink implements RobotLink {
  final AppConfig config;
  final BleTransport _transport;

  /// Enlace real (flutter_blue_plus). No toca la radio hasta [connect].
  BleRobotLink(this.config) : _transport = FlutterBluePlusTransport();

  /// Enlace con un transporte inyectado (tests).
  @visibleForTesting
  BleRobotLink.withTransport(this.config, BleTransport transport)
      : _transport = transport;

  final _statusCtrl = StreamController<LinkStatus>.broadcast();
  final _msgCtrl = StreamController<RobotMessage>.broadcast();
  final _assembler = LineAssembler();

  LinkStatus _status = LinkStatus.disconnected;
  StreamSubscription<List<int>>? _rxSub;
  StreamSubscription<void>? _lostSub;
  Future<void> _writeChain = Future.value();
  bool _disposed = false;

  // Cola de comandos (AUD-06). Como máximo [STOP pendiente, último no-STOP].
  final List<ControlCommand> _pendingCommands = [];
  bool _commandWriting = false;

  @override
  bool get isSimulated => false;

  @override
  LinkStatus get status => _status;

  @override
  Stream<LinkStatus> get statusStream => _statusCtrl.stream;

  @override
  Stream<RobotMessage> get messages => _msgCtrl.stream;

  bool get _isUp => !_disposed && _status == LinkStatus.connected;

  /// Parte una línea en fragmentos de (mtu − 3) bytes (mínimo 20, el payload
  /// del ATT por defecto).
  static List<List<int>> chunkLine(List<int> bytes, int mtu) {
    final size = math.max(20, mtu - 3);
    return [
      for (var i = 0; i < bytes.length; i += size)
        bytes.sublist(i, math.min(i + size, bytes.length)),
    ];
  }

  /// Regla de la cola de comandos pendientes (AUD-06, condiciones del
  /// usuario). [pending] son los comandos aún NO escritos, en orden:
  /// 1. Un STOP nunca se descarta.
  /// 2. Un STOP reemplaza a todo lo pendiente (todo es más viejo que él).
  /// 3. Un no-STOP reemplaza al no-STOP pendiente (gana el más nuevo).
  /// 4. Un no-STOP nunca reemplaza a un STOP pendiente: va DETRÁS de él.
  /// Resultado: como máximo `[STOP, no-STOP]`, siempre en orden de llegada.
  @visibleForTesting
  static void enqueueCommand(List<ControlCommand> pending, ControlCommand cmd) {
    if (cmd.state == RobotState.stop) {
      pending
        ..clear()
        ..add(cmd);
    } else {
      pending
        ..removeWhere((c) => c.state != RobotState.stop)
        ..add(cmd);
    }
  }

  // --- Conexión -------------------------------------------------------------

  @override
  Future<void> connect() async {
    if (_disposed || _status != LinkStatus.disconnected) return;
    final reason = _transport.unavailableReason;
    if (reason != null) throw BleLinkException(reason);

    _setStatus(LinkStatus.connecting);
    _assembler.reset();
    _rxSub = _transport.received.listen(_onBytes);
    _lostSub = _transport.linkLost.listen((_) => _onLinkLost());
    try {
      await _transport.open();
    } catch (_) {
      if (_status == LinkStatus.connecting) {
        await _teardown();
        _setStatus(LinkStatus.disconnected);
      }
      rethrow;
    }
    if (_status != LinkStatus.connecting) {
      // disconnect()/dispose() durante la conexión: no se queda conectado.
      await _transport.close();
      return;
    }
    _setStatus(LinkStatus.connected);
  }

  void _onLinkLost() {
    if (_status == LinkStatus.disconnected) return;
    // Pérdida de enlace: el ESP aplica su timeout de 300 ms por su cuenta.
    _setStatus(LinkStatus.disconnected);
    unawaited(_teardown().then((_) => _transport.close()));
  }

  @override
  Future<void> disconnect() async {
    if (_status == LinkStatus.disconnected) return;
    _setStatus(LinkStatus.disconnected);
    await _teardown();
    try {
      await _transport.close();
    } catch (e) {
      debugPrint('BleRobotLink: error al desconectar: $e');
    }
  }

  Future<void> _teardown() async {
    _pendingCommands.clear();
    _assembler.reset();
    await _rxSub?.cancel();
    _rxSub = null;
    await _lostSub?.cancel();
    _lostSub = null;
  }

  // --- Envío ----------------------------------------------------------------

  /// Comando a 10 Hz. Nunca se descarta en silencio un STOP: si hay una
  /// escritura en curso, el comando queda pendiente según [enqueueCommand] y
  /// sale apenas termina. Los errores de escritura no se propagan (se
  /// registran; la caída real la avisa el transporte) y no frenan lo pendiente.
  /// El Future se completa cuando el comando se escribió, quedó pendiente
  /// detrás de la escritura en curso, o no había conexión.
  @override
  Future<void> sendCommand(ControlCommand command) async {
    if (!_isUp) return;
    var toSend = command.applyToolsPolicy(toolsEnabled: config.toolsEnabled);
    if (_commandWriting) {
      enqueueCommand(_pendingCommands, toSend); // sale al terminar la actual
      return;
    }
    _commandWriting = true;
    try {
      while (true) {
        try {
          await _enqueueWrite(toSend.toJsonLine());
        } catch (e) {
          debugPrint('BleRobotLink: fallo al escribir comando seq=${toSend.seq}: $e');
        }
        if (!_isUp || _pendingCommands.isEmpty) break;
        toSend = _pendingCommands.removeAt(0);
      }
    } finally {
      _commandWriting = false;
    }
  }

  /// Valida la integridad localmente antes de transmitir: un polígono inválido
  /// lanza [ArgumentError] y NO se envía, conectado o no (no se fabrica un
  /// PERR: el PERR solo lo emite el ESP; ver robot_link.dart, AUD-07).
  /// Errores de escritura se propagan.
  @override
  Future<void> sendPolygon(int id, List<(int, int)> points) async {
    final err = EspProtocol.polygonIntegrityError(id, points);
    if (err != null) {
      throw ArgumentError('polígono inválido para el ESP ($err)');
    }
    if (!_isUp) return;
    await _enqueueWrite(EspProtocol.encodePolygon(id, points));
  }

  @override
  Future<void> clearPolygon() async {
    if (!_isUp) return;
    await _enqueueWrite(EspProtocol.encodeClear());
  }

  /// Serializa las escrituras: los fragmentos de una línea nunca se mezclan
  /// con los de otra.
  Future<void> _enqueueWrite(String line) {
    final result = _writeChain.then((_) => _writeLine(line));
    _writeChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _writeLine(String line) async {
    for (final chunk in chunkLine(utf8.encode(line), _transport.mtu)) {
      if (!_isUp) return; // se cortó: el ESP descarta la línea incompleta
      await _transport.write(chunk);
    }
  }

  // --- Recepción ------------------------------------------------------------

  void _onBytes(List<int> bytes) {
    for (final line in _assembler.add(bytes)) {
      final msg = EspProtocol.decodeEspLine(line);
      if (msg != null && !_msgCtrl.isClosed) _msgCtrl.add(msg);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disconnect();
    await _statusCtrl.close();
    await _msgCtrl.close();
  }

  void _setStatus(LinkStatus s) {
    if (_status == s) return;
    _status = s;
    if (!_statusCtrl.isClosed) _statusCtrl.add(s);
  }
}

/// Transporte real sobre flutter_blue_plus. No toca la radio hasta [open].
class FlutterBluePlusTransport implements BleTransport {
  final _received = StreamController<List<int>>.broadcast();
  final _lost = StreamController<void>.broadcast();

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  int _generation = 0;

  @override
  String? get unavailableReason => BleConfig.isConfigured
      ? null
      : 'firmware BLE del ESP pendiente: no hay UUID de servicio/características '
          '(BleConfig). Usar el robot simulado.';

  @override
  int get mtu => _device?.mtuNow ?? 23;

  @override
  Stream<List<int>> get received => _received.stream;

  @override
  Stream<void> get linkLost => _lost.stream;

  void _checkNotCancelled(int gen) {
    if (gen != _generation) {
      throw const BleLinkException('conexión cancelada');
    }
  }

  @override
  Future<void> open() async {
    final svc = BleConfig.serviceUuid;
    final rxId = BleConfig.rxCharacteristicUuid;
    final txId = BleConfig.txCharacteristicUuid;
    if (svc == null || rxId == null || txId == null) {
      throw BleLinkException(unavailableReason!);
    }
    final gen = ++_generation;
    try {
      if (!await FlutterBluePlus.isSupported) {
        throw const BleLinkException('este teléfono no soporta Bluetooth LE');
      }
      final adapter = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 3));
      if (adapter != BluetoothAdapterState.on) {
        throw const BleLinkException('Bluetooth apagado');
      }

      final serviceGuid = Guid(svc);
      final device = await _scanFor(serviceGuid);
      _checkNotCancelled(gen);
      _device = device;

      await device.connect(
        license: BleConfig.license,
        timeout: BleConfig.connectTimeout,
        mtu: null, // se pide abajo, explícito
      );
      _checkNotCancelled(gen);
      if (defaultTargetPlatform == TargetPlatform.android) {
        await device.requestMtu(BleConfig.requestedMtu);
      }

      final services = await device.discoverServices();
      _checkNotCancelled(gen);
      final service = services.where((s) => s.uuid == serviceGuid).firstOrNull;
      if (service == null) {
        throw const BleLinkException('el ESP no expone el servicio esperado');
      }
      final rx = service.characteristics
          .where((c) => c.uuid == Guid(rxId))
          .firstOrNull;
      final tx = service.characteristics
          .where((c) => c.uuid == Guid(txId))
          .firstOrNull;
      if (rx == null ||
          !(rx.properties.write || rx.properties.writeWithoutResponse)) {
        throw const BleLinkException('característica RX ausente o no escribible');
      }
      if (tx == null || !(tx.properties.notify || tx.properties.indicate)) {
        throw const BleLinkException('característica TX ausente o sin notify');
      }

      _notifySub = tx.onValueReceived.listen(_received.add);
      device.cancelWhenDisconnected(_notifySub!);
      await tx.setNotifyValue(true);
      _checkNotCancelled(gen);
      _rx = rx;

      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && _rx != null) {
          _rx = null;
          _lost.add(null);
        }
      });
    } catch (_) {
      if (gen == _generation) await _release(disconnectDevice: true);
      rethrow;
    }
  }

  Future<BluetoothDevice> _scanFor(Guid service) async {
    // No se pasa `androidUsesFineLocation: true` (queda el default false): el
    // AndroidManifest declara BLUETOOTH_SCAN con neverForLocation y
    // ACCESS_FINE_LOCATION solo hasta API 30; en Android 12+ ese permiso no se
    // puede conceder y el escaneo fallaría.
    final found = FlutterBluePlus.onScanResults
        .expand((results) => results)
        .where((r) =>
            BleConfig.advertisedName == null ||
            r.advertisementData.advName == BleConfig.advertisedName)
        .map((r) => r.device)
        .first
        .timeout(BleConfig.scanTimeout);
    try {
      await FlutterBluePlus.startScan(
        withServices: [service],
        timeout: BleConfig.scanTimeout,
      );
      return await found;
    } on TimeoutException {
      throw const BleLinkException('no se encontró el ESP (¿encendido y cerca?)');
    } catch (_) {
      found.ignore();
      rethrow;
    } finally {
      await FlutterBluePlus.stopScan();
    }
  }

  @override
  Future<void> write(List<int> chunk) async {
    final rx = _rx;
    if (rx == null) throw const BleLinkException('no conectado');
    await rx.write(chunk, withoutResponse: !rx.properties.write);
  }

  @override
  Future<void> close() async {
    _generation++; // cancela un open() en curso
    await _release(disconnectDevice: true);
  }

  Future<void> _release({required bool disconnectDevice}) async {
    final device = _device;
    _rx = null;
    _device = null;
    await _connSub?.cancel();
    _connSub = null;
    await _notifySub?.cancel();
    _notifySub = null;
    if (disconnectDevice && device != null) {
      try {
        await device.disconnect(queue: false);
      } catch (e) {
        debugPrint('FlutterBluePlusTransport: error al desconectar: $e');
      }
    }
  }
}
