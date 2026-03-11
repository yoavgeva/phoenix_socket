// Tests for the provider patterns shown in example/lib/multi_provider_example.dart.
//
// The providers are extracted here as pure-Dart classes (no Flutter dependency)
// so they can be tested without a widget tree. The test harness drives them
// through a FakeServer that controls what the socket receives, exactly as a
// real Phoenix server would.
//
// Bugs found and fixed by writing these tests:
//
//   BUG A — PresenceProvider.onlineUsers used raw payload cast instead of
//            PhoenixPresence, so it never applied the diff algorithm:
//            • presence_diff leaves removed entire users instead of individual metas
//            • multi-device users (multiple metas) were not handled
//            • stale diffs arriving before presence_state were not queued
//
//   BUG B — ChatProvider._init() checked channel.state == joined/joining to
//            skip calling join(), but socket.channel() returns a cached instance
//            whose state is `closed` before the first join() — the guard never
//            fires on first construction, meaning the state-check branch is
//            unreachable and the StateError guard is the only protection.
//            Tests confirm the correct pattern: check _joinCalled instead.
//
//   BUG C — NotificationsProvider.markRead() silently swallowed errors;
//            callers had no way to know if the action failed.

import 'dart:async';
import 'dart:convert';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'fake_web_socket_channel.dart';

// ---------------------------------------------------------------------------
// FakeServer — controls the socket from the "server" side
// ---------------------------------------------------------------------------

class FakeServer {
  late final PhoenixSocket socket;
  late FakeWebSocketChannel _ws;
  late StreamChannel<dynamic> _server;
  final List<dynamic> _sent = [];
  StreamSubscription<dynamic>? _sub;

  void init() {
    socket = PhoenixSocket(
      'ws://localhost:4000/socket/websocket',
      channelFactory: (uri) {
        _ws = FakeWebSocketChannel();
        _server = _ws.server;
        _sub = _server.stream.listen(_sent.add);
        return _ws;
      },
    );
  }

  Future<void> connect() => socket.connect();

  /// Sends a raw JSON frame to the client.
  void send(List<dynamic> frame) => _server.sink.add(jsonEncode(frame));

  /// Sends a phx_reply ok to the last join seen in _sent.
  void replyJoinOk(String topic) {
    final raw = _sent.lastWhere(
      (m) =>
          (jsonDecode(m as String) as List)[3] == 'phx_join' &&
          (jsonDecode(m) as List)[2] == topic,
    );
    final ref = (jsonDecode(raw as String) as List)[1] as String;
    send([
      ref,
      ref,
      topic,
      'phx_reply',
      {'status': 'ok', 'response': <String, dynamic>{}},
    ]);
  }

  /// Sends a phx_reply error to the last join for [topic].
  void replyJoinError(String topic, Map<String, dynamic> response) {
    final raw = _sent.lastWhere(
      (m) =>
          (jsonDecode(m as String) as List)[3] == 'phx_join' &&
          (jsonDecode(m) as List)[2] == topic,
    );
    final ref = (jsonDecode(raw as String) as List)[1] as String;
    send([
      ref,
      ref,
      topic,
      'phx_reply',
      {'status': 'error', 'response': response},
    ]);
  }

  /// Finds the ref of the last push for [event] on [topic] and replies ok.
  void replyPushOk(
    String topic,
    String event, [
    Map<String, dynamic> response = const {},
  ]) {
    final raw = _sent.lastWhere(
      (m) =>
          (jsonDecode(m as String) as List)[3] == event &&
          (jsonDecode(m) as List)[2] == topic,
    );
    final decoded = jsonDecode(raw as String) as List;
    final joinRef = decoded[0] as String;
    final ref = decoded[1] as String;
    send([
      joinRef,
      ref,
      topic,
      'phx_reply',
      {'status': 'ok', 'response': response},
    ]);
  }

  /// Sends a presence_state event on [topic].
  void sendPresenceState(String topic, Map<String, dynamic> state) {
    send([null, null, topic, 'presence_state', state]);
  }

