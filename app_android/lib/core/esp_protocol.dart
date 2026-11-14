// Codec del protocolo App <-> ESP32 sensor (líneas JSON terminadas en `\n`).
// Dueño: Agente 1. Lo usan SimulatedRobotLink y BleRobotLink.
//
// Fijado por la Directiva §3 / docs §5 (NO cambiar):
//   App→ESP  {"t":"POLY","id":N,"p":[[lat,lon],...]}   3–10 vértices, int32 en 1e-7°
//   ESP→App  {"t":"POK","id":N}
//   App→ESP  {"t":"PCLR"}
//
// PROPUESTA del Agente 1 (NO congelada con el firmware, ver docs §4 y §5):
//   App→ESP  {"t":"CMD","state":S,"dir":D,"speed":V,"cutter":C,"trimmer":T,"seq":Q}
//   ESP→App  {"t":"PERR","id":N,"e":"<código>"}   (`id` se omite si no se pudo leer;
//            con e:"ID" es el eco del id inválido recibido)
//   ESP→App  {"t":"ACK","seq":Q}                   ACK de RECEPCIÓN, no de ejecución
//   ESP→App  {"t":"GPS","fix":F,"lat":LAT,"lon":LON,"sats":N,"hdop":H}
//            lat/lon int32 en 1e-7° (igual que POLY); se omiten sin fix.
//            sats/hdop = -1 "sin dato" (igual que /sensores índices 13–14).

import 'dart:convert';

import 'robot_link.dart';

/// Códigos de rechazo de polígono (`PERR.e`). PROPUESTA, no congelada.
abstract final class PerrCode {
  /// JSON mal formado, `t` incorrecto, campo faltante o de tipo incorrecto.
  static const String format = 'FMT';

  /// Cantidad de vértices fuera de 3–10.
  static const String vertexCount = 'NVERT';

  /// Alguna coordenada fuera de int32.
  static const String range = 'RANGE';

  /// `id` fuera de rango (ver [EspProtocol.polygonIdMin]/[EspProtocol.polygonIdMax]).
  static const String id = 'ID';

  /// La línea supera el buffer de recepción del ESP.
  static const String length = 'LEN';

  static const List<String> all = [format, vertexCount, range, id, length];
}

/// Resultado de la validación de integridad de un POLY del lado ESP.
class PolygonParseResult {
  /// Id leído (puede existir aunque el polígono sea inválido); null si no se
  /// pudo leer.
  final int? id;
  final List<(int, int)>? points;

  /// null = válido; si no, un [PerrCode].
  final String? error;

  const PolygonParseResult._(this.id, this.points, this.error);

  bool get isValid => error == null;
}

/// Funciones puras del protocolo. Sin estado, sin E/S.
abstract final class EspProtocol {
  static const int minVertices = 3;
  static const int maxVertices = 10;
  static const int int32Min = -2147483648;
  static const int int32Max = 2147483647;

  /// Rango de `id` de polígono. PROPUESTA: 0 está reservado ("ninguna", índice
  /// 23 de /sensores) y 65535 se representa exacto en el Float32 de /sensores.
  static const int polygonIdMin = 1;
  static const int polygonIdMax = 65535;

  /// Largo máximo aceptado de una línea entrante (bytes, sin `\n`). PROPUESTA
  /// para dimensionar el buffer del ESP: el peor POLY válido mide 290 bytes con `\n`.
  static const int maxLineLength = 512;

  // ---------------------------------------------------------------------------
  // App → ESP
  // ---------------------------------------------------------------------------

  /// `{"t":"POLY","id":N,"p":[[lat,lon],...]}\n`. No valida: ver
  /// [polygonIntegrityError].
  static String encodePolygon(int id, List<(int, int)> points) {
    final p = [
      for (final (lat, lon) in points) [lat, lon],
    ];
    return '${jsonEncode({'t': 'POLY', 'id': id, 'p': p})}\n';
  }

