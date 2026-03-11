/// Multi-provider example: several ChangeNotifiers sharing one PhoenixSocket.
///
/// Demonstrates:
///   - NotificationsProvider  — user:$uid          (server-push only)
///   - PresenceProvider       — room:$id            (tracks who is online)
///   - FeedProvider           — feed:$userId        (paginated, push-updated)
///   - ChatProvider           — room:$id            (bidirectional, same channel as presence)
///
/// All four read from the single PhoenixSocketManager in the tree.
/// None of them own the socket — they only call manager.channel(topic).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:dark_phoenix_socket/dark_phoenix_socket.dart';

import 'main.dart' show PhoenixSocketManager, ChangeNotifierProvider;

// ============================================================
// 1. NotificationsProvider
//    Topic: "notifications:{userId}"
//    Joins once on login, stays alive for the whole session.
//    Only receives — never pushes.
// ============================================================

class NotificationsProvider extends ChangeNotifier {
  final PhoenixSocketManager _manager;
  final String _userId;

  late final PhoenixChannel _channel;
  StreamSubscription<PhoenixMessage>? _sub;

  final List<Map<String, dynamic>> notifications = [];
  int get unreadCount => notifications.where((n) => n['read'] != true).length;

  NotificationsProvider(this._manager, this._userId) {
    _init();
  }

  Future<void> _init() async {
    _channel = _manager.channel('notifications:$_userId');
    _sub = _channel.messages.listen(_onMessage);

    try {
      await _channel.join();
    } on PhoenixException {
      // auth failure — nothing to do, channel will stay errored
    } on TimeoutException {
      // will auto-rejoin after reconnect
    }
  }

  void _onMessage(PhoenixMessage msg) {
    switch (msg.event) {
      case 'new_notification':
        notifications.insert(0, Map<String, dynamic>.from(msg.payload));
        notifyListeners();
      case 'notification_read':
        final id = msg.payload['id'];
        for (final n in notifications) {
          if (n['id'] == id) n['read'] = true;
        }
        notifyListeners();
    }
  }

  Future<void> markRead(String id) async {
    try {
      await _channel.push('mark_read', {'id': id});
    } on PhoenixException catch (e) {
      debugPrint('mark_read rejected: ${e.message}');
    } on TimeoutException {
      debugPrint('mark_read timed out');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _channel.leave().ignore();
    super.dispose();
  }
}

// ============================================================
// 2. PresenceProvider
//    Topic: "room:{roomId}"
//    Tracks who is online via phx_presence_diff events.
//    Scoped to a screen — disposed when user leaves.
// ============================================================

class PresenceProvider extends ChangeNotifier {
  final PhoenixSocketManager _manager;
  final String _roomId;

  late final PhoenixChannel _channel;
  StreamSubscription<PhoenixMessage>? _sub;

  final Map<String, Map<String, dynamic>> onlineUsers = {};
  bool joined = false;

  PresenceProvider(this._manager, this._roomId) {
    _init();
  }

  Future<void> _init() async {
    // Reuse the same channel as ChatProvider for the same room —
    // socket.channel() returns the cached instance.
    _channel = _manager.channel('room:$_roomId');
    _sub = _channel.messages.listen(_onMessage);

    try {
      await _channel.join();
      joined = true;
      notifyListeners();
    } on PhoenixException catch (e) {
      debugPrint('presence join refused: ${e.message}');
    } on TimeoutException {
      debugPrint('presence join timed out');
    }
  }

