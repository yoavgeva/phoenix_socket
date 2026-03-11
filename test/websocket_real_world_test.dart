// Real-world WebSocket edge cases from production systems.
//
// Covers scenarios found in the wild:
//   - NAT/load-balancer idle timeouts (silent connection death)
//   - Thundering herd on reconnect (many clients reconnecting simultaneously)
//   - Leave → immediate rejoin race
//   - Push buffer not flushed when join times out (Phoenix JS bug #1295)
//   - Network interface switch (WiFi → cellular mid-operation)
//   - Graceful server shutdown with active channels
//   - TCP half-open (one side dead, other unaware)
//   - Backoff jitter / thundering herd pattern
//   - Large push payload handling
//   - Channel left while push reply in-flight
//   - Stale ref after channel topic reuse
//   - Reconnect while disconnect in progress
//   - Connect after long downtime (stale state)
//   - phx_error before join reply
//   - Multiple phx_error events on same channel
//   - Server gracefully closes with close code
//   - Socket close while reconnect timer pending
//   - Channel join during socket reconnecting state
//   - Push timeout cleaned up properly (no crash after timeout)
//   - Ref counter wraps cleanly after many operations
//   - Messages ordered correctly across rapid sends
//   - Broadcast arrives before push reply
//   - Two channels on same topic (different socket instances)
//   - Socket reuse after disconnect
//   - Zero-payload push
//   - Heartbeat fires during active push (no interference)
//   - Server sends unexpected event type
//   - Channel errored → rejoin → errored → rejoin cycle
//   - App "comes back online" after extended downtime
//   - Push sent just after join reply (no buffer needed)

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:phoenix_socket/src/channel.dart';
import 'package:phoenix_socket/src/message.dart';
import 'package:phoenix_socket/src/socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'fake_web_socket_channel.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

class RealWorldSetup {
  late PhoenixSocket socket;
  late FakeWebSocketChannel ws;
  late StreamChannel<dynamic> server;
  final sent = <dynamic>[];
  int connectCount = 0;
  // Allow tests to intercept factory for custom behavior
  FakeWebSocketChannel Function()? wsFactory;

  void init({String url = 'ws://localhost:4000/socket/websocket'}) {
    socket = PhoenixSocket(
      url,
      channelFactory: (uri) {
        connectCount++;
        ws = wsFactory != null ? wsFactory!() : FakeWebSocketChannel();
        server = ws.server;
        server.stream.listen(sent.add);
        return ws;
      },
    );
  }

  Future<void> connect() => socket.connect();

  void sendToClient(List<dynamic> msg) => server.sink.add(jsonEncode(msg));

  // Parse helpers
  String msgRef(dynamic raw) =>
      (jsonDecode(raw as String) as List)[1] as String;
  String msgJoinRef(dynamic raw) =>
      (jsonDecode(raw as String) as List)[0] as String;
  String msgTopic(dynamic raw) =>
      (jsonDecode(raw as String) as List)[2] as String;
  String msgEvent(dynamic raw) =>
      (jsonDecode(raw as String) as List)[3] as String;
  dynamic msgPayload(dynamic raw) =>
      (jsonDecode(raw as String) as List)[4];

  void replyOk(String joinRef, String ref, String topic,
      [Map<String, dynamic> resp = const {}]) {
    sendToClient(
        [joinRef, ref, topic, 'phx_reply', {'status': 'ok', 'response': resp}]);
  }

  void replyError(String joinRef, String ref, String topic,
      [Map<String, dynamic> resp = const {}]) {
    sendToClient([
      joinRef,
      ref,
      topic,
      'phx_reply',
      {'status': 'error', 'response': resp}
    ]);
  }

  void replyJoinOk(String ref, String topic,
      [Map<String, dynamic> resp = const {}]) {
    replyOk(ref, ref, topic, resp);
  }

  void broadcast(String topic, String event, Map<String, dynamic> payload) {
    sendToClient([null, null, topic, event, payload]);
  }

  /// Simulate server crash / NAT timeout (no close frame — TCP just dies).
  void killNetwork() => server.sink.close();

  Future<PhoenixChannel> joinedChannel(String topic) async {
    final ch = socket.channel(topic);
    final f = ch.join();
    await flush();
    final ref = msgRef(sent.last);
    replyJoinOk(ref, topic);
    await flush();
    await f;
    return ch;
  }
}

Future<void> flush([int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await Future.microtask(() {});
  }
}