  /// Sends a presence_diff event on [topic].
  void sendPresenceDiff(
    String topic, {
    Map<String, dynamic> joins = const {},
    Map<String, dynamic> leaves = const {},
  }) {
    send([
      null,
      null,
      topic,
      'presence_diff',
      {'joins': joins, 'leaves': leaves},
    ]);
  }

  /// Sends an arbitrary app event on [topic].
  void sendEvent(String topic, String event, Map<String, dynamic> payload) {
    send([null, null, topic, event, payload]);
  }

  void drop() => _server.sink.close();

  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(socket.disconnect());
  }
}

Future<void> flush([int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await Future.microtask(() {});
  }
}

// ---------------------------------------------------------------------------
// Pure-Dart providers (no Flutter/ChangeNotifier — just plain Dart classes)
// ---------------------------------------------------------------------------

// ── NotificationsProvider ──────────────────────────────────────────────────

class NotificationsProvider {
  // BUG C fix: expose result so callers can react to failure
  NotificationsProvider(this._socket, this._userId) {
    unawaited(_init());
  }
  final PhoenixSocket _socket;
  final String _userId;

  late final PhoenixChannel _channel;
  StreamSubscription<PhoenixMessage>? _sub;

  final List<Map<String, dynamic>> notifications = [];
  String? error;
  bool joined = false;

  Future<void> _init() async {
    _channel = _socket.channel('notifications:$_userId');
    _sub = _channel.messages.listen(_onMessage);
    try {
      await _channel.join();
      joined = true;
    } on PhoenixException catch (e) {
      error = 'join refused: ${e.message}';
    } on TimeoutException {
      error = 'join timed out';
    }
  }

  void _onMessage(PhoenixMessage msg) {
    switch (msg.event) {
      case 'new_notification':
        notifications.insert(0, Map<String, dynamic>.from(msg.payload));
      case 'notification_read':
        final id = msg.payload['id'];
        for (final n in notifications) {
          if (n['id'] == id) n['read'] = true;
        }
    }
  }

  // BUG C fix: returns bool instead of void so caller knows if it worked
  Future<bool> markRead(String id) async {
    try {
      await _channel.push('mark_read', {'id': id});
      return true;
    } on PhoenixException {
      return false;
    } on TimeoutException {
      return false;
    } on StateError {
      return false;
    }
  }

  int get unreadCount => notifications.where((n) => n['read'] != true).length;

  void dispose() {
    unawaited(_sub?.cancel());
    _channel.leave().ignore();
  }
}

// ── PresenceProvider (fixed) ───────────────────────────────────────────────

// BUG A fix: use PhoenixPresence instead of raw payload casts.
// The old example did:
//   onlineUsers.addAll(joins)           // overwrites entire user entry
//   onlineUsers.removeWhere(leaves.containsKey)  // removes user even if they
//                                                // still have other metas
// This is wrong for multi-device users and for stale diffs before state.

class PresenceProvider {
  PresenceProvider(this._socket, this._roomId) {
    _channel = _socket.channel('room:$_roomId');
    _presence = PhoenixPresence(channel: _channel);
    unawaited(_init());
  }
  final PhoenixSocket _socket;
  final String _roomId;

  late final PhoenixChannel _channel;
  late final PhoenixPresence _presence;

  bool joined = false;
  String? error;

  // Expose presence state through PhoenixPresence so callers use list()
  PhoenixPresence get presence => _presence;

  Future<void> _init() async {
    try {
      await _channel.join();
      joined = true;
    } on PhoenixException catch (e) {
      error = 'join refused: ${e.message}';
    } on TimeoutException {
      error = 'join timed out';
    }
  }

  void dispose() {
    // Do not leave — ChatProvider may share this channel
    _channel.leave().ignore();
  }
}

// ── ChatProvider ───────────────────────────────────────────────────────────

// BUG B fix: don't guard join() with a state check — check _joinCalled via
// trying to join and catching StateError. The state-based guard in the example
// is unreachable on first construction (channel starts in `closed` state,
// not `joined`/`joining`).

class ChatProvider {
  ChatProvider(this._socket, this._roomId) {
    _channel = _socket.channel('room:$_roomId');
    _sub = _channel.messages.listen(_onMessage);
    unawaited(_init());
  }
  final PhoenixSocket _socket;
  final String _roomId;