  /// `{"t":"PCLR"}\n`.
  static String encodeClear() => '{"t":"PCLR"}\n';

  /// Validación de integridad (la misma que hace el ESP): id, cantidad de
  /// vértices y valores int32. NO valida geometría (eso es de la Raspberry).
  /// Devuelve null si es válido o el [PerrCode] correspondiente.
  static String? polygonIntegrityError(int id, List<(int, int)> points) {
    if (id < polygonIdMin || id > polygonIdMax) return PerrCode.id;
    if (points.length < minVertices || points.length > maxVertices) {
      return PerrCode.vertexCount;
    }
    for (final (lat, lon) in points) {
      if (!_isInt32(lat) || !_isInt32(lon)) return PerrCode.range;
    }
    return null;
  }

  /// Referencia del lado ESP: parsea una línea POLY y valida su integridad.
  /// Lo usa el ESP simulado; sirve de especificación para el firmware.
  static PolygonParseResult parsePolygonLine(String line) {
    final body = _stripNewline(line);
    if (utf8.encode(body).length > maxLineLength) {
      return const PolygonParseResult._(null, null, PerrCode.length);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const PolygonParseResult._(null, null, PerrCode.format);
    }
    if (decoded is! Map<String, dynamic> || decoded['t'] != 'POLY') {
      return const PolygonParseResult._(null, null, PerrCode.format);
    }
    final rawId = decoded['id'];
    if (rawId is! int) {
      return const PolygonParseResult._(null, null, PerrCode.format);
    }
    // El id se valida primero: así un PERR distinto de "ID" siempre lleva un
    // id válido (1–65535), y uno "ID" lleva el eco solo si cabe en int32.
    if (!_isPolygonId(rawId)) {
      return PolygonParseResult._(_isInt32(rawId) ? rawId : null, null, PerrCode.id);
    }
    final rawP = decoded['p'];
    if (rawP is! List) return PolygonParseResult._(rawId, null, PerrCode.format);
    final points = <(int, int)>[];
    for (final v in rawP) {
      if (v is! List || v.length != 2 || v[0] is! int || v[1] is! int) {
        return PolygonParseResult._(rawId, null, PerrCode.format);
      }
      points.add((v[0] as int, v[1] as int));
    }
    final err = polygonIntegrityError(rawId, points);
    return PolygonParseResult._(rawId, err == null ? points : null, err);
  }

  // ---------------------------------------------------------------------------
  // ESP → App
  // ---------------------------------------------------------------------------

  static String encodePok(int id) => '${jsonEncode({'t': 'POK', 'id': id})}\n';

  static String encodePerr({int? id, required String code}) =>
      '${jsonEncode({'t': 'PERR', 'id': ?id, 'e': code})}\n';

  static String encodeAck(int seq) => '${jsonEncode({'t': 'ACK', 'seq': seq})}\n';