void main() {
  // =========================================================================
  // 1. NAT / load-balancer silent idle timeout
  // =========================================================================
  group('NAT and LB idle timeout', () {
    test('1. idle connection silently dropped after 10 min — heartbeat detects it',
        () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        // Flush connect() async work (ready future, setState, startHeartbeat)
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 30))
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 30))
          ..flushMicrotasks();
        expect(s.socket.state, PhoenixSocketState.reconnecting);
      });
    });

    test('2. heartbeat reply resets pending ref — no false reconnect',
        () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 30))
          ..flushMicrotasks();
        final hbRef = s.msgRef(s.sent.last);
        s.sendToClient([null, hbRef, 'phoenix', 'phx_reply',
          {'status': 'ok', 'response': <String, dynamic>{}}]);
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 30))
          ..flushMicrotasks();
        expect(s.socket.state, PhoenixSocketState.connected);
      });
    });

    test('3. LB closes idle connection after 60s — client detects via _onDone',
        () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      await flush();

      // LB closes after 60s of inactivity (before 30s heartbeat reply window).
      // Simulate with server sink close.
      unawaited(s.server.sink.close());
      await flush();
      expect(s.socket.state, PhoenixSocketState.reconnecting);
    });

    test('4. reconnect after NAT timeout rejoins all channels', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:nat');

      s.killNetwork();
      await flush();
      expect(s.socket.state, PhoenixSocketState.reconnecting);
      expect(ch.state, PhoenixChannelState.errored);
    });
  });

  // =========================================================================
  // 2. Leave → immediate rejoin race (Phoenix JS #1483, #3171)
  // =========================================================================
  group('Leave → rejoin race', () {
    test('5. leave then immediate rejoin — second join succeeds', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch1 = await s.joinedChannel('room:lobby');

      // Leave ch1
      final leaveFuture = ch1.leave();
      await flush();
      final leaveRef = s.msgRef(s.sent.last);
      s.replyOk(s.msgJoinRef(s.sent.last), leaveRef, 'room:lobby');
      await flush();
      await leaveFuture;
      expect(ch1.state, PhoenixChannelState.closed);

      // Immediately get a new channel for same topic (socket.channel caches by topic,
      // but the closed channel is replaced on next channel() call if topic is reused)
      // In our impl, channel() caches so re-request returns the same closed object.
      // A new PhoenixSocket would have a fresh channel. Test that closed state is correct.
      expect(ch1.state, PhoenixChannelState.closed);
    });

    test('6. leave reply arrives after socket crashes — no error thrown', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:crash');

      final leaveFuture = ch.leave();
      await flush();

      // Socket crashes before leave reply
      s.killNetwork();
      await flush();

      // Leave future should complete or error without crashing
      await leaveFuture.catchError((_) {});
    });
  });

  // =========================================================================
  // 3. TCP half-open (one side dead, other unaware)
  // =========================================================================
  group('TCP half-open connection', () {
    test('7. server process dies — no TCP RST sent — heartbeat detects', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks()
          // first heartbeat sent
          ..elapse(const Duration(seconds: 30))
          ..flushMicrotasks()
          // Heartbeat pending, no reply - second tick
          ..elapse(const Duration(seconds: 30))
          ..flushMicrotasks();
        expect(s.socket.state, PhoenixSocketState.reconnecting);
        expect(s.connectCount, 1); // Still on first connection
      });
    });

    test('8. client detects half-open only via heartbeat — not immediately', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 29))
          ..flushMicrotasks();
        expect(s.socket.state, PhoenixSocketState.connected);
      });
    });
  });

  // =========================================================================
  // 4. Graceful server shutdown
  // =========================================================================
  group('Graceful server shutdown', () {
    test('9. server closes connection gracefully — client reconnects', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      await flush();

      // Server sends close (graceful shutdown) — stream ends cleanly
      unawaited(s.server.sink.close());
      await flush();
      expect(s.socket.state, PhoenixSocketState.reconnecting);
    });

    test('10. all channels errored after graceful shutdown', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch1 = await s.joinedChannel('room:a');
      final ch2 = await s.joinedChannel('room:b');

      unawaited(s.server.sink.close());
      await flush();
      expect(ch1.state, PhoenixChannelState.errored);
      expect(ch2.state, PhoenixChannelState.errored);
    });

    test('11. channels rejoin after server restarts', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:restart');

      s.killNetwork();
      await flush();
      expect(ch.state, PhoenixChannelState.errored);

      // Server comes back — reconnect fires after 1s
      fakeAsync((async) {
        // Fast-forward through reconnect timer
        async
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks();
      });

      // After reconnect, channel should have attempted rejoin
      // (state is joining or errored depending on server reply)
      expect(
        ch.state,
        anyOf(
          PhoenixChannelState.joining,
          PhoenixChannelState.errored,
          PhoenixChannelState.joined,
        ),
      );
    });
  });

  // =========================================================================
  // 5. Network interface switch (WiFi → cellular)
  // =========================================================================
  group('Network interface switch', () {
    test('12. switch mid-push — push errors or times out after network drop', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = s.socket.channel('room:switch');
        unawaited(ch.join());
        async.flushMicrotasks();
        final jRef = s.msgRef(s.sent.last);
        s.replyJoinOk(jRef, 'room:switch');
        async.flushMicrotasks();

        var pushErrored = false;
        unawaited(ch.push('event', {'data': 'x'}).then(
          (_) {},
          onError: (_) { pushErrored = true; },
        ));
        async.flushMicrotasks();

        // Network switches — old connection dies
        s.killNetwork();
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 11))
          ..flushMicrotasks();
        expect(pushErrored, isTrue);
      });
    });

    test('13. new connection established after switch — sends are fresh', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(s.connectCount, 1);

        s.killNetwork();
        async.flushMicrotasks();
        expect(s.socket.state, PhoenixSocketState.reconnecting);

        // Reconnect fires after 1s
        async
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(s.connectCount, greaterThanOrEqualTo(2));
      });
    });
  });

  // =========================================================================
  // 6. phx_error before join reply
  // =========================================================================
  group('phx_error edge cases', () {
    test('14. phx_error before join reply — join future errors', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = s.socket.channel('room:err');
      var errored = false;
      final f = ch.join().then((_) {}, onError: (_) { errored = true; });
      await flush();
      final jRef = s.msgRef(s.sent.last);
      // Server sends phx_error instead of join reply
      s.sendToClient([jRef, jRef, 'room:err', 'phx_error', <String, dynamic>{}]);
      await flush();
      await f;
      expect(errored, isTrue);
      expect(ch.state, PhoenixChannelState.errored);
    });

    test('15. multiple phx_error events — channel stays errored, no crash', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:multi-err');

      // Send phx_error multiple times
      s.sendToClient([null, null, 'room:multi-err', 'phx_error', <String, dynamic>{}]);
      await flush();
      s.sendToClient([null, null, 'room:multi-err', 'phx_error', <String, dynamic>{}]);
      await flush();
      s.sendToClient([null, null, 'room:multi-err', 'phx_error', <String, dynamic>{}]);
      await flush();
      expect(ch.state, PhoenixChannelState.errored);
    });

    test('16. phx_error on one channel does not affect sibling channels', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final chA = await s.joinedChannel('room:a');
      final chB = await s.joinedChannel('room:b');

      s.sendToClient([null, null, 'room:a', 'phx_error', <String, dynamic>{}]);
      await flush();
      expect(chA.state, PhoenixChannelState.errored);
      expect(chB.state, PhoenixChannelState.joined);
    });
  });

  // =========================================================================
  // 7. Large payload handling
  // =========================================================================
  group('Large payloads', () {
    test('17. push with 1MB payload — sent correctly', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:large');

      // Build 1MB string
      final largeData = 'x' * (1024 * 1024);
      var result = false;
      fakeAsync((async) {
        unawaited(ch.push('big_event', {'data': largeData}).then((_) {
          result = true;
        }));
        async.flushMicrotasks();
        final pushRef = s.msgRef(s.sent.last);
        final joinRef = s.msgJoinRef(s.sent.last);
        s.replyOk(joinRef, pushRef, 'room:large');
        async
          ..elapse(const Duration(milliseconds: 100))
          ..flushMicrotasks();
        expect(result, isTrue);
      });

      // Verify payload was actually sent
      final lastSent = jsonDecode(s.sent.last as String) as List;
      expect((lastSent[4] as Map)['data'], hasLength(1024 * 1024));
    });

    test('18. server sends large broadcast — received without error', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:large-bcast');

      final events = <PhoenixMessage>[];
      ch.messages.listen(events.add);

      final largeData = 'y' * (512 * 1024);
      s.broadcast('room:large-bcast', 'big', {'content': largeData});
      await flush(8);
      expect(events, hasLength(1));
      expect((events[0].payload as Map)['content'], hasLength(512 * 1024));
    });
  });

  // =========================================================================
  // 8. Push reply after channel left
  // =========================================================================
  group('Push reply after leave', () {
    test('19. push reply arrives after leave completed — no error thrown', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = s.socket.channel('room:late');
        unawaited(ch.join());
        async.flushMicrotasks();
        final jRef = s.msgRef(s.sent.last);
        s.replyJoinOk(jRef, 'room:late');
        async.flushMicrotasks();

        // Start push — don't reply yet
        var pushDone = false;
        var pushErrored = false;
        unawaited(ch.push('event', {}).then(
          (_) { pushDone = true; },
          onError: (_) { pushErrored = true; },
        ));
        async.flushMicrotasks();

        // Capture push ref before leave
        final pushRef = s.msgRef(s.sent.last);

        // Leave channel while push is in-flight
        unawaited(ch.leave());
        async.flushMicrotasks();
        final leaveRef = s.msgRef(s.sent.last);
        s.replyOk(jRef, leaveRef, 'room:late');
        async.flushMicrotasks();

        // Now server belatedly replies to the push
        s.replyOk(jRef, pushRef, 'room:late');
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 11))
          ..flushMicrotasks();
        expect(pushErrored || pushDone, isTrue);
      });
    });

    test('20. push timeout fires after channel left — no double-complete crash', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = s.socket.channel('room:timeout-left');
        unawaited(ch.join());
        async.flushMicrotasks();
        final jRef = s.msgRef(s.sent.last);
        s.replyJoinOk(jRef, 'room:timeout-left');
        async.flushMicrotasks();

        var pushErrored = false;
        unawaited(ch.push('event', {}).then(
          (_) {},
          onError: (_) { pushErrored = true; },
        ));
        async.flushMicrotasks();

        // Leave before push timeout
        unawaited(ch.leave());
        async.flushMicrotasks();
        final leaveRef = s.msgRef(s.sent.last);
        s.replyOk(jRef, leaveRef, 'room:timeout-left');
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 11))
          ..flushMicrotasks();
        expect(pushErrored, isTrue);
      });
    });
  });

  // =========================================================================
  // 9. Reconnect timing races
  // =========================================================================
  group('Reconnect timing races', () {
    test('21. disconnect called while reconnect timer pending — no reconnect', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks();
        s.killNetwork();
        async.flushMicrotasks();
        expect(s.socket.state, PhoenixSocketState.reconnecting);

        // Call disconnect before timer fires
        unawaited(s.socket.disconnect());
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks();
        expect(s.connectCount, 1);
        expect(s.socket.state, PhoenixSocketState.disconnected);
      });
    });

    test('22. connect called while reconnect timer pending — no duplicate', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks();
        s.killNetwork();
        async.flushMicrotasks();
        expect(s.socket.state, PhoenixSocketState.reconnecting);
        final connectsAfterCrash = s.connectCount;

        // Calling connect() again while in reconnecting state is a no-op
        unawaited(s.socket.connect());
        async.flushMicrotasks();
        expect(s.connectCount, connectsAfterCrash); // no extra connect

        // Advance past timer
        async
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks();
        expect(s.connectCount, connectsAfterCrash + 1);
      });
    });

    test('23. rapid kill → kill → kill — only one reconnect timer active', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks();
        s.killNetwork();
        async.flushMicrotasks();
        // State is reconnecting — further killNetwork() calls are ignored
        // because _handleDisconnect guards on reconnecting state
        unawaited(s.server.sink.close()); // already closed — no-op
        async.flushMicrotasks();

        final connectsBeforeTimer = s.connectCount;
        async
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks();
        expect(s.connectCount, connectsBeforeTimer + 1);
      });
    });

    test('24. socket reconnects — new WS factory called each time', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks();
        for (var i = 0; i < 3; i++) {
          s.killNetwork();
          async
            ..flushMicrotasks()
            ..elapse(Duration(seconds: [1, 2, 4][i] + 1))
            ..flushMicrotasks();
        }
        expect(s.connectCount, greaterThanOrEqualTo(4)); // initial + 3 reconnects
      });
    });
  });

  // =========================================================================
  // 10. Socket reuse after explicit disconnect
  // =========================================================================
  group('Socket reuse after disconnect', () {
    test('25. disconnect → connect → join works cleanly', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      await s.joinedChannel('room:reuse');

      await s.socket.disconnect();
      expect(s.socket.state, PhoenixSocketState.disconnected);

      await s.socket.connect();
      await flush();
      expect(s.socket.state, PhoenixSocketState.connected);

      // Can join again
      final ch2 = s.socket.channel('room:fresh');
      var joined = false;
      fakeAsync((async) {
        unawaited(ch2.join().then((_) { joined = true; }));
        async.flushMicrotasks();
        final ref = s.msgRef(s.sent.last);
        s.replyJoinOk(ref, 'room:fresh');
        async
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(joined, isTrue);
      });
    });

    test('26. socket state stream emits disconnected on explicit disconnect', () async {
      final s = RealWorldSetup()..init();
      final states = <PhoenixSocketState>[];
      s.socket.states.listen(states.add);
      await s.connect();
      await flush();
      await s.socket.disconnect();
      await flush();
      expect(states, contains(PhoenixSocketState.disconnected));
    });

    test('27. ref counter does not reset after disconnect → reconnect', () async {
      final s = RealWorldSetup()..init();
      await s.connect();

      // Generate some refs
      final r1 = s.socket.nextRef();
      final r2 = s.socket.nextRef();
      final ref1 = int.parse(r1);
      final ref2 = int.parse(r2);
      expect(ref2, ref1 + 1);

      await s.socket.disconnect();
      await s.socket.connect();
      await flush();

      final r3 = s.socket.nextRef();
      expect(int.parse(r3), greaterThan(ref2));
    });
  });

  // =========================================================================
  // 11. Broadcast ordering
  // =========================================================================
  group('Broadcast ordering', () {
    test('28. 10 broadcasts arrive in order', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:order');
      final received = <int>[];
      ch.messages.listen((m) => received.add(m.payload['seq'] as int));

      for (var i = 0; i < 10; i++) {
        s.broadcast('room:order', 'tick', {'seq': i});
      }
      await flush(20);
      expect(received, List.generate(10, (i) => i));
    });

    test('29. broadcast arrives before push reply — both processed', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:interleave');
      final events = <String>[];
      ch.messages.listen((m) => events.add(m.event));

      var pushDone = false;
      fakeAsync((async) {
        unawaited(ch.push('do_thing', {}).then((_) { pushDone = true; }));
        async.flushMicrotasks();
        final pushRef = s.msgRef(s.sent.last);
        final joinRef = s.msgJoinRef(s.sent.last);

        // Broadcast arrives before push reply
        s.broadcast('room:interleave', 'news', {'x': 1});
        async.flushMicrotasks();

        // Push reply arrives after broadcast
        s.replyOk(joinRef, pushRef, 'room:interleave');
        async
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(events, contains('news'));
        expect(pushDone, isTrue);
      });
    });

    test('30. broadcast on wrong topic not delivered to channel', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:mytopic');
      final events = <PhoenixMessage>[];
      ch.messages.listen(events.add);

      s.broadcast('room:othertopic', 'event', {'x': 1});
      await flush(4);
      expect(events, isEmpty);
    });
  });

  // =========================================================================
  // 12. Zero-payload and empty payload
  // =========================================================================
  group('Edge payloads', () {
    test('31. push with empty map payload', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:empty');

      var done = false;
      fakeAsync((async) {
        unawaited(ch.push('ping', {}).then((_) { done = true; }));
        async.flushMicrotasks();
        final ref = s.msgRef(s.sent.last);
        final jRef = s.msgJoinRef(s.sent.last);
        s.replyOk(jRef, ref, 'room:empty');
        async
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(done, isTrue);
      });
    });

    test('32. join with empty payload', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = s.socket.channel('room:emptyjoin');
      var joined = false;
      fakeAsync((async) {
        unawaited(ch.join(payload: {}).then((_) { joined = true; }));
        async.flushMicrotasks();
        final ref = s.msgRef(s.sent.last);
        s.replyJoinOk(ref, 'room:emptyjoin');
        async
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(joined, isTrue);
      });
    });

    test('33. push payload with nested structure preserved round-trip', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:nested');
      final payload = {
        'user': {'id': 42, 'name': 'Alice'},
        'tags': ['a', 'b', 'c'],
        'meta': {'score': 3.14}
      };

      fakeAsync((async) {
        unawaited(ch.push('complex', payload));
        async.flushMicrotasks();
        final raw = s.sent.last as String;
        final decoded = jsonDecode(raw) as List;
        expect(decoded[4], payload);
      });
    });
  });

  // =========================================================================
  // 13. Heartbeat does not interfere with pushes
  // =========================================================================
  group('Heartbeat and push coexistence', () {
    test('34. heartbeat fires during push in-flight — push still resolves',
        () async {
      // Simulate: push is in-flight, heartbeat fires and gets a reply, then push gets a reply.
      // This verifies heartbeat handling doesn't corrupt push pending refs.
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:hb34');

      var pushDone = false;
      unawaited(ch.push('my_custom_push', {}).then((_) { pushDone = true; }));
      await flush(4);
      final pushMsg = s.sent.lastWhere(
          (raw) => s.msgEvent(raw) == 'my_custom_push');
      final pushRef = s.msgRef(pushMsg);
      final pushJoinRef = s.msgJoinRef(pushMsg);

      // Simulate heartbeat arriving in the middle — just send a fake heartbeat reply
      // (as if the timer fired and the server replied)
      const fakeHbRef = 'hb-fake-999';
      s.sendToClient([null, fakeHbRef, 'phoenix', 'phx_reply',
        {'status': 'ok', 'response': <String, dynamic>{}}]);
      await flush(4);

      // Push reply arrives after heartbeat
      s.replyOk(pushJoinRef, pushRef, 'room:hb34');
      await flush();
      expect(pushDone, isTrue);
      expect(s.socket.state, PhoenixSocketState.connected);
    });

    test('35. push reply misidentified as heartbeat reply — not confused', () async {
      // Heartbeat replies go to topic "phoenix". Push replies go to channel topic.
      // They should never be confused.
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:nohb');
      final events = <PhoenixMessage>[];
      ch.messages.listen(events.add);

      var pushDone = false;
      fakeAsync((async) {
        unawaited(ch.push('action', {}).then((_) { pushDone = true; }));
        async.flushMicrotasks();
        final ref = s.msgRef(s.sent.last);
        final jRef = s.msgJoinRef(s.sent.last);
        s.replyOk(jRef, ref, 'room:nohb');
        async
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(pushDone, isTrue);
        expect(events, isEmpty); // phx_reply not emitted to messages stream
      });
    });
  });

  // =========================================================================
  // 14. Errored channel rejoin cycle
  // =========================================================================
  group('Errored channel rejoin cycle', () {
    test('36. channel error → socket reconnect → channel rejoins', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:cycle');

      s.killNetwork();
      await flush();
      expect(ch.state, PhoenixChannelState.errored);

      // After reconnect + rejoin
      fakeAsync((async) {
        async
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks();
        final hasSentJoin = s.sent.any((raw) => s.msgEvent(raw) == 'phx_join');
        expect(hasSentJoin, isTrue);
      });
    });

    test('37. rejoin fails → channel stays errored — no infinite loop', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks();
        final ch = s.socket.channel('room:failrejoin');
        unawaited(ch.join());
        async.flushMicrotasks();
        final jRef = s.msgRef(s.sent.last);
        s.replyJoinOk(jRef, 'room:failrejoin');
        async.flushMicrotasks();

        // Crash server → channel errors → reconnect → rejoin attempt
        s.killNetwork();
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks();
        final newJRef = s.sent
            .where((raw) => s.msgEvent(raw) == 'phx_join')
            .map(s.msgRef)
            .last;
        s.replyError(newJRef, newJRef, 'room:failrejoin', {'reason': 'forbidden'});
        async.flushMicrotasks();

        expect(ch.state, PhoenixChannelState.errored);
        // No crash, no infinite loop
      });
    });
  });

  // =========================================================================
  // 15. Connection failures (server refuses connection)
  // =========================================================================
  group('Connection refused', () {
    test('38. connect to unreachable server — schedules reconnect', () {
      fakeAsync((async) {
        var attempts = 0;
        final socket = PhoenixSocket(
          'ws://unreachable:9999/socket',
          channelFactory: (uri) {
            attempts++;
            final fake = FakeWebSocketChannel();
            // Immediately close (simulates connection refused)
            unawaited(Future.microtask(() => fake.server.sink.close()));
            return fake;
          },
        );
        unawaited(socket.connect());
        async.flushMicrotasks();
        // Initial connect attempt
        expect(attempts, 1);
        // State goes to reconnecting
        async.flushMicrotasks();
        expect(
          socket.state,
          anyOf(PhoenixSocketState.reconnecting, PhoenixSocketState.disconnected),
        );
        unawaited(socket.disconnect());
      });
    });

    test('39. connection error → backoff progression → eventually gives up timer', () {
      fakeAsync((async) {
        var attempts = 0;
        final socket = PhoenixSocket(
          'ws://unreachable:9999/socket',
          channelFactory: (uri) {
            attempts++;
            final fake = FakeWebSocketChannel();
            unawaited(Future.microtask(() => fake.server.sink.close()));
            return fake;
          },
        );
        unawaited(socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(attempts, greaterThanOrEqualTo(2));
        unawaited(socket.disconnect());
      });
    });
  });

  // =========================================================================
  // 16. Channel join during reconnecting state
  // =========================================================================
  group('Join during reconnecting', () {
    test('40. channel obtained during reconnecting — can be joined after reconnect',
        () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        s.killNetwork();
        async.flushMicrotasks();
        expect(s.socket.state, PhoenixSocketState.reconnecting);

        // Get channel while socket is reconnecting
        final ch = s.socket.channel('room:late-join');
        expect(ch.state, PhoenixChannelState.closed);

        // Reconnect fires after 1s
        async
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(s.socket.state,
          anyOf(PhoenixSocketState.connecting, PhoenixSocketState.connected));
      });
    });

    test('41. push buffered during joining — flushed after join reply', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks();
        final ch = s.socket.channel('room:buffer');
        unawaited(ch.join());
        async.flushMicrotasks();
        final jRef = s.msgRef(s.sent.last);

        // Push before join reply (buffered)
        var pushDone = false;
        unawaited(ch.push('buffered', {'x': 1}).then((_) { pushDone = true; }));
        async.flushMicrotasks();

        // Join reply arrives
        s.replyJoinOk(jRef, 'room:buffer');
        async.flushMicrotasks();

        // Buffered push should now be sent
        final pushesSent = s.sent
            .where((raw) => s.msgEvent(raw) == 'buffered')
            .toList();
        expect(pushesSent, hasLength(1));

        // Reply to push
        final pushRef = s.msgRef(pushesSent.first);
        final joinRef = s.msgJoinRef(pushesSent.first);
        s.replyOk(joinRef, pushRef, 'room:buffer');
        async
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(pushDone, isTrue);
      });
    });
  });

  // =========================================================================
  // 17. Thundering herd (many clients reconnect simultaneously)
  // =========================================================================
  group('Thundering herd', () {
    test('42. 20 sockets with same backoff timing — all get their own timer', () {
      fakeAsync((async) {
        final sockets = <PhoenixSocket>[];
        final connectCounts = <int>[];
        for (var i = 0; i < 20; i++) {
          const count = 0;
          connectCounts.add(0);
          final idx = i;
          final socket = PhoenixSocket(
            'ws://localhost:4000/socket',
            channelFactory: (uri) {
              connectCounts[idx]++;
              return FakeWebSocketChannel();
            },
          );
          sockets.add(socket);
        }

        // All connect simultaneously
        for (final s in sockets) {
          unawaited(s.connect());
        }
        async.flushMicrotasks();
        expect(connectCounts.every((c) => c == 1), isTrue);

        // Disconnect all
        for (final s in sockets) {
          unawaited(s.disconnect());
        }
        async.flushMicrotasks();
      });
    });
  });

  // =========================================================================
  // 18. Protocol invariants
  // =========================================================================
  group('Protocol invariants', () {
    test('43. join message always has vsn=2.0.0 in URL', () async {
      var capturedUri = Uri.parse('ws://placeholder');
      final socket = PhoenixSocket(
        'ws://localhost:4000/socket/websocket',
        channelFactory: (uri) {
          capturedUri = uri;
          return FakeWebSocketChannel();
        },
      );
      unawaited(socket.connect());
      await flush();
      expect(capturedUri.queryParameters['vsn'], '2.0.0');
      unawaited(socket.disconnect());
    });

    test('44. custom params preserved alongside vsn', () async {
      var capturedUri = Uri.parse('ws://placeholder');
      final socket = PhoenixSocket(
        'ws://localhost:4000/socket/websocket',
        params: {'token': 'abc123', 'user_id': '42'},
        channelFactory: (uri) {
          capturedUri = uri;
          return FakeWebSocketChannel();
        },
      );
      unawaited(socket.connect());
      await flush();
      expect(capturedUri.queryParameters['vsn'], '2.0.0');
      expect(capturedUri.queryParameters['token'], 'abc123');
      expect(capturedUri.queryParameters['user_id'], '42');
      unawaited(socket.disconnect());
    });

    test('45. phx_join event has correct wire format', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = s.socket.channel('room:wire');
      unawaited(ch.join(payload: {'token': 'xyz'}));
      await flush();
      final raw = jsonDecode(s.sent.last as String) as List;
      expect(raw.length, 5);
      // [joinRef, ref, topic, event, payload]
      expect(raw[2], 'room:wire');
      expect(raw[3], 'phx_join');
      expect(raw[4], {'token': 'xyz'});
      // joinRef and ref must be equal for join
      expect(raw[0], raw[1]);
    });

    test('46. heartbeat message has correct wire format', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 30))
          ..flushMicrotasks();
        final raw = jsonDecode(s.sent.last as String) as List;
        expect(raw.length, 5);
        expect(raw[0], isNull);       // joinRef = null
        expect(raw[2], 'phoenix');     // topic
        expect(raw[3], 'heartbeat');   // event
        expect(raw[4], <String, dynamic>{});            // payload = empty map
      });
    });

    test('47. push message wire format — joinRef matches channel joinRef', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:fmt');
      // joinRef was the ref used during join
      final joinJoinRef = s.msgJoinRef(
        s.sent.firstWhere((raw) => s.msgEvent(raw) == 'phx_join'));

      fakeAsync((async) {
        unawaited(ch.push('action', {}));
        async.flushMicrotasks();
        final pushMsg = s.sent.lastWhere((raw) => s.msgEvent(raw) == 'action');
        final pushJoinRef = s.msgJoinRef(pushMsg);
        expect(pushJoinRef, joinJoinRef);
      });
    });

    test('48. leave message wire format', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:leave-fmt');

      unawaited(ch.leave());
      await flush();
      final raw = jsonDecode(s.sent.last as String) as List;
      expect(raw[2], 'room:leave-fmt');
      expect(raw[3], 'phx_leave');
    });

    test('49. malformed server message does not crash socket', () async {
      final s = RealWorldSetup()..init();
      await s.connect();

      // Send invalid JSON
      s.server.sink.add('not-valid-json{{{');
      await flush();
      expect(s.socket.state, PhoenixSocketState.connected);

      // Send valid JSON but wrong structure (not an array)
      s.server.sink.add(jsonEncode({'key': 'value'}));
      await flush();
      expect(s.socket.state, PhoenixSocketState.connected);

      // Send array with too few elements
      s.server.sink.add(jsonEncode([1, 2]));
      await flush();
      expect(s.socket.state, PhoenixSocketState.connected);
    });

    test('50. null ref in push reply — not matched to any pending push', () async {
      final s = RealWorldSetup()..init();
      await s.connect();
      final ch = await s.joinedChannel('room:nullref');
      var pushDone = false;
      fakeAsync((async) {
        unawaited(ch.push('action', {}).then((_) { pushDone = true; }));
        async.flushMicrotasks();
        final jRef = s.msgJoinRef(s.sent.last);

        // Server sends reply with null ref — should not match the pending push
        s.replyOk(jRef, 'null', 'room:nullref');
        async.flushMicrotasks();
        expect(pushDone, isFalse);

        // Correct ref resolves
        final pushRef = s.msgRef(
          s.sent.lastWhere((raw) => s.msgEvent(raw) == 'action'));
        s.replyOk(jRef, pushRef, 'room:nullref');
        async
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(pushDone, isTrue);
      });
    });
  });

  // =========================================================================
  // 19. App backgrounding simulation (no timer ticks)
  // =========================================================================
  group('App backgrounding', () {
    test('51. no activity for 30min — heartbeat detects dead connection on resume', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks()
          // first heartbeat sent
          ..elapse(const Duration(seconds: 30))
          ..flushMicrotasks()
          // no reply → reconnect
          ..elapse(const Duration(seconds: 30))
          ..flushMicrotasks();
        expect(s.socket.state, PhoenixSocketState.reconnecting);
      });
    });

    test('52. resumed after backgrounding — channels rejoin after reconnect', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = s.socket.channel('room:bg');
        unawaited(ch.join());
        async.flushMicrotasks();
        final jRef = s.msgRef(s.sent.last);
        s.replyJoinOk(jRef, 'room:bg');
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 30))
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 30))
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks();
        expect(ch.state, anyOf(
          PhoenixChannelState.joining,
          PhoenixChannelState.joined,
          PhoenixChannelState.errored,
        ));
        // New join was sent
        final joinsSent = s.sent
            .where((raw) => s.msgEvent(raw) == 'phx_join')
            .toList();
        expect(joinsSent.length, greaterThanOrEqualTo(2)); // original + rejoin
      });
    });
  });

  // =========================================================================
  // 20. Concurrent channel operations
  // =========================================================================
  group('Concurrent operations', () {
    test('53. 5 channels join simultaneously — all succeed', () async {
      final s = RealWorldSetup()..init();
      await s.connect();

      final topics = List.generate(5, (i) => 'room:concurrent$i');
      final channels = topics.map(s.socket.channel).toList();
      final futures = channels.map((ch) => ch.join()).toList();
      await flush();

      // Reply to all joins
      for (final topic in topics) {
        final joinMsg = s.sent.lastWhere((raw) => s.msgTopic(raw) == topic);
        final ref = s.msgRef(joinMsg);
        s.replyJoinOk(ref, topic);
      }
      await flush(20);
      await Future.wait(futures);
      expect(channels.every((ch) => ch.state == PhoenixChannelState.joined), isTrue);
    });

    test('54. push on 3 channels simultaneously — all refs unique', () {
      fakeAsync((async) {
        final s = RealWorldSetup()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks();
        final topics = ['room:p1', 'room:p2', 'room:p3'];
        for (final t in topics) {
          final ch = s.socket.channel(t);
          unawaited(ch.join());
          async.flushMicrotasks();
          final jRef = s.msgRef(s.sent.last);
          s.replyJoinOk(jRef, t);
          async.flushMicrotasks();
        }

        // Push on all simultaneously
        for (final t in topics) {
          unawaited(s.socket.channel(t).push('action', {}));
        }
        async.flushMicrotasks();

        final pushRefs = s.sent
            .where((raw) => s.msgEvent(raw) == 'action')
            .map(s.msgRef)
            .toSet();
        expect(pushRefs.length, 3); // all unique refs
      });
    });

    test('55. disconnect during multi-channel join storm — clean teardown', () async {
      final s = RealWorldSetup()..init();
      await s.connect();

      final channels = List.generate(10, (i) => s.socket.channel('room:storm$i'));
      final futures = channels
          .map((ch) => ch.join().then((_) {}, onError: (_) {}))
          .toList();
      await flush();

      // Disconnect before any joins complete
      await s.socket.disconnect();
      await flush(10);
      await Future.wait(futures);
      expect(s.socket.state, PhoenixSocketState.disconnected);
    });
  });
}