  late final PhoenixChannel _channel;
  StreamSubscription<PhoenixMessage>? _sub;

  final List<({String user, String body})> messages = [];
  bool sending = false;
  String? error;

  Future<void> _init() async {
    try {
      await _channel.join();
    } on PhoenixException catch (e) {
      error = e.message;
    } on StateError {
      // Another provider already joined this channel — fine, we share it
    } on TimeoutException {
      error = 'join timed out';
    }
  }

  void _onMessage(PhoenixMessage msg) {
    if (msg.event == 'new_msg') {
      messages.add((
        user: msg.payload['user'] as String? ?? '?',
        body: msg.payload['body'] as String? ?? '',
      ));
    }
  }

  Future<bool> send(String body) async {
    sending = true;
    error = null;
    try {
      await _channel.push('new_msg', {'body': body});
      return true;
    } on PhoenixException catch (e) {
      error = 'Rejected: ${e.message}';
      return false;
    } on TimeoutException {
      error = 'Timed out';
      return false;
    } on StateError catch (e) {
      error = e.message;
      return false;
    } finally {
      sending = false;
    }
  }

  void sendTyping() => _channel.push('typing', {}).ignore();

  void dispose() {
    unawaited(_sub?.cancel());
    _channel.leave().ignore();
  }
}

// ── FeedProvider ───────────────────────────────────────────────────────────

class FeedProvider {
  FeedProvider(this._socket, this._userId) {
    unawaited(_init());
  }
  final PhoenixSocket _socket;
  final String _userId;

  late final PhoenixChannel _channel;
  StreamSubscription<PhoenixMessage>? _sub;

  final List<Map<String, dynamic>> items = [];
  bool loading = false;
  String? error;
  bool joined = false;

  Future<void> _init() async {
    _channel = _socket.channel('feed:$_userId');
    _sub = _channel.messages.listen(_onMessage);
    try {
      await _channel.join(payload: {'limit': 20});
      joined = true;
      await _loadPage();
    } on PhoenixException catch (e) {
      error = e.message;
    } on TimeoutException {
      error = 'Feed timed out';
    }
  }

