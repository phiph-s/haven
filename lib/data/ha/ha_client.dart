import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../haven_repository.dart';
import '../models/snapshot.dart';

typedef ChannelFactory = WebSocketChannel Function(Uri uri);

/// Fehler aus der HA-Antwort (`success: false`).
class HaError extends HavenException {
  HaError(super.message, {super.code});
}

/// WebSocket-Client für Home Assistant.
///
/// - Auth per Long-Lived-Token (`auth_required` / `auth` / `auth_ok`)
/// - Request-IDs mit Futures
/// - Abos, die nach jedem Reconnect automatisch neu gesendet werden
/// - Reconnect mit exponentiellem Backoff (1 s bis 30 s, mit Jitter)
/// - Ping alle 25 s, tote Verbindungen werden erkannt
///
/// TODO(oauth): Login über HA (IndieAuth/OAuth) statt Token. Der Client
/// bekommt dann einen Token-Provider statt eines festen Strings.
class HaClient {
  HaClient({
    required String url,
    required String token,
    this.tokenProvider,
    ChannelFactory? channelFactory,
    this.pingInterval = const Duration(seconds: 25),
    this.requestTimeout = const Duration(seconds: 15),
    this.minBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    Random? random,
  }) : uri = websocketUri(url),
       // ignore: prefer_initializing_formals
       _token = token,
       _factory = channelFactory ?? ((u) => WebSocketChannel.connect(u)),
       _rng = random ?? Random();

  final Uri uri;
  String _token;

  /// Liefert vor jedem Verbindungsaufbau ein gültiges Token (Panel in HA:
  /// kurzlebiges Access-Token aus `hass.auth`). Ohne gilt das feste Token.
  final Future<String> Function()? tokenProvider;
  int _authFailures = 0;
  final ChannelFactory _factory;
  final Duration pingInterval;
  final Duration requestTimeout;
  final Duration minBackoff;
  final Duration maxBackoff;
  final Random _rng;

  final _statusCtrl = StreamController<ConnectionStatus>.broadcast();
  final _connectedCtrl = StreamController<void>.broadcast();
  ConnectionStatus _status = ConnectionStatus.connecting;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  Completer<void>? _authDone;
  Completer<void>? _closedSignal;
  Timer? _pingTimer;
  Timer? _pongTimer;
  bool _stopped = false;
  bool _authFailed = false;
  int _nextId = 1;
  int _nextHandle = 1;
  Completer<void>? _firstConnect;

  final Map<int, Completer<dynamic>> _pending = {};
  final Map<int, _Sub> _subs = {};
  final Map<int, int> _routes = {}; // WS-ID -> Handle

  ConnectionStatus get status => _status;
  Stream<ConnectionStatus> get statusStream => _statusCtrl.stream;

  /// Feuert nach jedem erfolgreichen Auth, auch nach Reconnects.
  Stream<void> get onConnected => _connectedCtrl.stream;

  bool get isConnected => _status == ConnectionStatus.connected;

  /// `http(s)://host:8123` nach `ws(s)://host:8123/api/websocket`.
  static Uri websocketUri(String input) {
    var s = input.trim();
    if (!s.contains('://')) s = 'http://$s';
    final u = Uri.parse(s);
    final scheme = switch (u.scheme) {
      'https' || 'wss' => 'wss',
      _ => 'ws',
    };
    var path = u.path;
    if (!path.endsWith('/api/websocket')) {
      path =
          '${path.endsWith('/') ? path.substring(0, path.length - 1) : path}/api/websocket';
    }
    return Uri(
      scheme: scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: path,
    );
  }

  void _setStatus(ConnectionStatus s) {
    if (_status == s) return;
    _status = s;
    if (!_statusCtrl.isClosed) _statusCtrl.add(s);
  }

  /// Startet die Verbindungsschleife. Das Future endet mit dem ersten
  /// erfolgreichen Auth. Bei `failFast` scheitert es schon, wenn der erste
  /// Versuch nicht klappt (Onboarding). Sonst versucht der Client es weiter.
  Future<void> start({bool failFast = false}) {
    if (_firstConnect != null) return _firstConnect!.future;
    _firstConnect = Completer<void>();
    unawaited(_loop(failFast));
    return _firstConnect!.future;
  }

  Future<void> _loop(bool failFast) async {
    var backoff = minBackoff;
    while (!_stopped) {
      try {
        await _connectOnce();
        backoff = minBackoff;
        if (_firstConnect != null && !_firstConnect!.isCompleted) {
          _firstConnect!.complete();
        }
        await _closedSignal!.future;
      } catch (e) {
        _teardown();
        // Mit Token-Quelle (Panel) war das Token vielleicht gerade
        // abgelaufen: zweimal neu holen, erst dann aufgeben.
        if (_authFailed && tokenProvider != null && ++_authFailures < 3) {
          _authFailed = false;
        }
        if (_authFailed) {
          _setStatus(ConnectionStatus.authFailed);
          _failFirst(
            HavenException('Der Token wurde abgelehnt.', code: 'auth_invalid'),
          );
          return;
        }
        if (failFast && !(_firstConnect?.isCompleted ?? true)) {
          _setStatus(ConnectionStatus.offline);
          _failFirst(
            HavenException(
              'Home Assistant ist nicht erreichbar.',
              code: 'unreachable',
            ),
          );
          return;
        }
      }
      if (_stopped) break;
      _teardown();
      if (_authFailed) return;
      _setStatus(ConnectionStatus.reconnecting);
      final jitter = Duration(milliseconds: _rng.nextInt(400));
      await Future<void>.delayed(backoff + jitter);
      backoff = Duration(
        milliseconds: min(
          backoff.inMilliseconds * 2,
          maxBackoff.inMilliseconds,
        ),
      );
    }
  }

