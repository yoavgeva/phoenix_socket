import 'dart:async';
import 'dart:convert';

import 'package:phoenix_socket/src/channel.dart';
import 'package:phoenix_socket/src/message.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// The connection state of a [PhoenixSocket].
enum PhoenixSocketState {
  /// Establishing the WebSocket connection.
  connecting,

  /// Connected and heartbeat active.
  connected,

  /// Not connected (intentional disconnect or initial state).
  disconnected,

  /// Connection lost; waiting to reconnect.
  reconnecting,
}

/// Manages a Phoenix WebSocket connection.
///
/// Handles connection, heartbeat, reconnection with exponential backoff,
/// and routes incoming messages to the appropriate [PhoenixChannel].
class PhoenixSocket {
  /// Creates a [PhoenixSocket] for the given [url].
  ///
  /// [params] are appended as query parameters (alongside `vsn=2.0.0`).
  /// [channelFactory] overrides the WebSocket constructor — useful in tests.
  PhoenixSocket(
    String url, {
    Map<String, String> params = const {},
    WebSocketChannel Function(Uri)? channelFactory,
  })  : _url = url,
        _params = params,
        _channelFactory = channelFactory ?? WebSocketChannel.connect;

  final String _url;
  final Map<String, String> _params;
  final WebSocketChannel Function(Uri) _channelFactory;

  /// Reconnect intervals in seconds, matching Phoenix JS client.
  static const List<int> _reconnectIntervals = [1, 2, 4, 8, 16, 30];

  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  String? _pendingHeartbeatRef;
  int _ref = 0;
  int _reconnectAttempts = 0;
  bool _intentionalDisconnect = false;
  PhoenixSocketState _state = PhoenixSocketState.disconnected;

  final Map<String, PhoenixChannel> _channels = {};
  final StreamController<PhoenixSocketState> _stateController =
      StreamController<PhoenixSocketState>.broadcast(sync: true);

  /// Stream of socket state changes.
  Stream<PhoenixSocketState> get states => _stateController.stream;

  /// Current socket state.
  PhoenixSocketState get state => _state;