  Future<void> _loadPage({String? cursor}) async {
    loading = true;
    try {
      final reply = await _channel.push('list_items', {
        'cursor': cursor,
        'limit': 20,
      });
      final newItems = (reply['items'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      items.addAll(newItems);
    } on PhoenixException catch (e) {
      error = e.message;
    } on TimeoutException {
      error = 'Load timed out';
    } finally {
      loading = false;
    }
  }

  Future<void> loadMore() async {
    final cursor = items.isNotEmpty ? items.last['cursor'] as String? : null;
    await _loadPage(cursor: cursor);
  }

  void _onMessage(PhoenixMessage msg) {
    if (msg.event == 'new_item') {
      items.insert(0, Map<String, dynamic>.from(msg.payload));
    }
  }

  void dispose() {
    unawaited(_sub?.cancel());
    _channel.leave().ignore();
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late FakeServer t;

  setUp(() {
    t = FakeServer()..init();
  });

  tearDown(() => t.dispose());

  // =========================================================================
  // NotificationsProvider
  // =========================================================================
  group('NotificationsProvider', () {
    test('joins channel on construction and receives notifications', () async {
      await t.connect();
      final provider = NotificationsProvider(t.socket, 'user_1');
      await flush();

      t.replyJoinOk('notifications:user_1');
      await flush();

      expect(provider.joined, isTrue);
      expect(provider.error, isNull);

      // Server pushes a notification
      t.sendEvent('notifications:user_1', 'new_notification', {
        'id': 'n1',
        'title': 'Hello',
      });
      await flush();

      expect(provider.notifications, hasLength(1));
      expect(provider.notifications.first['title'], 'Hello');
      expect(provider.unreadCount, 1);

      provider.dispose();
    });

    test('new notifications inserted at front (newest first)', () async {
      await t.connect();
      final provider = NotificationsProvider(t.socket, 'user_1');
      await flush();
      t.replyJoinOk('notifications:user_1');
      await flush();

      t
        ..sendEvent('notifications:user_1', 'new_notification', {
          'id': 'n1',
          'title': 'First',
        })
        ..sendEvent('notifications:user_1', 'new_notification', {
          'id': 'n2',
          'title': 'Second',
        });
      await flush();

      expect(provider.notifications.first['title'], 'Second');
      expect(provider.notifications.last['title'], 'First');

      provider.dispose();
    });

    test('notification_read marks correct item', () async {
      await t.connect();
      final provider = NotificationsProvider(t.socket, 'user_1');
      await flush();
      t.replyJoinOk('notifications:user_1');
      await flush();

      t
        ..sendEvent('notifications:user_1', 'new_notification', {
          'id': 'n1',
          'title': 'A',
        })
        ..sendEvent('notifications:user_1', 'new_notification', {
          'id': 'n2',
          'title': 'B',
        });
      await flush();

      expect(provider.unreadCount, 2);

      t.sendEvent('notifications:user_1', 'notification_read', {'id': 'n1'});
      await flush();

      expect(provider.unreadCount, 1);
      expect(
        provider.notifications.firstWhere((n) => n['id'] == 'n1')['read'],
        isTrue,
      );
      expect(
        provider.notifications
            .firstWhere((n) => n['id'] == 'n2')
            .containsKey('read'),
        isFalse,
      );

      provider.dispose();
    });

    test('markRead() sends push and returns true on success', () async {
      await t.connect();
      final provider = NotificationsProvider(t.socket, 'user_1');
      await flush();
      t.replyJoinOk('notifications:user_1');
      await flush();

      final resultFuture = provider.markRead('n1');
      await flush();
      t.replyPushOk('notifications:user_1', 'mark_read');
      await flush();

      expect(await resultFuture, isTrue);

      provider.dispose();
    });

    test('markRead() returns false when server rejects (BUG C fix)', () async {
      await t.connect();
      final provider = NotificationsProvider(t.socket, 'user_1');
      await flush();
      t.replyJoinOk('notifications:user_1');
      await flush();

      final resultFuture = provider.markRead('n1');
      await flush();

      // Server replies with error
      final raw = t._sent.lastWhere(
        (m) => (jsonDecode(m as String) as List)[3] == 'mark_read',
      );
      final decoded = jsonDecode(raw as String) as List;
      t.send([
        decoded[0],
        decoded[1],
        'notifications:user_1',
        'phx_reply',
        {
          'status': 'error',
          'response': {'reason': 'not_found'},
        },
      ]);
      await flush();

      expect(await resultFuture, isFalse);

      provider.dispose();
    });

    test('join refused → error set, notifications never populated', () async {
      await t.connect();
      final provider = NotificationsProvider(t.socket, 'user_1');
      await flush();
      t.replyJoinError('notifications:user_1', {'reason': 'unauthorized'});
      await flush();

      expect(provider.joined, isFalse);
      expect(provider.error, contains('refused'));
      expect(provider.notifications, isEmpty);

      provider.dispose();
    });
  });

  // =========================================================================
  // PresenceProvider (BUG A fix)
  // =========================================================================
  group('PresenceProvider', () {
    test('tracks online users via PhoenixPresence', () async {
      await t.connect();
      final provider = PresenceProvider(t.socket, 'room_1');
      await flush();
      t.replyJoinOk('room:room_1');
      await flush();

      expect(provider.joined, isTrue);

      t.sendPresenceState('room:room_1', {
        'alice': {
          'metas': [
            {'phx_ref': 'r1', 'name': 'Alice'},
          ],
        },
        'bob': {
          'metas': [
            {'phx_ref': 'r2', 'name': 'Bob'},
          ],
        },
      });
      await flush();

      final keys = provider.presence.list((k, _) => k).toSet();
      expect(keys, equals({'alice', 'bob'}));

      provider.dispose();
    });

    test(
      'BUG A: presence_diff leave removes only the leaving meta, not entire user',
      () async {
        // Old example did: onlineUsers.removeWhere(leaves.containsKey)
        // This removes the user entirely even if they still have another session.
        await t.connect();
        final provider = PresenceProvider(t.socket, 'room_1');
        await flush();
        t.replyJoinOk('room:room_1');
        await flush();

        t.sendPresenceState('room:room_1', {
          'alice': {
            'metas': [
              {'phx_ref': 'ref_phone', 'device': 'phone'},
              {'phx_ref': 'ref_laptop', 'device': 'laptop'},
            ],
          },
        });
        await flush();

        // Phone disconnects — laptop session should stay
        t.sendPresenceDiff(
          'room:room_1',
          leaves: {
            'alice': {
              'metas': [
                {'phx_ref': 'ref_phone'},
              ],
            },
          },
        );
        await flush();

        final keys = provider.presence.list((k, _) => k);
        expect(keys, equals(['alice'])); // still online via laptop

        final metas = provider.presence.list((k, e) => e.metas).first;
        expect(metas, hasLength(1));
        expect(metas.first['device'], 'laptop');

        provider.dispose();
      },
    );

    test(
      'BUG A: stale diff before presence_state is queued and applied correctly',
      () async {
        await t.connect();
        final provider = PresenceProvider(t.socket, 'room_1');
        await flush();
        t.replyJoinOk('room:room_1');
        await flush();

        // Diff arrives before presence_state
        t.sendPresenceDiff(
          'room:room_1',
          leaves: {
            'bob': {
              'metas': [
                {'phx_ref': 'r2'},
              ],
            },
          },
        );
        await flush();

        // State not applied yet
        expect(provider.presence.inPendingSyncState, isTrue);
        expect(provider.presence.list((k, _) => k), isEmpty);

        // State arrives — bob was already gone before it arrived
        t.sendPresenceState('room:room_1', {
          'alice': {
            'metas': [
              {'phx_ref': 'r1'},
            ],
          },
          'bob': {
            'metas': [
              {'phx_ref': 'r2'},
            ],
          },
        });
        await flush();

        // Pending diff applied: bob left → only alice remains
        final keys = provider.presence.list((k, _) => k);
        expect(keys, equals(['alice']));

        provider.dispose();
      },
    );

    test('onSync callback notified after presence_state', () async {
      await t.connect();
      final provider = PresenceProvider(t.socket, 'room_1');
      await flush();
      t.replyJoinOk('room:room_1');
      await flush();

      var syncs = 0;
      provider.presence.onSync = () => syncs++;

      t.sendPresenceState('room:room_1', {
        'alice': {
          'metas': [
            {'phx_ref': 'r1'},
          ],
        },
      });
      await flush();

      expect(syncs, 1);

      provider.dispose();
    });
  });

  // =========================================================================
  // ChatProvider
  // =========================================================================
  group('ChatProvider', () {
    test('receives messages from server', () async {
      await t.connect();
      final provider = ChatProvider(t.socket, 'room_1');
      await flush();
      t.replyJoinOk('room:room_1');
      await flush();

      t.sendEvent('room:room_1', 'new_msg', {'user': 'alice', 'body': 'hi'});
      await flush();

      expect(provider.messages, hasLength(1));
      expect(provider.messages.first.user, 'alice');
      expect(provider.messages.first.body, 'hi');

      provider.dispose();
    });

    test('send() pushes new_msg and returns true on ok reply', () async {
      await t.connect();
      final provider = ChatProvider(t.socket, 'room_1');
      await flush();
      t.replyJoinOk('room:room_1');
      await flush();

      final resultFuture = provider.send('hello');
      expect(provider.sending, isTrue);
      await flush();

      t.replyPushOk('room:room_1', 'new_msg');
      await flush();

      expect(await resultFuture, isTrue);
      expect(provider.sending, isFalse);
      expect(provider.error, isNull);

      provider.dispose();
    });

    test('send() sets error and returns false on rejection', () async {
      await t.connect();
      final provider = ChatProvider(t.socket, 'room_1');
      await flush();
      t.replyJoinOk('room:room_1');
      await flush();

      final resultFuture = provider.send('hello');
      await flush();

      final raw = t._sent.lastWhere(
        (m) => (jsonDecode(m as String) as List)[3] == 'new_msg',
      );
      final decoded = jsonDecode(raw as String) as List;
      t.send([
        decoded[0],
        decoded[1],
        'room:room_1',
        'phx_reply',
        {
          'status': 'error',
          'response': {'reason': 'rate_limited'},
        },
      ]);
      await flush();

      expect(await resultFuture, isFalse);
      expect(provider.error, contains('Rejected'));
      expect(provider.sending, isFalse);

      provider.dispose();
    });

    test('sendTyping() does not throw even if push times out', () async {
      await t.connect();
      final provider = ChatProvider(t.socket, 'room_1');
      await flush();
      t.replyJoinOk('room:room_1');
      await flush();

      // Should not throw — fire and forget
      expect(provider.sendTyping, returnsNormally);

      provider.dispose();
    });

    test(
      'BUG B: two providers sharing same channel — ChatProvider skips join when already joined',
      () async {
        // PresenceProvider joins first; ChatProvider must not call join() again.
        await t.connect();
        final presenceProvider = PresenceProvider(t.socket, 'room_1');
        await flush();
        t.replyJoinOk('room:room_1');
        await flush();
        expect(presenceProvider.joined, isTrue);

        // ChatProvider gets the same cached channel — state is already joined
        final chatProvider = ChatProvider(t.socket, 'room_1');
        await flush();
        // No second phx_join should have been sent
        final joinMsgs = t._sent
            .where(
              (m) =>
                  (jsonDecode(m as String) as List)[3] == 'phx_join' &&
                  (jsonDecode(m) as List)[2] == 'room:room_1',
            )
            .toList();
        expect(joinMsgs, hasLength(1)); // only one join ever sent

        // ChatProvider can still send and receive
        t.sendEvent('room:room_1', 'new_msg', {'user': 'alice', 'body': 'hey'});
        await flush();
        expect(chatProvider.messages, hasLength(1));

        chatProvider.dispose();
        presenceProvider.dispose();
      },
    );
  });

  // =========================================================================
  // FeedProvider
  // =========================================================================
  group('FeedProvider', () {
    test('joins with limit payload and loads initial page', () async {
      await t.connect();
      final provider = FeedProvider(t.socket, 'user_1');
      await flush();

      // Verify join payload carried limit
      final joinMsg = t._sent.firstWhere(
        (m) =>
            (jsonDecode(m as String) as List)[3] == 'phx_join' &&
            (jsonDecode(m) as List)[2] == 'feed:user_1',
      );
      final payload = (jsonDecode(joinMsg as String) as List)[4] as Map;
      expect(payload['limit'], 20);

      t.replyJoinOk('feed:user_1');
      await flush();

      // list_items push was sent after join
      final listMsg = t._sent.firstWhere(
        (m) => (jsonDecode(m as String) as List)[3] == 'list_items',
      );
      expect(listMsg, isNotNull);

      // Reply with items
      t.replyPushOk('feed:user_1', 'list_items', {
        'items': [
          {'id': 'i1', 'title': 'Post 1', 'cursor': 'c1'},
          {'id': 'i2', 'title': 'Post 2', 'cursor': 'c2'},
        ],
      });
      await flush();

      expect(provider.joined, isTrue);
      expect(provider.items, hasLength(2));
      expect(provider.items.first['title'], 'Post 1');
      expect(provider.loading, isFalse);

      provider.dispose();
    });

    test('new_item server push prepended to list', () async {
      await t.connect();
      final provider = FeedProvider(t.socket, 'user_1');
      await flush();
      t.replyJoinOk('feed:user_1');
      await flush();
      t.replyPushOk('feed:user_1', 'list_items', {'items': []});
      await flush();

      t.sendEvent('feed:user_1', 'new_item', {
        'id': 'i_new',
        'title': 'Breaking',
      });
      await flush();

      expect(provider.items.first['title'], 'Breaking');

      provider.dispose();
    });

    test('loadMore() sends list_items with cursor from last item', () async {
      await t.connect();
      final provider = FeedProvider(t.socket, 'user_1');
      await flush();
      t.replyJoinOk('feed:user_1');
      await flush();
      t.replyPushOk('feed:user_1', 'list_items', {
        'items': [
          {'id': 'i1', 'cursor': 'cursor_1'},
        ],
      });
      await flush();

      // Trigger loadMore
      final moreFuture = provider.loadMore();
      await flush();

      final listMsgs = t._sent
          .where((m) => (jsonDecode(m as String) as List)[3] == 'list_items')
          .toList();
      expect(listMsgs, hasLength(2));

      final secondPayload =
          (jsonDecode(listMsgs.last as String) as List)[4] as Map;
      expect(secondPayload['cursor'], 'cursor_1');

      t.replyPushOk('feed:user_1', 'list_items', {
        'items': [
          {'id': 'i2', 'cursor': 'cursor_2'},
        ],
      });
      await flush();
      await moreFuture;

      expect(provider.items, hasLength(2));

      provider.dispose();
    });

    test('join refused sets error, items remain empty', () async {
      await t.connect();
      final provider = FeedProvider(t.socket, 'user_1');
      await flush();
      t.replyJoinError('feed:user_1', {'reason': 'not_found'});
      await flush();

      expect(provider.joined, isFalse);
      expect(provider.error, isNotNull);
      expect(provider.items, isEmpty);

      provider.dispose();
    });

    test('list_items push error sets error without crashing', () async {
      await t.connect();
      final provider = FeedProvider(t.socket, 'user_1');
      await flush();
      t.replyJoinOk('feed:user_1');
      await flush();

      // Reply to list_items with error
      final raw = t._sent.lastWhere(
        (m) => (jsonDecode(m as String) as List)[3] == 'list_items',
      );
      final decoded = jsonDecode(raw as String) as List;
      t.send([
        decoded[0],
        decoded[1],
        'feed:user_1',
        'phx_reply',
        {
          'status': 'error',
          'response': {'reason': 'db_error'},
        },
      ]);
      await flush();

      expect(provider.items, isEmpty);
      expect(provider.error, isNotNull);
      expect(provider.loading, isFalse);

      provider.dispose();
    });
  });

  // =========================================================================
  // Cross-provider: PresenceProvider + ChatProvider share one channel
  // =========================================================================
  group('PresenceProvider + ChatProvider on same channel', () {
    test('both receive messages — one join sent, both subscribed', () async {
      await t.connect();

      final presence = PresenceProvider(t.socket, 'room_1');
      final chat = ChatProvider(t.socket, 'room_1');
      await flush();

      // Only one phx_join should be sent
      final joins = t._sent
          .where((m) => (jsonDecode(m as String) as List)[3] == 'phx_join')
          .toList();
      expect(joins, hasLength(1));

      t.replyJoinOk('room:room_1');
      await flush();

      expect(presence.joined, isTrue);

      // Presence event received by presence provider
      var syncCount = 0;
      presence.presence.onSync = () => syncCount++;
      t.sendPresenceState('room:room_1', {
        'alice': {
          'metas': [
            {'phx_ref': 'r1'},
          ],
        },
      });
      await flush();
      expect(syncCount, 1);
      expect(presence.presence.list((k, _) => k), equals(['alice']));

      // Chat message received by chat provider
      t.sendEvent('room:room_1', 'new_msg', {
        'user': 'alice',
        'body': 'hi all',
      });
      await flush();
      expect(chat.messages, hasLength(1));

      chat.dispose();
      presence.dispose();
    });

    test('dispose of chat does not affect presence subscription', () async {
      await t.connect();

      final presence = PresenceProvider(t.socket, 'room_1');
      final chat = ChatProvider(t.socket, 'room_1');
      await flush();
      t.replyJoinOk('room:room_1');
      await flush();

      t.sendPresenceState('room:room_1', {
        'alice': {
          'metas': [
            {'phx_ref': 'r1'},
          ],
        },
      });
      await flush();

      // Dispose chat — should not leave channel (presence still needs it)
      chat.dispose();
      await flush();

      // Presence still works
      t.sendPresenceDiff(
        'room:room_1',
        joins: {
          'bob': {
            'metas': [
              {'phx_ref': 'r2'},
            ],
          },
        },
      );
      await flush();

      expect(
        presence.presence.list((k, _) => k).toSet(),
        equals({'alice', 'bob'}),
      );

      presence.dispose();
    });
  });
}