  void _onMessage(PhoenixMessage msg) {
    switch (msg.event) {
      case 'presence_state':
        // Initial snapshot: payload is {userId: {metas: [...]}}
        onlineUsers
          ..clear()
          ..addAll(msg.payload.cast<String, Map<String, dynamic>>());
        notifyListeners();
      case 'presence_diff':
        final joins = (msg.payload['joins'] as Map?)
                ?.cast<String, Map<String, dynamic>>() ??
            {};
        final leaves = (msg.payload['leaves'] as Map?)
                ?.cast<String, Map<String, dynamic>>() ??
            {};
        onlineUsers
          ..addAll(joins)
          ..removeWhere((k, _) => leaves.containsKey(k));
        notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    // Do NOT leave the channel here — ChatProvider may still be using it.
    // Whoever joins last is responsible for leaving.
    super.dispose();
  }
}

// ============================================================
// 3. ChatProvider
//    Topic: "room:{roomId}"   ← same channel as PresenceProvider
//    Bidirectional: receives messages, pushes new_msg.
//    Scoped to the chat screen.
// ============================================================

class ChatProvider extends ChangeNotifier {
  final PhoenixSocketManager _manager;
  final String _roomId;

  late final PhoenixChannel _channel;
  StreamSubscription<PhoenixMessage>? _sub;

  final List<ChatMessage> messages = [];
  bool sending = false;
  String? error;

  ChatProvider(this._manager, this._roomId) {
    _init();
  }

  Future<void> _init() async {
    // socket.channel() is cached — same instance PresenceProvider got.
    _channel = _manager.channel('room:$_roomId');
    _sub = _channel.messages.listen(_onMessage);

    // join() is idempotent on the same instance — if PresenceProvider already
    // joined this channel, the second join() call throws StateError.
    // Guard with a state check:
    if (_channel.state == PhoenixChannelState.joined ||
        _channel.state == PhoenixChannelState.joining) {
      return;
    }

    try {
      await _channel.join();
    } on PhoenixException catch (e) {
      error = e.message;
      notifyListeners();
    } on StateError {
      // Already joining from another provider — fine
    }
  }

  void _onMessage(PhoenixMessage msg) {
    if (msg.event == 'new_msg') {
      messages.add(ChatMessage(
        user: msg.payload['user'] as String? ?? '?',
        body: msg.payload['body'] as String? ?? '',
      ));
      notifyListeners();
    }
  }