  /// GPS en el formato propuesto. [latE7]/[lonE7] en 1e-7°; se omiten si son
  /// null (sin fix). [sats]/[hdop] null se codifican como -1 ("sin dato").
  static String encodeGps({
    required int fix,
    int? latE7,
    int? lonE7,
    int? sats,
    double? hdop,
  }) =>
      '${jsonEncode({
        't': 'GPS',
        'fix': fix,
        'lat': ?latE7,
        'lon': ?lonE7,
        'sats': sats ?? -1,
        'hdop': (hdop as num?) ?? -1, // -1 entero, no -1.0
      })}\n';

  /// Límites de lat/lon en 1e-7° (±90° / ±180°).
  static const int latE7Max = 900000000;
  static const int lonE7Max = 1800000000;

  /// Decodifica una línea ESP→App. Nunca lanza: devuelve null si la línea es
  /// inválida, si algún valor está fuera de rango (id de POK/PERR fuera de
  /// [polygonIdMin]–[polygonIdMax], seq fuera de 0–65535, `fix` negativo,
  /// lat/lon fuera de ±90°/±180°, sats/hdop negativos distintos de -1) o si es
  /// de un tipo desconocido (se ignora, compatibilidad hacia adelante). Los GPS
  /// decodificados llevan `simulated: false`; el simulador emite los suyos
  /// directamente con `simulated: true`.
  static RobotMessage? decodeEspLine(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(_stripNewline(line));
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    switch (decoded['t']) {
      case 'POK':
        final id = decoded['id'];
        return (id is int && _isPolygonId(id)) ? PolygonAccepted(id) : null;
      case 'PERR':
        // `id` puede faltar (el ESP no lo pudo leer). Si viene, debe estar en
        // 1–65535, SALVO con `e:"ID"`: ahí el `id` es el eco del id inválido
        // que recibió el ESP (int32), para que la app sepa qué pedido se
        // rechazó.
        final id = decoded['id'];
        final e = decoded['e'];
        if (e != null && e is! String) return null;
        if (id != null) {
          if (id is! int) return null;
          final ok = e == PerrCode.id ? _isInt32(id) : _isPolygonId(id);
          if (!ok) return null;
        }
        return PolygonRejected(id: id as int?, reason: e as String?);
      case 'ACK':
        final seq = decoded['seq'];
        if (seq is! int || seq < 0 || seq > 65535) return null;
        return CommandAck(seq);
      case 'GPS':
        return _decodeGps(decoded);
      default:
        return null;
    }
  }

  static GpsFix? _decodeGps(Map<String, dynamic> m) {
    final fix = m['fix'];
    if (fix is! int || fix < 0) return null;
    final lat = m['lat'];
    final lon = m['lon'];
    if (lat != null && (lat is! int || lat.abs() > latE7Max)) return null;
    if (lon != null && (lon is! int || lon.abs() > lonE7Max)) return null;
    final hasPos = fix > 0 && lat is int && lon is int;
    final sats = m['sats'];
    final hdop = m['hdop'];
    if (sats != null && (sats is! int || sats < -1)) return null;
    if (hdop != null && (hdop is! num || (hdop < 0 && hdop != -1))) return null;
    return GpsFix(
      lat: hasPos ? lat / 1e7 : null,
      lon: hasPos ? lon / 1e7 : null,
      fixQuality: fix,
      satellites: (sats is int && sats >= 0) ? sats : null,
      hdop: (hdop is num && hdop >= 0) ? hdop.toDouble() : null,
      simulated: false,
    );
  }

  static bool _isInt32(int v) => v >= int32Min && v <= int32Max;

  static bool _isPolygonId(int v) => v >= polygonIdMin && v <= polygonIdMax;

  static String _stripNewline(String line) {
    var s = line;
    if (s.endsWith('\n')) s = s.substring(0, s.length - 1);
    if (s.endsWith('\r')) s = s.substring(0, s.length - 1);
    return s;
  }
}

/// Reensambla líneas a partir de fragmentos de bytes (notificaciones BLE que
/// pueden partir o juntar mensajes). Descarta líneas que superan
/// [maxLineLength] para no crecer sin límite si llega basura sin `\n`.
class LineAssembler {
  final int maxLineLength;
  final List<int> _buf = [];
  bool _overflow = false;

  LineAssembler({this.maxLineLength = EspProtocol.maxLineLength});

  /// Agrega bytes y devuelve las líneas completas (sin `\n`), decodificadas
  /// como UTF-8 tolerante.
  List<String> add(List<int> bytes) {
    final out = <String>[];
    for (final b in bytes) {
      if (b == 0x0A) {
        if (!_overflow) {
          out.add(utf8.decode(_buf, allowMalformed: true));
        }
        _buf.clear();
        _overflow = false;
      } else if (!_overflow) {
        _buf.add(b);
        if (_buf.length > maxLineLength) {
          _buf.clear();
          _overflow = true; // se descarta hasta el próximo `\n`
        }
      }
    }
    return out;
  }

  void reset() {
    _buf.clear();
    _overflow = false;
  }
}