  void _failFirst(Object e) {
    final c = _firstConnect;
    if (c != null && !c.isCompleted) c.completeError(e);
  }

  Future<void> _connectOnce() async {
    final tp = tokenProvider;
    if (tp != null) {
      try {
        final t = await tp();
        if (t.isNotEmpty) _token = t;
      } catch (_) {
        // Das letzte Token versuchen.
      }
    }
    _authDone = Completer<void>();
    _closedSignal = Completer<void>();
    final ch = _factory(uri);
    _channel = ch;
    await ch.ready.timeout(const Duration(seconds: 10));
    _channelSub = ch.stream.listen(
      _onMessage,
      onError: (Object e) => _signalClosed(),
      onDone: _signalClosed,
      cancelOnError: true,
    );
    await _authDone!.future.timeout(const Duration(seconds: 10));
    _authFailures = 0;
    _setStatus(ConnectionStatus.connected);
    _startPing();
    await _resubscribe();
    if (!_connectedCtrl.isClosed) _connectedCtrl.add(null);
  }

  void _signalClosed() {
    final c = _closedSignal;
    if (c != null && !c.isCompleted) c.complete();
    final a = _authDone;
    if (a != null && !a.isCompleted) {
      a.completeError(HavenException('Verbindung beendet'));
    }
  }

  void _teardown() {
    _pingTimer?.cancel();
    _pongTimer?.cancel();
    _channelSub?.cancel();
    _channelSub = null;
    final ch = _channel;
    _channel = null;
    ch?.sink.close();
    _routes.clear();
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(
          HavenException('Verbindung verloren', code: 'disconnected'),
        );
      }
    }
    _pending.clear();
  }

  void _onMessage(dynamic raw) {
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'auth_required':
        _sendRaw({'type': 'auth', 'access_token': _token});
      case 'auth_ok':
        final a = _authDone;
        if (a != null && !a.isCompleted) a.complete();
      case 'auth_invalid':
        _authFailed = true;
        final a = _authDone;
        if (a != null && !a.isCompleted) {
          a.completeError(HavenException('auth_invalid', code: 'auth_invalid'));
        }
      case 'pong':
        _pongTimer?.cancel();
      case 'result':
        final c = _pending.remove(msg['id']);
        if (c == null || c.isCompleted) return;
        if (msg['success'] == true) {
          c.complete(msg['result']);
        } else {
          final err = (msg['error'] as Map?) ?? const {};
          c.completeError(
            HaError(
              '${err['message'] ?? 'Fehler'}',
              code: err['code'] as String?,
            ),
          );
        }
      case 'event':
        final h = _routes[msg['id']];
        final sub = h == null ? null : _subs[h];
        sub?.handler(msg['event']);
    }
  }

  void _sendRaw(Map<String, dynamic> m) {
    _channel?.sink.add(jsonEncode(m));
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(pingInterval, (_) {
      if (!isConnected) return;
      _sendRaw({'id': _nextId++, 'type': 'ping'});
      _pongTimer?.cancel();
      _pongTimer = Timer(const Duration(seconds: 10), () {
        // Keine Antwort: Verbindung gilt als tot.
        _channel?.sink.close();
        _signalClosed();
      });
    });
  }

  /// Sendet einen Befehl, `id` wird gesetzt. Das Future liefert `result`.
  Future<dynamic> send(Map<String, dynamic> message, {Duration? timeout}) {
    if (!isConnected || _channel == null) {
      return Future.error(
        HavenException(
          'Keine Verbindung zu Home Assistant.',
          code: 'disconnected',
        ),
      );
    }
    final id = _nextId++;
    final c = Completer<dynamic>();
    _pending[id] = c;
    _sendRaw({...message, 'id': id});
    return c.future.timeout(
      timeout ?? requestTimeout,
      onTimeout: () {
        _pending.remove(id);
        throw HavenException(
          'Keine Antwort von Home Assistant.',
          code: 'timeout',
        );
      },
    );
  }

  /// Abo, das Reconnects übersteht. Rückgabe ist ein Handle für [unsubscribe].
  Future<int> subscribe(
    Map<String, dynamic> message,
    void Function(dynamic event) onEvent,
  ) async {
    final handle = _nextHandle++;
    _subs[handle] = _Sub(message, onEvent);
    if (isConnected) await _subscribeOne(handle);
    return handle;
  }

  Future<void> _subscribeOne(int handle) async {
    final sub = _subs[handle];
    if (sub == null) return;
    final id = _nextId++;
    _routes[id] = handle;
    sub.wsId = id;
    final c = Completer<dynamic>();
    _pending[id] = c;
    _sendRaw({...sub.message, 'id': id});
    await c.future.timeout(requestTimeout);
  }

  Future<void> _resubscribe() async {
    for (final h in _subs.keys.toList()) {
      try {
        await _subscribeOne(h);
      } catch (e) {
        debugPrint('Abo $h nicht erneuert: $e');
      }
    }
  }

  Future<void> unsubscribe(int handle) async {
    final sub = _subs.remove(handle);
    final wsId = sub?.wsId;
    if (wsId != null) {
      _routes.remove(wsId);
      if (isConnected) {
        try {
          await send({'type': 'unsubscribe_events', 'subscription': wsId});
        } catch (_) {}
      }
    }
  }

  Future<void> close() async {
    _stopped = true;
    _teardown();
    _signalClosed();
    _setStatus(ConnectionStatus.offline);
    await _statusCtrl.close();
    await _connectedCtrl.close();
  }
}

class _Sub {
  _Sub(this.message, this.handler);
  final Map<String, dynamic> message;
  final void Function(dynamic) handler;
  int? wsId;
}
