import 'dart:convert';

/// How the app talks to a camera.
enum CameraKind {
  /// A direct RTSP or RTSPS stream URL.
  rtsp,

  /// An ONVIF camera: the stream URL is looked up over ONVIF (SOAP) with
  /// WS-Security digest authentication.
  onvif,

  /// A camera or cloud bridge that serves JPEG snapshots over HTTP(S) and is
  /// authorised with an API key header.
  httpApi,
}

extension CameraKindLabel on CameraKind {
  String get label => switch (this) {
        CameraKind.rtsp => 'RTSP stream',
        CameraKind.onvif => 'ONVIF camera',
        CameraKind.httpApi => 'HTTPS API (API key)',
      };
}

enum RecordingMode { off, continuous, events }

extension RecordingModeLabel on RecordingMode {
  String get label => switch (this) {
        RecordingMode.off => 'Off',
        RecordingMode.continuous => 'Continuous (24/7)',
        RecordingMode.events => 'Only around events',
      };
}

/// Non-secret camera settings. Passwords and API keys are never stored here;
/// they live in [SecretStore] under keys derived from [id].
class Camera {
  Camera({
    required this.id,
    required this.name,
    required this.kind,
    this.host = '',
    this.port = 0,
    this.path = '',
    this.username = '',
    this.useTls = true,
    this.apiKeyHeader = 'X-API-Key',
    this.pinnedSha256,
    this.resolvedStreamUri,
    this.refreshSeconds = 2,
    this.aiFaces = false,
    this.aiPlates = false,
    this.aiIntervalSeconds = 2,
    this.recording = RecordingMode.off,
    this.retentionDays = 14,
    this.motion = false,
    this.alarmMotion = false,
    this.alarmFaces = false,
    this.alarmPlates = false,
    this.alarmWhenHome = false,
  });

  final String id;
  String name;
  CameraKind kind;

  /// Host name or IP of the camera.
  String host;

  /// Port; 0 means the protocol default.
  int port;

  /// RTSP: stream path (e.g. `/Streaming/Channels/101`).
  /// ONVIF: device service path (default `/onvif/device_service`).
  /// HTTP API: snapshot path (e.g. `/api/v1/snapshot.jpg`).
  String path;
  String username;

  /// Use RTSPS / HTTPS.
  bool useTls;

  /// Header name used to send the API key for [CameraKind.httpApi].
  String apiKeyHeader;

  /// SHA-256 fingerprint (hex) of the camera's TLS certificate, pinned when
  /// the camera was added. Null when the camera does not use TLS.
  String? pinnedSha256;

  /// ONVIF: stream URI discovered at setup, without credentials.
  String? resolvedStreamUri;

  /// HTTP API: seconds between snapshot refreshes.
  int refreshSeconds;

  /// Run face detection on this camera's live picture.
  bool aiFaces;

  /// Run number-plate detection and reading on this camera's live picture.
  bool aiPlates;

  /// Seconds between analysed frames.
  int aiIntervalSeconds;

  bool get aiEnabled => aiFaces || aiPlates;

  RecordingMode recording;

  /// Days of recordings to keep for this camera.
  int retentionDays;

  /// Run motion detection in the background.
  bool motion;

  /// Alarm triggers (used when the system is armed).
  bool alarmMotion, alarmFaces, alarmPlates;

  /// Also raise alarms in Home mode (e.g. outdoor cameras); otherwise only
  /// in Away mode.
  bool alarmWhenHome;

  bool get canRecord => kind != CameraKind.httpApi;

  /// Whether this camera needs a background worker.
  bool get needsWorker =>
      (canRecord && recording != RecordingMode.off) || motion || alarmMotion || alarmFaces || alarmPlates;

  int get effectivePort {
    if (port > 0) return port;
    return switch (kind) {
      CameraKind.rtsp => useTls ? 322 : 554,
      CameraKind.onvif => useTls ? 443 : 80,
      CameraKind.httpApi => useTls ? 443 : 80,
    };
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'host': host,
        'port': port,
        'path': path,
        'username': username,
        'useTls': useTls,
        'apiKeyHeader': apiKeyHeader,
        'pinnedSha256': pinnedSha256,
        'resolvedStreamUri': resolvedStreamUri,
        'refreshSeconds': refreshSeconds,
        'aiFaces': aiFaces,
        'aiPlates': aiPlates,
        'aiIntervalSeconds': aiIntervalSeconds,
        'recording': recording.name,
        'retentionDays': retentionDays,
        'motion': motion,
        'alarmMotion': alarmMotion,
        'alarmFaces': alarmFaces,
        'alarmPlates': alarmPlates,
        'alarmWhenHome': alarmWhenHome,
      };

  factory Camera.fromJson(Map<String, dynamic> j) => Camera(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Camera',
        kind: CameraKind.values.firstWhere(
          (k) => k.name == j['kind'],
          orElse: () => CameraKind.rtsp,
        ),
        host: j['host'] as String? ?? '',
        port: (j['port'] as num?)?.toInt() ?? 0,
        path: j['path'] as String? ?? '',
        username: j['username'] as String? ?? '',
        useTls: j['useTls'] as bool? ?? true,
        apiKeyHeader: j['apiKeyHeader'] as String? ?? 'X-API-Key',
        pinnedSha256: j['pinnedSha256'] as String?,
        resolvedStreamUri: j['resolvedStreamUri'] as String?,
        refreshSeconds: (j['refreshSeconds'] as num?)?.toInt() ?? 2,
        aiFaces: j['aiFaces'] as bool? ?? false,
        aiPlates: j['aiPlates'] as bool? ?? false,
        aiIntervalSeconds: (j['aiIntervalSeconds'] as num?)?.toInt() ?? 2,
        recording: RecordingMode.values.firstWhere((m) => m.name == j['recording'], orElse: () => RecordingMode.off),
        retentionDays: (j['retentionDays'] as num?)?.toInt() ?? 14,
        motion: j['motion'] as bool? ?? false,
        alarmMotion: j['alarmMotion'] as bool? ?? false,
        alarmFaces: j['alarmFaces'] as bool? ?? false,
        alarmPlates: j['alarmPlates'] as bool? ?? false,
        alarmWhenHome: j['alarmWhenHome'] as bool? ?? false,
      );

  Camera copy() => Camera.fromJson(jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);
}