  Future<void> send(String body) async {
    sending = true;
    error = null;
    notifyListeners();

    try {
      await _channel.push('new_msg', {'body': body});
    } on PhoenixException catch (e) {
      error = 'Rejected: ${e.message}';
    } on TimeoutException {
      error = 'Timed out';
    } on StateError catch (e) {
      error = e.message;
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  void sendTyping() => _channel.push('typing', {}).ignore();

  @override
  void dispose() {
    _sub?.cancel();
    _channel.leave().ignore();
    super.dispose();
  }
}

class ChatMessage {
  final String user;
  final String body;
  ChatMessage({required this.user, required this.body});
}

// ============================================================
// 4. FeedProvider
//    Topic: "feed:{userId}"
//    Loads initial page via push-with-reply, then receives
//    server-pushed updates when new items arrive.
// ============================================================

class FeedProvider extends ChangeNotifier {
  final PhoenixSocketManager _manager;
  final String _userId;

  late final PhoenixChannel _channel;
  StreamSubscription<PhoenixMessage>? _sub;

  final List<Map<String, dynamic>> items = [];
  bool loading = false;
  String? error;

  FeedProvider(this._manager, this._userId) {
    _init();
  }

  Future<void> _init() async {
    _channel = _manager.channel('feed:$_userId');
    _sub = _channel.messages.listen(_onMessage);

    try {
      // Join payload can carry pagination cursor or filter params
      await _channel.join({'limit': 20});
      await _loadPage();
    } on PhoenixException catch (e) {
      error = e.message;
      notifyListeners();
    } on TimeoutException {
      error = 'Feed timed out';
      notifyListeners();
    }
  }

  Future<void> _loadPage({String? cursor}) async {
    loading = true;
    notifyListeners();
    try {
      final reply = await _channel.push('list_items', {
        'cursor': cursor,
        'limit': 20,
      });
      final newItems =
          (reply['items'] as List? ?? []).cast<Map<String, dynamic>>();
      items.addAll(newItems);
    } on PhoenixException catch (e) {
      error = e.message;
    } on TimeoutException {
      error = 'Load timed out';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    final cursor = items.isNotEmpty ? items.last['cursor'] as String? : null;
    await _loadPage(cursor: cursor);
  }

  void _onMessage(PhoenixMessage msg) {
    if (msg.event == 'new_item') {
      items.insert(0, Map<String, dynamic>.from(msg.payload));
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _channel.leave().ignore();
    super.dispose();
  }
}

// ============================================================
// Wiring — how to set up the Provider tree
// ============================================================
//
// Root (lives for the whole app session):
//
//   MultiProvider(
//     providers: [
//       ChangeNotifierProvider(create: (_) => PhoenixSocketManager()),
//       // NotificationsProvider depends on the socket, so it comes after.
//       ChangeNotifierProxyProvider<PhoenixSocketManager, NotificationsProvider>(
//         create: (ctx) => NotificationsProvider(
//           ctx.read<PhoenixSocketManager>(), currentUserId),
//         update: (_, __, prev) => prev!,
//       ),
//     ],
//     child: const MyApp(),
//   )
//
// Room screen (scoped — disposed when user leaves the screen):
//
//   MultiProvider(
//     providers: [
//       ChangeNotifierProxyProvider<PhoenixSocketManager, PresenceProvider>(
//         create: (ctx) => PresenceProvider(ctx.read<PhoenixSocketManager>(), roomId),
//         update: (_, __, prev) => prev!,
//       ),
//       ChangeNotifierProxyProvider<PhoenixSocketManager, ChatProvider>(
//         create: (ctx) => ChatProvider(ctx.read<PhoenixSocketManager>(), roomId),
//         update: (_, __, prev) => prev!,
//       ),
//     ],
//     child: const ChatScreen(),
//   )
//
// Feed screen (scoped):
//
//   ChangeNotifierProxyProvider<PhoenixSocketManager, FeedProvider>(
//     create: (ctx) => FeedProvider(ctx.read<PhoenixSocketManager>(), userId),
//     update: (_, __, prev) => prev!,
//     child: const FeedScreen(),
//   )
//
// Key points:
//   - PhoenixSocketManager lives at the root — one socket for the session.
//   - Scoped providers (Chat, Presence, Feed) are created per-screen and
//     disposed when the route is popped.
//   - PresenceProvider and ChatProvider share "room:{id}" — socket.channel()
//     returns the cached PhoenixChannel instance so only one join is sent.
//   - NotificationsProvider lives at root alongside the socket so it keeps
//     receiving pushes while the user navigates between screens.

// ============================================================
// Demo widget — shows all providers in one place
// ============================================================

class RoomScreen extends StatelessWidget {
  final String roomId;
  final String userId;

  const RoomScreen({super.key, required this.roomId, required this.userId});

  @override
  Widget build(BuildContext context) {
    final socket = ChangeNotifierProvider.of<PhoenixSocketManager>(context);

    return MultiProvider(
      providers: [
        _ProxyProvider(
          create: (_) => PresenceProvider(socket, roomId),
        ),
        _ProxyProvider(
          create: (_) => ChatProvider(socket, roomId),
        ),
        _ProxyProvider(
          create: (_) => FeedProvider(socket, userId),
        ),
      ],
      child: const _RoomView(),
    );
  }
}

// Minimal scoped ChangeNotifierProvider that disposes on pop
class MultiProvider extends StatefulWidget {
  final List<_ProxyProvider> providers;
  final Widget child;
  const MultiProvider(
      {super.key, required this.providers, required this.child});

  @override
  State<MultiProvider> createState() => _MultiProviderState();
}

class _MultiProviderState extends State<MultiProvider> {
  late final List<ChangeNotifier> _notifiers;

  @override
  void initState() {
    super.initState();
    _notifiers = widget.providers.map((p) => p.create(context)).toList();
  }

  @override
  void dispose() {
    for (final n in _notifiers) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ProxyProvider<T extends ChangeNotifier> {
  final T Function(BuildContext) create;
  const _ProxyProvider({required this.create});
}

class _RoomView extends StatelessWidget {
  const _RoomView();

  @override
  Widget build(BuildContext context) {
    return const Placeholder();
  }
}
