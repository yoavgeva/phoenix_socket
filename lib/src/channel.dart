import 'dart:async';

import 'package:phoenix_socket/src/exceptions.dart';
import 'package:phoenix_socket/src/message.dart';
import 'package:phoenix_socket/src/socket.dart';

/// The lifecycle state of a [PhoenixChannel].
enum PhoenixChannelState {
  /// Channel has not joined or has been explicitly closed.
  closed,

  /// Join has been sent; awaiting server reply.
  joining,

  /// Join confirmed by the server.
  joined,

  /// Leave has been sent; awaiting server reply.
  leaving,

  /// An error occurred; the socket will attempt to rejoin.
  errored,
}

/// Manages a Phoenix Channel's lifecycle: join, push, leave.
///
/// Created via [PhoenixSocket.channel], not directly.
class PhoenixChannel {
  /// Internal constructor — use [PhoenixSocket.channel] instead.
  PhoenixChannel(this.topic, this._socket);

  /// The channel topic (e.g. `"room:lobby"`).
  final String topic;
  final PhoenixSocket _socket;

  PhoenixChannelState _state = PhoenixChannelState.closed;
  String? _joinRef;
  Map<String, dynamic>? _joinPayload;
  bool _joinCalled = false;
  Completer<Map<String, dynamic>>? _joinCompleter;

  final Map<String, Completer<Map<String, dynamic>>> _pendingRefs = {};
  final List<_BufferedPush> _pushBuffer = [];

  final StreamController<PhoenixMessage> _messagesController =
      StreamController<PhoenixMessage>.broadcast(sync: true);

  static const _controlEvents = {
    'phx_reply',
    'phx_join',
    'phx_leave',
    'phx_close',
    'phx_error',
  };

  /// Current channel state.
  PhoenixChannelState get state => _state;

  /// The join ref for the current join cycle. Null before [join] is called.
  ///
  /// Used by `PhoenixPresence` to detect reconnects.
  String? get joinRef => _joinRef;

  /// Broadcast stream of incoming app events (control events filtered out).
  Stream<PhoenixMessage> get messages => _messagesController.stream;

  /// Joins the channel.
  ///
  /// Throws [StateError] if called more than once on the same instance.
  /// Throws [PhoenixException] if the server replies with an error.
  Future<Map<String, dynamic>> join({
    Map<String, dynamic> payload = const {},
  }) {
    if (_joinCalled) {
      return Future.error(
        StateError(
          'PhoenixChannel: tried to join multiple times. '
          'Create a new channel instance via socket.channel("$topic").',
        ),
      );
    }
    _joinCalled = true;
    _joinPayload = Map<String, dynamic>.from(payload);
    _state = PhoenixChannelState.joining;

    return _sendJoin();
  }

