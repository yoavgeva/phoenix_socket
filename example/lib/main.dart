/// Flutter chat app example using dart_phoenix_socket.
///
/// Shows the recommended patterns for a real Flutter app:
///   - PhoenixSocketManager as a ChangeNotifier in the Provider tree
///   - Connect on login, disconnect on logout
///   - Join channels lazily and leave on dispose
///   - Fire-and-forget push vs. push-with-reply
///   - Reconnection state shown in the UI
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:dart_phoenix_socket/dart_phoenix_socket.dart';

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => PhoenixSocketManager(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'dart_phoenix_socket demo',
      home: const LoginScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// PhoenixSocketManager — put this in lib/services/
// ---------------------------------------------------------------------------

/// Manages the Phoenix WebSocket connection for the whole app.
///
/// Add to your Provider tree once at the root. Call [connect] after the user
/// logs in and [disconnect] when they log out.
class PhoenixSocketManager extends ChangeNotifier {
  PhoenixSocket? _socket;
  StreamSubscription<PhoenixSocketState>? _stateSub;

  PhoenixSocketState _socketState = PhoenixSocketState.disconnected;
  PhoenixSocketState get socketState => _socketState;

  bool get isConnected => _socketState == PhoenixSocketState.connected;

  // ── connect / disconnect ──────────────────────────────────────────────────

  Future<void> connect({required String url, String? token}) async {
    if (_socket != null) return; // already connecting or connected

    _socket = PhoenixSocket(
      url,
      params: token != null ? {'token': token} : {},
    );

    _stateSub = _socket!.states.listen((state) {
      _socketState = state;
      notifyListeners();
    });

    await _socket!.connect();
  }

  Future<void> disconnect() async {
    await _stateSub?.cancel();
    _stateSub = null;
    await _socket?.disconnect();
    _socket = null;
    _socketState = PhoenixSocketState.disconnected;
    notifyListeners();
  }

  // ── channel helpers ───────────────────────────────────────────────────────

  /// Returns the channel for [topic], joining it if needed.
  ///
  /// The socket must be connected before calling this.
  PhoenixChannel channel(String topic) {
    assert(_socket != null, 'Call connect() before channel()');
    return _socket!.channel(topic);
  }
}

// ---------------------------------------------------------------------------
// Simple ChangeNotifierProvider shim (no extra package needed for the example)
// ---------------------------------------------------------------------------

class ChangeNotifierProvider<T extends ChangeNotifier> extends StatefulWidget {
  final T Function(BuildContext) create;
  final Widget child;

  const ChangeNotifierProvider({
    super.key,
    required this.create,
    required this.child,
  });

  static T of<T extends ChangeNotifier>(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_InheritedNotifier<T>>()!
        .notifier;
  }

  @override
  State<ChangeNotifierProvider<T>> createState() =>
      _ChangeNotifierProviderState<T>();
}

class _ChangeNotifierProviderState<T extends ChangeNotifier>
    extends State<ChangeNotifierProvider<T>> {
  late final T _notifier;

  @override
  void initState() {
    super.initState();
    _notifier = widget.create(context);
    _notifier.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    _notifier.removeListener(_rebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _InheritedNotifier(notifier: _notifier, child: widget.child);
  }
}

class _InheritedNotifier<T extends ChangeNotifier> extends InheritedWidget {
  final T notifier;

  const _InheritedNotifier({required this.notifier, required super.child});

  @override
  bool updateShouldNotify(_InheritedNotifier<T> old) => true;
}

// ---------------------------------------------------------------------------
// Login screen
// ---------------------------------------------------------------------------

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = ChangeNotifierProvider.of<PhoenixSocketManager>(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Login')),
      body: Center(
        child: ElevatedButton(
          onPressed: manager.isConnected
              ? null
              : () async {
                  await manager.connect(
                    url: 'ws://localhost:4000/socket/websocket',
                    token: 'demo-token',
                  );
                  if (context.mounted) {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ChangeNotifierProvider(
                          create: (_) => ChatRoomNotifier(
                            manager: manager,
                            topic: 'room:lobby',
                          ),
                          child: const ChatScreen(),
                        ),
                      ),
                    );
                  }
                },
          child: const Text('Enter lobby'),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ChatRoomNotifier — one per channel, put this in lib/features/chat/
// ---------------------------------------------------------------------------

/// Drives the chat UI for a single Phoenix channel.
///
/// Joins the channel on creation, leaves on dispose.
class ChatRoomNotifier extends ChangeNotifier {
  final PhoenixSocketManager manager;
  final String topic;

  late final PhoenixChannel _channel;
  StreamSubscription<PhoenixMessage>? _msgSub;

  final List<ChatMessage> messages = [];
  String? error;
  bool joined = false;

  ChatRoomNotifier({required this.manager, required this.topic}) {
    _join();
  }

  Future<void> _join() async {
    _channel = manager.channel(topic);

    // Listen for server-broadcast events BEFORE joining so we don't miss
    // messages that arrive in the same microtask as the join reply.
    _msgSub = _channel.messages.listen(_onMessage);

    try {
      await _channel.join();
      joined = true;
      error = null;
    } on PhoenixException catch (e) {
      // Server refused the join — e.g. authentication failed, room full.
      error = 'Join refused: ${e.message}';
      if (e.response != null) {
        error = '$error (${e.response})';
      }
    } on TimeoutException {
      // Server never replied. Channel is in `errored` state and will
      // auto-rejoin after the socket reconnects.
      error = 'Join timed out — will retry on reconnect';
    }
    notifyListeners();
  }

  void _onMessage(PhoenixMessage msg) {
    switch (msg.event) {
      case 'new_msg':
        final body = msg.payload['body'] as String? ?? '';
        final user = msg.payload['user'] as String? ?? 'unknown';
        messages.add(ChatMessage(user: user, body: body));
        notifyListeners();

      case 'user_joined':
        final user = msg.payload['user'] as String? ?? 'someone';
        messages.add(ChatMessage(user: 'system', body: '$user joined'));
        notifyListeners();

      default:
        // Ignore unknown events
        break;
    }
  }

  /// Sends a chat message.
  ///
  /// Returns true on success, false on error (with [error] set).
  Future<bool> sendMessage(String body) async {
    try {
      await _channel.push('new_msg', {'body': body});
      return true;
    } on PhoenixException catch (e) {
      // Server rejected the push — e.g. rate limited, message too long.
      error = 'Message rejected: ${e.message}';
      notifyListeners();
      return false;
    } on TimeoutException {
      error = 'Message timed out — server may not have received it';
      notifyListeners();
      return false;
    } on StateError catch (e) {
      // Channel was closed (e.g. socket.disconnect() was called).
      error = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Fire-and-forget — tell the server the user is typing.
  void sendTyping() {
    // .ignore() suppresses the Future error so it doesn't become an
    // unhandled exception if the push fails (network drop, etc.)
    _channel.push('typing', {}).ignore();
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _channel.leave().ignore(); // best-effort; don't await in dispose
    super.dispose();
  }
}

class ChatMessage {
  final String user;
  final String body;
  ChatMessage({required this.user, required this.body});
}

// ---------------------------------------------------------------------------
// Chat screen
// ---------------------------------------------------------------------------

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notifier = ChangeNotifierProvider.of<ChatRoomNotifier>(context);
    final socket = ChangeNotifierProvider.of<PhoenixSocketManager>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('room:lobby'),
        actions: [
          // Show reconnection state in the app bar
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _SocketStateBadge(state: socket.socketState),
          ),
        ],
      ),
      body: Column(
        children: [
          // Error banner
          if (notifier.error != null)
            MaterialBanner(
              content: Text(notifier.error!),
              actions: [
                TextButton(
                  onPressed: () {
                    notifier.error = null;
                    notifier.notifyListeners();
                  },
                  child: const Text('Dismiss'),
                ),
              ],
            ),

          // Message list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: notifier.messages.length,
              itemBuilder: (_, i) {
                final msg = notifier.messages[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('[${msg.user}] ${msg.body}'),
                );
              },
            ),
          ),

          // Input row
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    onChanged: (_) => notifier.sendTyping(),
                    decoration:
                        const InputDecoration(hintText: 'Type a message…'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: notifier.joined
                      ? () async {
                          final text = _controller.text.trim();
                          if (text.isEmpty) return;
                          _controller.clear();
                          await notifier.sendMessage(text);
                        }
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SocketStateBadge extends StatelessWidget {
  final PhoenixSocketState state;
  const _SocketStateBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      PhoenixSocketState.connected => ('connected', Colors.green),
      PhoenixSocketState.connecting => ('connecting…', Colors.orange),
      PhoenixSocketState.reconnecting => ('reconnecting…', Colors.orange),
      PhoenixSocketState.disconnected => ('offline', Colors.red),
    };
    return Chip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      backgroundColor: color.withOpacity(0.15),
      side: BorderSide(color: color),
    );
  }
}
