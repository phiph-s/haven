import 'dart:async';

import 'haven_repository.dart';
import 'models/snapshot.dart';

/// Gemeinsamer Unterbau: hält den Snapshot und den Broadcast-Stream.
abstract class BaseRepository implements HavenRepository {
  HavenSnapshot _snapshot = const HavenSnapshot();
  final StreamController<HavenSnapshot> _controller =
      StreamController<HavenSnapshot>.broadcast();
  bool _disposed = false;

  @override
  HavenSnapshot get snapshot => _snapshot;

  @override
  Stream<HavenSnapshot> get snapshots => _controller.stream;

  bool get disposed => _disposed;

  /// Ersetzt den Snapshot und benachrichtigt die Hörer.
  void publish(HavenSnapshot s) {
    if (_disposed) return;
    _snapshot = s;
    _controller.add(s);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _controller.close();
  }
}