  Future<Map<String, dynamic>> _sendJoin() {
    final ref = _socket.nextRef();
    _joinRef = ref;
    _joinCompleter = Completer<Map<String, dynamic>>();

    _socket.send(
      PhoenixMessage(
        joinRef: ref,
        ref: ref,
        topic: topic,
        event: 'phx_join',
        payload: _joinPayload ?? const {},
      ),
    );

    return _joinCompleter!.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        // Bug fix: null out _joinCompleter so a late phx_reply doesn't
        // transition state to joined after the caller got TimeoutException.
        _joinCompleter = null;
        _state = PhoenixChannelState.errored;
        throw TimeoutException('Channel join timed out: $topic');
      },
    );
  }

  /// Leaves the channel.
  Future<void> leave() async {
    if (_state == PhoenixChannelState.closed) return;

    // Bug fix: if we're still joining, fail the pending join before leaving.
    final joinCompleter = _joinCompleter;
    if (joinCompleter != null && !joinCompleter.isCompleted) {
      _joinCompleter = null;
      joinCompleter.completeError(
        const PhoenixException('Channel left before join completed'),
      );
    }

    _state = PhoenixChannelState.leaving;

    final ref = _socket.nextRef();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRefs[ref] = completer;

    _socket.send(
      PhoenixMessage(
        joinRef: _joinRef,
        ref: ref,
        topic: topic,
        event: 'phx_leave',
        payload: const {},
      ),
    );

    try {
      await completer.future.timeout(const Duration(seconds: 5));
    } on Exception {
      // Best-effort leave — ignore timeout / rejection.
    }
    _state = PhoenixChannelState.closed;
    // Bug fix: error-complete buffered push completers instead of silently
    // discarding them — callers awaiting ch.push() would otherwise hang.
    final buffered = List<_BufferedPush>.from(_pushBuffer);
    _pushBuffer.clear();
    for (final b in buffered) {
      if (!b.completer.isCompleted) {
        b.completer.completeError(
          StateError('Channel left before buffered push could be sent'),
        );
      }
    }
  }

  /// Pushes an event to the channel.
  ///
  /// Throws [StateError] if [join] was never called.
  /// Throws [PhoenixException] if the server replies with an error status.
  /// Throws [TimeoutException] if no reply is received within 10 seconds.
  Future<Map<String, dynamic>> push(
    String event,
    Map<String, dynamic> payload,
  ) {
    if (!_joinCalled) {
      throw StateError(
        'PhoenixChannel: tried to push before joining. '
        'Call join() first.',
      );
    }

    if (_state == PhoenixChannelState.joining) {
      final completer = Completer<Map<String, dynamic>>();
      _pushBuffer.add(_BufferedPush(event, payload, completer));
      return completer.future;
    }

    if (_state == PhoenixChannelState.closed ||
        _state == PhoenixChannelState.leaving) {
      throw StateError('Channel is not joined (state: $_state)');
    }

    // Bug fix: also buffer pushes during errored state so they aren't lost
    // in the window between socket disconnect and rejoin.
    if (_state == PhoenixChannelState.errored) {
      final completer = Completer<Map<String, dynamic>>();
      _pushBuffer.add(_BufferedPush(event, payload, completer));
      return completer.future;
    }

    return _sendPush(event, payload);
  }

  Future<Map<String, dynamic>> _sendPush(
    String event,
    Map<String, dynamic> payload,
  ) {
    final ref = _socket.nextRef();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRefs[ref] = completer;

    _socket.send(
      PhoenixMessage(
        joinRef: _joinRef,
        ref: ref,
        topic: topic,
        event: event,
        payload: payload,
      ),
    );

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _pendingRefs.remove(ref);
        throw TimeoutException('Push timed out: $event on $topic');
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Internal — called by PhoenixSocket
  // ---------------------------------------------------------------------------

  /// Routes an incoming message to the appropriate handler.
  void receive(PhoenixMessage message) {
    // Drop stale messages (from a previous join)
    if (message.joinRef != null &&
        _joinRef != null &&
        message.joinRef != _joinRef) {
      return;
    }

    switch (message.event) {
      case 'phx_reply':
        _handleReply(message);
      case 'phx_close':
        // Bug fix: complete _joinCompleter with error if pending.
        _failPendingJoin(
          const PhoenixException('Channel closed by server'),
        );
        _state = PhoenixChannelState.closed;
      case 'phx_error':
        // Bug fix: complete _joinCompleter with error if pending.
        _failPendingJoin(
          const PhoenixException('Channel error from server'),
        );
        // Bug fix: clear in-flight push completers — they will never get a
        // reply after phx_error. Without this they hang until 10s timeout.
        _clearPendingRefs(
          const PhoenixException('Channel error from server'),
        );
        _state = PhoenixChannelState.errored;
      default:
        if (!_controlEvents.contains(message.event)) {
          _messagesController.add(message);
        }
    }
  }

  void _failPendingJoin(PhoenixException error) {
    final completer = _joinCompleter;
    if (completer != null && !completer.isCompleted) {
      _joinCompleter = null;
      completer.completeError(error);
    }
  }

  void _handleReply(PhoenixMessage message) {
    final ref = message.ref;
    if (ref == null) return;

    final status = message.payload['status'] as String?;
    final response =
        (message.payload['response'] as Map<dynamic, dynamic>?)
            ?.cast<String, dynamic>() ??
        {};

    // Check if this is a reply to our join
    if (ref == _joinRef) {
      final completer = _joinCompleter;
      _joinCompleter = null;
      if (completer == null || completer.isCompleted) return;

      if (status == 'ok') {
        _state = PhoenixChannelState.joined;
        completer.complete(response);
        _flushPushBuffer();
      } else {
        _state = PhoenixChannelState.errored;
        completer.completeError(
          PhoenixException(
            'Channel join failed: $status',
            response: response,
          ),
        );
      }
      return;
    }

    // Regular push reply
    final completer = _pendingRefs.remove(ref);
    if (completer == null || completer.isCompleted) return;

    if (status == 'ok') {
      completer.complete(response);
    } else {
      completer.completeError(
        PhoenixException('Push failed: $status', response: response),
      );
    }
  }

  void _flushPushBuffer() {
    final buffer = List<_BufferedPush>.from(_pushBuffer);
    _pushBuffer.clear();

    for (final buffered in buffer) {
      if (_state != PhoenixChannelState.joined) {
        buffered.completer.completeError(
          StateError('Channel closed before buffered push could be sent'),
        );
        continue;
      }
      unawaited(
        _sendPush(buffered.event, buffered.payload).then(
          buffered.completer.complete,
          onError: buffered.completer.completeError,
        ),
      );
    }
  }

  /// Called by the socket on intentional disconnect.
  ///
  /// Unlike [onSocketDisconnect], this transitions to
  /// [PhoenixChannelState.closed] so that subsequent [push] calls throw
  /// [StateError] immediately instead of buffering forever (no reconnect
  /// will ever come).
  void onIntentionalDisconnect() {
    _clearPendingRefs(const PhoenixException('Socket disconnected'));
    _state = PhoenixChannelState.closed;
  }

  /// Called by the socket when the connection drops unexpectedly.
  void onSocketDisconnect() {
    _clearPendingRefs(const PhoenixException('Socket disconnected'));
    // Bug fix: also transition `leaving` to `errored` — leave() can be
    // called concurrently with a socket disconnect.
    if (_state == PhoenixChannelState.joined ||
        _state == PhoenixChannelState.joining ||
        _state == PhoenixChannelState.leaving) {
      _state = PhoenixChannelState.errored;
    }
  }

  void _clearPendingRefs(Exception error) {
    final pending = Map<String, Completer<Map<String, dynamic>>>.from(
      _pendingRefs,
    );
    _pendingRefs.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }

    final joinCompleter = _joinCompleter;
    if (joinCompleter != null && !joinCompleter.isCompleted) {
      _joinCompleter = null;
      joinCompleter.completeError(error);
    }

    // Bug fix: buffered pushes also have completers that must be
    // error-completed on disconnect/leave.
    final buffered = List<_BufferedPush>.from(_pushBuffer);
    _pushBuffer.clear();
    for (final b in buffered) {
      if (!b.completer.isCompleted) {
        b.completer.completeError(error);
      }
    }
  }

  /// Called by the socket after reconnection to rejoin the channel.
  void rejoin() {
    if (_joinPayload == null) return;
    _state = PhoenixChannelState.joining;

    final ref = _socket.nextRef();
    _joinRef = ref;
    _joinCompleter = Completer<Map<String, dynamic>>();

    _socket.send(
      PhoenixMessage(
        joinRef: ref,
        ref: ref,
        topic: topic,
        event: 'phx_join',
        payload: _joinPayload!,
      ),
    );

    // Bug fix: add timeout matching _sendJoin so rejoin doesn't hang forever.
    unawaited(
      _joinCompleter!.future
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              _joinCompleter = null;
              _state = PhoenixChannelState.errored;
              // Bug fix: clear push buffer on rejoin timeout.
              _clearPendingRefs(
                TimeoutException('Rejoin timed out: $topic'),
              );
              throw TimeoutException('Rejoin timed out: $topic');
            },
          )
          .catchError((Object _) => <String, dynamic>{}),
    );
  }
}

class _BufferedPush {
  _BufferedPush(this.event, this.payload, this.completer);

  final String event;
  final Map<String, dynamic> payload;
  final Completer<Map<String, dynamic>> completer;
}
