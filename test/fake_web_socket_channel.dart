import 'dart:async';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A fake [WebSocketChannel] for testing.
///
/// Bidirectional: write to [server.sink] to send to the client;
/// read [server.stream] to see what the client sent.
class FakeWebSocketChannel extends StreamChannelMixin<Object?>
    implements WebSocketChannel {
  // Client → server (what the socket sends)
  final _toServer = StreamController<dynamic>.broadcast();
  // Server → client (what we inject as incoming messages)
  final _toClient = StreamController<dynamic>.broadcast();

  late final StreamChannel<dynamic> _server = StreamChannel<dynamic>(
    _toServer.stream,
    _FakeStreamSink(_toClient),
  );

  /// Server side of the connection for tests to use.
  StreamChannel<dynamic> get server => _server;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Future<void> get ready => Future.value();

  @override
  Stream<dynamic> get stream => _toClient.stream;

  @override
  WebSocketSink get sink => _FakeWebSocketSink(_toServer);

  void close() {
    unawaited(_toServer.close());
    unawaited(_toClient.close());
  }
}

class _FakeStreamSink implements StreamSink<dynamic> {
  _FakeStreamSink(this._controller);
  final StreamController<dynamic> _controller;
  final _doneCompleter = Completer<void>();

  @override
  void add(dynamic event) => _controller.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _controller.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<dynamic> stream) {
    final sub = stream.listen(
      _controller.add,
      onError: _controller.addError,
    );
    return sub.asFuture<void>();
  }

  @override
  Future<void> close() {
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
    // Closing server.sink means the server is done sending — close the client stream.
    unawaited(_controller.close());
    return Future.value();
  }

  @override
  Future<void> get done => _doneCompleter.future;
}

class _FakeWebSocketSink implements WebSocketSink {
  _FakeWebSocketSink(this._toServer);
  final StreamController<dynamic> _toServer;
  final _doneCompleter = Completer<void>();

  @override
  void add(dynamic data) => _toServer.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _toServer.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<dynamic> stream) {
    final sub = stream.listen(
      _toServer.add,
      onError: _toServer.addError,
    );
    return sub.asFuture<void>();
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
    return Future.value();
  }

  @override
  Future<void> get done => _doneCompleter.future;
}
