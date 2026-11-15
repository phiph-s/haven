import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Gegenstelle: spielt einen HA-Server nach.
class FakeServer {
  FakeServer(this.channel);
  final FakeChannel channel;
  final List<Map<String, dynamic>> received = [];
  bool accept = true;
  void Function(FakeServer server, Map<String, dynamic> msg)? onMessage;

  void greet() => send({'type': 'auth_required', 'ha_version': 'test'});
  void send(Map<String, dynamic> m) => channel._in.add(jsonEncode(m));
  void close() => channel._in.close();

  void _onClient(dynamic raw) {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    received.add(m);
    if (m['type'] == 'auth') {
      send({'type': accept ? 'auth_ok' : 'auth_invalid'});
    } else {
      onMessage?.call(this, m);
    }
  }
}

class FakeChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  FakeChannel() {
    _outCtl.stream.listen((d) => server._onClient(d));
    server = FakeServer(this);
  }
  late final FakeServer server;
  final _in = StreamController<dynamic>();
  final _outCtl = StreamController<dynamic>();

  @override
  Stream<dynamic> get stream => _in.stream;
  @override
  WebSocketSink get sink => _Sink(_outCtl);
  @override
  Future<void> get ready => Future<void>.value();
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
}

class _Sink implements WebSocketSink {
  _Sink(this._c);
  final StreamController<dynamic> _c;
  @override
  void add(dynamic data) => _c.add(data);
  @override
  void addError(Object error, [StackTrace? st]) => _c.addError(error, st);
  @override
  Future<void> addStream(Stream<dynamic> stream) => _c.addStream(stream);
  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}
  @override
  Future<void> get done => _c.done;
}