  /// Connects to the Phoenix server.
  ///
  /// Idempotent: returns immediately if already connected, connecting, or
  /// reconnecting.
  Future<void> connect() async {
    // Bug fix: also guard reconnecting state to prevent concurrent connects.
    if (_state == PhoenixSocketState.connected ||
        _state == PhoenixSocketState.connecting ||
        _state == PhoenixSocketState.reconnecting) {
      return;
    }

    _intentionalDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _setState(PhoenixSocketState.connecting);

    try {
      final uri = _buildUri();
      _ws = _channelFactory(uri);
      _wsSub = _ws!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );
      await _ws!.ready;
      // Guard: if stream already closed (onDone fired before ready resolved),
      // state may already be reconnecting — don't override it.
      if (_state != PhoenixSocketState.connecting) return;
      _setState(PhoenixSocketState.connected);
      _reconnectAttempts = 0;
      _startHeartbeat();
      _rejoinChannels();
    } on Exception {
      _setState(PhoenixSocketState.disconnected);
      _scheduleReconnect();
    }
  }

  /// Disconnects from the Phoenix server.
  ///
  /// Sets intentional disconnect flag so reconnection is NOT attempted.
  Future<void> disconnect() {
    _intentionalDisconnect = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    // Bug fix: clear pending heartbeat ref so a reconnect+disconnect cycle
    // doesn't spuriously reconnect on the next heartbeat tick.
    _pendingHeartbeatRef = null;
    // Bug fix: don't await cancel/close — StreamSubscription.cancel() on a
    // broadcast stream may not resolve until the controller is closed, which
    // would deadlock in test environments.
    unawaited(_wsSub?.cancel());
    _wsSub = null;
    unawaited(_ws?.sink.close());
    _ws = null;
    for (final ch in _channels.values) {
      // Bug fix: intentional disconnect closes channels (not errored) so that
      // subsequent push() calls throw StateError immediately.
      ch.onIntentionalDisconnect();
    }
    _setState(PhoenixSocketState.disconnected);
    return Future<void>.value();
  }

  /// Returns a [PhoenixChannel] for the given topic, creating one if needed.
  PhoenixChannel channel(String topic) {
    return _channels.putIfAbsent(topic, () => PhoenixChannel(topic, this));
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Uri _buildUri() {
    final params = Map<String, String>.from(_params);
    params['vsn'] = '2.0.0';
    final uri = Uri.parse(_url);
    return uri.replace(
      queryParameters: {...uri.queryParameters, ...params},
    );
  }

  /// Generates the next message reference.
  String nextRef() => (++_ref).toString();

  /// Sends a message if connected.
  void send(PhoenixMessage message) {
    if (_state != PhoenixSocketState.connected) return;
    _ws?.sink.add(message.encode());
  }

  void _setState(PhoenixSocketState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  void _onMessage(dynamic data) {
    // Bug fix: wrap in try/catch so malformed messages don't trigger a
    // spurious reconnect via the stream's onError handler.
    try {
      final json = jsonDecode(data as String) as List<dynamic>;
      final message = PhoenixMessage.fromJson(json);

      // Handle heartbeat reply
      if (message.topic == 'phoenix' && message.event == 'phx_reply') {
        if (message.ref == _pendingHeartbeatRef) {
          _pendingHeartbeatRef = null;
        }
        return;
      }

      // Route to channel
      _channels[message.topic]?.receive(message);
    } on Exception {
      // Ignore malformed messages — do not disconnect.
    }
  }

  void _onError(Object error) {
    _handleDisconnect();
  }

  void _onDone() {
    _handleDisconnect();
  }

  void _handleDisconnect() {
    if (_intentionalDisconnect) return;
    // Bug fix: idempotent guard — if already reconnecting, a second call
    // must not schedule another reconnect or notify channels twice.
    if (_state == PhoenixSocketState.reconnecting ||
        _state == PhoenixSocketState.disconnected) {
      return;
    }
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    unawaited(_wsSub?.cancel());
    _wsSub = null;
    _ws = null;
    for (final ch in _channels.values) {
      ch.onSocketDisconnect();
    }
    _scheduleReconnect();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_pendingHeartbeatRef != null) {
        // Heartbeat not acknowledged — trigger reconnect.
        _pendingHeartbeatRef = null;
        _heartbeatTimer?.cancel();
        _heartbeatTimer = null;
        unawaited(_wsSub?.cancel());
        _wsSub = null;
        final ws = _ws;
        _ws = null;
        // may fire _onDone async, but _handleDisconnect guards idempotently
        unawaited(ws?.sink.close());
        for (final ch in _channels.values) {
          ch.onSocketDisconnect();
        }
        _scheduleReconnect();
        return;
      }
      final ref = nextRef();
      _pendingHeartbeatRef = ref;
      send(PhoenixMessage(
        joinRef: null,
        ref: ref,
        topic: 'phoenix',
        event: 'heartbeat',
        payload: const {},
      ));
    });
  }

  void _scheduleReconnect() {
    if (_intentionalDisconnect) return;
    _setState(PhoenixSocketState.reconnecting);

    final idx = _reconnectAttempts < _reconnectIntervals.length
        ? _reconnectAttempts
        : _reconnectIntervals.length - 1;
    final delay = Duration(seconds: _reconnectIntervals[idx]);
    _reconnectAttempts++;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      _reconnectTimer = null;
      // Override reconnecting guard for the timer-triggered reconnect.
      _state = PhoenixSocketState.disconnected;
      await connect();
    });
  }

  void _rejoinChannels() {
    for (final ch in _channels.values) {
      if (ch.state == PhoenixChannelState.errored ||
          ch.state == PhoenixChannelState.joining) {
        ch.rejoin();
      }
    }
  }
}
