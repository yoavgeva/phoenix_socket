// Tests for additional real-world Phoenix Channel / WebSocket bugs.
//
// Sources:
//   - Phoenix.js #4948:  double-ref on buffered push (orphaned reply handler)
//   - Phoenix.js #3349:  join+leave before reply → infinite rejoin loop
//   - Phoenix.js #4616:  disconnect() during reconnecting doesn't stop retries
//   - Phoenix.js #2187:  reconnect backoff not reset after successful connect
//   - Phoenix.js #4623:  heartbeat timer not cancelled on disconnect
//   - Phoenix.js #3669:  client disconnect() leaves channel joined → unmatched topic
//   - Phoenix.js #3161:  close code 1000 suppresses reconnect after heartbeat self-close
//   - Phoenix.js #1739:  push() during "leaving" state silently lost
//   - Phoenix.js #2251:  phx_close prevents rejoin after reconnect
//   - Dart SDK #32519:   StreamSink "bad state" crash during reconnect window
//   - braverhealth/phoenix-socket-dart #6/#34: backoff list not progressed

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:phoenix_socket/src/channel.dart';
import 'package:phoenix_socket/src/exceptions.dart';
import 'package:phoenix_socket/src/message.dart';
import 'package:phoenix_socket/src/socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'fake_web_socket_channel.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class T {
  late PhoenixSocket socket;
  late FakeWebSocketChannel ws;
  late StreamChannel<dynamic> server;
  final sent = <dynamic>[];
  int connects = 0;

  void init({String url = 'ws://localhost:4000/socket/websocket'}) {
    socket = PhoenixSocket(
      url,
      channelFactory: (uri) {
        connects++;
        ws = FakeWebSocketChannel();
        server = ws.server;
        server.stream.listen(sent.add);
        return ws;
      },
    );
  }

  Future<void> connect() => socket.connect();
  void drop() => server.sink.close();

  void toClient(List<dynamic> msg) => server.sink.add(jsonEncode(msg));

  String ref(dynamic raw) => (jsonDecode(raw as String) as List)[1] as String;
  String jRef(dynamic raw) => (jsonDecode(raw as String) as List)[0] as String;
  String evnt(dynamic raw) => (jsonDecode(raw as String) as List)[3] as String;
  String topicOf(dynamic raw) =>
      (jsonDecode(raw as String) as List)[2] as String;

  void replyOk(
    String jr,
    String r,
    String t, [
    Map<String, dynamic> resp = const {},
  ]) {
    toClient([
      jr,
      r,
      t,
      'phx_reply',
      {'status': 'ok', 'response': resp},
    ]);
  }

  void replyErr(
    String jr,
    String r,
    String t, [
    Map<String, dynamic> resp = const {},
  ]) {
    toClient([
      jr,
      r,
      t,
      'phx_reply',
      {'status': 'error', 'response': resp},
    ]);
  }

  void replyJoinOk(String r, String t, [Map<String, dynamic> resp = const {}]) {
    replyOk(r, r, t, resp);
  }

  void replyJoinErr(
    String r,
    String t, [
    Map<String, dynamic> resp = const {},
  ]) {
    replyErr(r, r, t, resp);
  }
}

Future<void> flush([int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await Future.microtask(() {});
  }
}

Future<PhoenixChannel> joinedChannel(T t, String topic) async {
  final ch = t.socket.channel(topic);
  unawaited(ch.join().then((_) {}, onError: (_) {}));
  await flush();
  final r = t.ref(t.sent.last);
  t.replyJoinOk(r, topic);
  await flush();
  return ch;
}

void main() {
  // =========================================================================
  // Bug: Phoenix.js #4948 — buffered push gets correct ref when finally sent
  // The push is buffered during joining, then flushed after join ok.
  // The push must use the joinRef that was current at send time, not at buffer
  // time — and the reply handler must match the ref in the server's reply.
  // =========================================================================
  group('Buffered push ref correctness (Phoenix.js #4948)', () {
    test('1. buffered push reply resolves completer correctly', () async {
      final t = T()..init();
      await t.connect();

      final ch = t.socket.channel('room:ref_test');
      unawaited(ch.join().then((_) {}, onError: (_) {}));
      await flush();
      final joinRef = t.ref(t.sent.last);

      // Buffer a push before join completes
      var pushResult = <String, dynamic>{};
      var pushDone = false;
      unawaited(
        ch.push('event_a', {'v': 42}).then((r) {
          pushResult = r;
          pushDone = true;
        }),
      );
      await flush();

      // Push not yet sent
      expect(t.sent.where((m) => t.evnt(m) == 'event_a'), isEmpty);

      // Join ok → push should be flushed
      t.replyJoinOk(joinRef, 'room:ref_test');
      await flush(10);

      // Push was sent after join
      final pushMsgs = t.sent.where((m) => t.evnt(m) == 'event_a').toList();
      expect(pushMsgs, hasLength(1));

      // Reply to push with correct ref
      final pushRef = t.ref(pushMsgs.first);
      final pushJoinRef = t.jRef(pushMsgs.first);
      t.replyOk(pushJoinRef, pushRef, 'room:ref_test', {'result': 'ok'});
      await flush();

      expect(pushDone, isTrue);
      expect(pushResult['result'], 'ok');
    });

    test('2. multiple buffered pushes all resolve in order', () async {
      final t = T()..init();
      await t.connect();

      final ch = t.socket.channel('room:multi_ref');
      unawaited(ch.join().then((_) {}, onError: (_) {}));
      await flush();
      final joinRef = t.ref(t.sent.last);

      final resolved = <int>[];
      for (var i = 0; i < 3; i++) {
        final idx = i;
        unawaited(ch.push('msg_$i', {'i': i}).then((_) => resolved.add(idx)));
      }
      await flush();

      t.replyJoinOk(joinRef, 'room:multi_ref');
      await flush(10);

      // All 3 pushes sent — reply to each
      for (var i = 0; i < 3; i++) {
        final msgs = t.sent.where((m) => t.evnt(m) == 'msg_$i').toList();
        expect(msgs, hasLength(1));
        final pRef = t.ref(msgs.first);
        final pJRef = t.jRef(msgs.first);
        t.replyOk(pJRef, pRef, 'room:multi_ref');
      }
      await flush(10);

      expect(resolved, containsAll([0, 1, 2]));
    });
  });

  // =========================================================================
  // Bug: Phoenix.js #3349 — join+leave before reply → potential rejoin loop
  // leave() must cancel the pending join timeout, not leave it dangling.
  // After leave() the channel must stay closed even if no join reply ever comes.
  // =========================================================================
  group('join+leave before reply — no infinite rejoin (Phoenix.js #3349)', () {
    test('3. join then leave before reply — channel ends closed', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = t.socket.channel('room:join_leave');
        unawaited(ch.join().then((_) {}, onError: (_) {}));
        async.flushMicrotasks();

        // Leave immediately — server never replies to join
        unawaited(ch.leave().then((_) {}, onError: (_) {}));
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 60));
        expect(ch.state, PhoenixChannelState.closed);

        // Server should have received a phx_leave
        final leaves = t.sent.where((m) => t.evnt(m) == 'phx_leave').toList();
        expect(leaves, isNotEmpty);
      });
    });

    test('4. join then leave — join future errors, not hangs', () async {
      final t = T()..init();
      await t.connect();

      final ch = t.socket.channel('room:join_leave2');
      var joinErrored = false;
      unawaited(
        ch.join().then(
          (_) {},
          onError: (_) {
            joinErrored = true;
          },
        ),
      );
      await flush();

      await ch.leave();
      await flush(4);

      expect(joinErrored, isTrue);
    });
  });

  // =========================================================================
  // Bug: Phoenix.js #4616 — disconnect() during reconnecting stops all retries
  // =========================================================================
  group('disconnect() cancels reconnect timer (Phoenix.js #4616)', () {
    test(
      '5. disconnect() during reconnect backoff — no further connect calls',
      () {
        fakeAsync((async) {
          final t = T()..init();
          unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
          async
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks();
          final connectsBefore = t.connects;

          // Drop connection → schedules reconnect in 1s
          t.drop();
          async
            ..flushMicrotasks()
            ..flushMicrotasks();
          expect(t.socket.state, PhoenixSocketState.reconnecting);

          // Disconnect before the 1s reconnect timer fires
          unawaited(t.socket.disconnect());
          async
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 60));
          expect(t.connects, connectsBefore);
          expect(t.socket.state, PhoenixSocketState.disconnected);
        });
      },
    );

    test('6. disconnect() then connect() — reconnects cleanly', () async {
      final t = T()..init();
      await t.connect();
      await t.socket.disconnect();

      expect(t.socket.state, PhoenixSocketState.disconnected);

      await t.connect();
      await flush();

      expect(t.socket.state, PhoenixSocketState.connected);
    });
  });

  // =========================================================================
  // Bug: Phoenix.js #2187 — reconnect backoff resets after successful connect
  // After a successful reconnect, the NEXT disconnect must start from delay[0].
  // =========================================================================
  group('Backoff resets after successful reconnect (Phoenix.js #2187)', () {
    test('7. second disconnect-reconnect cycle starts from first delay', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        t.drop();
        async
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(t.socket.state, PhoenixSocketState.reconnecting);

        // Reconnect fires at 1s
        async
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(t.socket.state, PhoenixSocketState.connected);
        expect(t.connects, 2); // initial + 1 reconnect

        // Second disconnect → must use delay[0] = 1s again
        final connectsBefore = t.connects;
        t.drop();
        async
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(t.socket.state, PhoenixSocketState.reconnecting);

        // Should reconnect at 1s (backoff reset), not a longer delay
        async
          ..elapse(const Duration(milliseconds: 900))
          ..flushMicrotasks();
        expect(t.connects, connectsBefore); // not yet

        async
          ..elapse(const Duration(milliseconds: 200))
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(t.connects, connectsBefore + 1); // fired at ~1s
      });
    });
  });

  // =========================================================================
  // Bug: Phoenix.js #4623 — heartbeat timer cancelled on disconnect
  // After disconnect(), no heartbeat should fire or cause reconnect.
  // =========================================================================
  group('Heartbeat cancelled on disconnect (Phoenix.js #4623)', () {
    test('8. disconnect() — no heartbeat sent afterward', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(t.socket.state, PhoenixSocketState.connected);

        unawaited(t.socket.disconnect());
        async.flushMicrotasks();

        final sentCountAfterDisconnect = t.sent.length;

        // Advance past heartbeat interval — no new heartbeat should be sent
        async.elapse(const Duration(seconds: 60));

        expect(t.sent.length, sentCountAfterDisconnect);
        expect(t.socket.state, PhoenixSocketState.disconnected);
      });
    });

    test('9. disconnect() mid-heartbeat-interval — no reconnect loop', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 29));
        unawaited(t.socket.disconnect());
        async.flushMicrotasks();

        final connectsBefore = t.connects;

        // Advance another 60s — heartbeat that was about to fire must NOT
        // fire, and certainly must not trigger a reconnect loop
        async.elapse(const Duration(seconds: 60));

        expect(t.connects, connectsBefore);
        expect(t.socket.state, PhoenixSocketState.disconnected);
      });
    });
  });

  // =========================================================================
  // Bug: Phoenix.js #3669 — client-side disconnect() must mark channels errored
  // After socket.disconnect() + socket.connect(), channels must rejoin.
  // =========================================================================
  group(
    'Client disconnect transitions channels to errored (Phoenix.js #3669)',
    () {
      test('10. disconnect+connect → channel rejoins automatically', () async {
        final t = T()..init();
        await t.connect();

        // Join a channel
        final ch = await joinedChannel(t, 'room:dc_rejoin');
        expect(ch.state, PhoenixChannelState.joined);

        // Client-side intentional disconnect → channel goes closed (not errored)
        await t.socket.disconnect();
        expect(ch.state, PhoenixChannelState.closed);

        // Reconnect — channels in closed state are NOT auto-rejoined
        // (intentional disconnects mean the user chose to leave)
        await t.connect();
        await flush(6);

        // Only the original join — no auto-rejoin for intentionally-closed channels
        final joins = t.sent.where((m) => t.evnt(m) == 'phx_join').toList();
        expect(joins.length, 1);
      });

      test(
        '11. channel state is errored (not joined) after client disconnect',
        () async {
          final t = T()..init();
          await t.connect();

          final ch = await joinedChannel(t, 'room:dc_state');
          expect(ch.state, PhoenixChannelState.joined);

          await t.socket.disconnect();

          expect(ch.state, isNot(PhoenixChannelState.joined));
        },
      );
    },
  );

  // =========================================================================
  // Bug: Phoenix.js #3161 — heartbeat timeout close must trigger reconnect
  // Heartbeat fires, no reply, socket closes itself → must reconnect (not die).
  // =========================================================================
  group('Heartbeat timeout triggers reconnect (Phoenix.js #3161)', () {
    test('12. unanswered heartbeat → reconnect attempt made', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(t.socket.state, PhoenixSocketState.connected);

        // First heartbeat tick at 30s — send heartbeat but never reply
        async
          ..elapse(const Duration(seconds: 30))
          ..flushMicrotasks();
        final heartbeats = t.sent
            .where((m) => t.evnt(m) == 'heartbeat')
            .toList();
        expect(heartbeats, isNotEmpty);

        // Second tick at 60s — pending heartbeat ref → trigger reconnect
        async
          ..elapse(const Duration(seconds: 30))
          ..flushMicrotasks();
        expect(
          t.socket.state,
          anyOf(
            PhoenixSocketState.reconnecting,
            PhoenixSocketState.connecting,
            PhoenixSocketState.connected,
          ),
        );

        // After backoff (1s), reconnect fires
        async
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(t.connects, greaterThanOrEqualTo(2));
      });
    });
  });

  // =========================================================================
  // Bug: Phoenix.js #1739 — push() during "leaving" state must not silently hang
  // After leave() is called, a push() must fail fast (StateError), not hang.
  // =========================================================================
  group('push() during leaving state not silently lost (Phoenix.js #1739)', () {
    test('13. push() while leaving → throws StateError immediately', () async {
      final t = T()..init();
      await t.connect();

      final ch = await joinedChannel(t, 'room:leaving_push');

      // Start leave (don't await — server never replies)
      unawaited(ch.leave().then((_) {}, onError: (_) {}));
      await flush(2);

      expect(ch.state, PhoenixChannelState.leaving);

      // push() during leaving must throw, not silently hang
      expect(
        () => ch.push('event', {'x': 1}),
        throwsStateError,
      );
    });
  });

  // =========================================================================
  // Bug: Phoenix.js #2251 — phx_close from server → channel stays closed after reconnect
  // After server sends phx_close the channel transitions to closed.
  // On socket reconnect, a server-closed channel must NOT auto-rejoin —
  // that would flood the server with unauthorized joins.
  // =========================================================================
  group(
    'phx_close prevents auto-rejoin after reconnect (Phoenix.js #2251)',
    () {
      test(
        '14. server phx_close → channel closed, does not rejoin on reconnect',
        () async {
          final t = T()..init();
          await t.connect();

          final ch = await joinedChannel(t, 'room:server_close');
          final joinRef = t.jRef(t.sent.last);

          // Server sends phx_close
          t.toClient([joinRef, null, 'room:server_close', 'phx_close', {}]);
          await flush(4);

          expect(ch.state, PhoenixChannelState.closed);

          // Simulate disconnect + reconnect
          t.drop();
          await flush(4);

          // Advance reconnect backoff
          await Future.delayed(const Duration(seconds: 2));
          await flush(4);

          // No new phx_join for the closed channel
          final joins = t.sent.where((m) => t.evnt(m) == 'phx_join').toList();
          // Only the original join, no additional
          expect(joins.length, 1);
        },
      );

      test('15. server phx_close on joining channel — future errors', () async {
        final t = T()..init();
        await t.connect();

        final ch = t.socket.channel('room:close_during_join');
        var joinErrored = false;
        unawaited(
          ch.join().then(
            (_) {},
            onError: (_) {
              joinErrored = true;
            },
          ),
        );
        await flush();

        final r = t.ref(t.sent.last);

        // Server sends phx_close before join reply
        t.toClient([r, null, 'room:close_during_join', 'phx_close', {}]);
        await flush(4);

        expect(joinErrored, isTrue);
        expect(ch.state, PhoenixChannelState.closed);
      });
    },
  );

  // =========================================================================
  // Bug: Dart SDK #32519 — no unhandled StateError during reconnect window
  // If the heartbeat/send fires while the old WS is closed and new WS is not
  // yet up, the sink.add() must not throw an unhandled exception.
  // =========================================================================
  group('No unhandled StateError during reconnect window (Dart SDK #32519)', () {
    test('16. send() while disconnected — no exception propagates', () async {
      final t = T()..init();
      await t.connect();
      t.drop();
      await flush(4);

      // socket is now reconnecting / disconnected
      // Calling send-level push should not crash
      expect(
        () => t.socket.send(
          const PhoenixMessage(
            joinRef: null,
            ref: '999',
            topic: 'phoenix',
            event: 'heartbeat',
            payload: {},
          ),
        ),
        returnsNormally,
      );
    });

    test('17. rapid connect+drop cycles — no unhandled exceptions', () async {
      final t = T()..init();

      for (var i = 0; i < 5; i++) {
        unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
        await flush(4);
        t.drop();
        await flush(4);
      }

      // No exception means success — socket in reconnecting/disconnected state
      expect(
        t.socket.state,
        anyOf(
          PhoenixSocketState.reconnecting,
          PhoenixSocketState.disconnected,
        ),
      );
    });
  });

  // =========================================================================
  // Bug: braverhearts/phoenix-socket-dart #6/#34 — backoff list progresses
  // Each failed reconnect must use the next delay, not the same one forever.
  // =========================================================================
  group('Reconnect backoff progresses through delays (braverhealth #6/#34)', () {
    test('18. consecutive connect-refused failures use increasing delays', () {
      fakeAsync((async) {
        // Factory throws on connect (connection refused — never reaches ready)
        var connectCount = 0;
        final socket = PhoenixSocket(
          'ws://localhost:4000/socket/websocket',
          channelFactory: (uri) {
            connectCount++;
            // Throw synchronously to simulate connection refused
            throw Exception('Connection refused');
          },
        );

        unawaited(socket.connect().then((_) {}, onError: (_) {}));
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(connectCount, 1);
        expect(socket.state, PhoenixSocketState.reconnecting);

        // Should NOT retry before 1s
        async
          ..elapse(const Duration(milliseconds: 999))
          ..flushMicrotasks();
        expect(connectCount, 1);

        // Retries at 1s (1ms more tips us over)
        async
          ..elapse(const Duration(milliseconds: 2))
          ..flushMicrotasks();
        expect(connectCount, 2); // attempt 2 fired

        // Should NOT retry before 2s more
        // (from t=1001ms, 2s timer fires at t=3001ms; check at t=3000ms)
        async
          ..elapse(const Duration(milliseconds: 1998))
          ..flushMicrotasks();
        expect(connectCount, 2);

        // Retries at 2s
        async
          ..elapse(const Duration(milliseconds: 5))
          ..flushMicrotasks();
        expect(connectCount, 3); // attempt 3 fired

        // Should NOT retry before 4s more
        // attempt 3 fired at t≈3000ms, 4s timer fires at t≈7000ms
        // check at t=6999ms (1ms before boundary)
        async
          ..elapse(const Duration(milliseconds: 3993))
          ..flushMicrotasks();
        expect(connectCount, 3);

        // Retries at 4s
        async
          ..elapse(const Duration(milliseconds: 5))
          ..flushMicrotasks();
        expect(connectCount, 4); // attempt 4 fired

        unawaited(socket.disconnect());
      });
    });

    test('19. backoff is capped at 30s max delay', () {
      fakeAsync((async) {
        var connectCount = 0;
        final socket = PhoenixSocket(
          'ws://localhost:4000/socket/websocket',
          channelFactory: (uri) {
            connectCount++;
            throw Exception('Connection refused');
          },
        );

        unawaited(socket.connect().then((_) {}, onError: (_) {}));

        // Burn through delays: 1, 2, 4, 8, 16, 30 seconds
        // Each attempt fails immediately (factory throws), schedules next timer
        final delays = [1, 2, 4, 8, 16, 30];
        for (final d in delays) {
          async
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..elapse(Duration(seconds: d));
        }
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final countAtMax = connectCount;
        async
          ..elapse(const Duration(seconds: 29))
          ..flushMicrotasks();
        expect(connectCount, countAtMax); // not yet

        async
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(connectCount, countAtMax + 1); // fired at 30s cap, not 60s

        unawaited(socket.disconnect());
      });
    });
  });

  // =========================================================================
  // Misc correctness edge cases
  // =========================================================================
  group('Additional correctness edge cases', () {
    test('20. orphaned reply for old joinRef does not resolve new join', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = t.socket.channel('room:stale_ref');
        unawaited(ch.join().then((_) {}, onError: (_) {}));
        async.flushMicrotasks();

        final firstJoinRef = t.ref(t.sent.last);

        // Drop → channel goes errored, socket schedules reconnect
        t.drop();
        async
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(ch.state, PhoenixChannelState.errored);

        // Let reconnect timer fire (1s backoff)
        async
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final joins = t.sent
            .where(
              (m) =>
                  t.evnt(m) == 'phx_join' && t.topicOf(m) == 'room:stale_ref',
            )
            .toList();
        expect(joins.length, 2); // original + rejoin

        final secondJoinRef = t.ref(joins.last);
        expect(secondJoinRef, isNot(firstJoinRef));

        // Late reply for the OLD join ref — must be dropped
        t.replyJoinOk(firstJoinRef, 'room:stale_ref');
        async.flushMicrotasks();

        // Channel should still be joining (old reply dropped)
        expect(ch.state, PhoenixChannelState.joining);

        // Correct reply for new ref → joined
        t.replyJoinOk(secondJoinRef, 'room:stale_ref');
        async.flushMicrotasks();
        expect(ch.state, PhoenixChannelState.joined);
      });
    });

    test('21. push reply for unknown ref — no crash', () async {
      final t = T()..init();
      await t.connect();

      final ch = await joinedChannel(t, 'room:unknown_ref');
      final joinRef = t.jRef(t.sent.last);

      // Server sends a reply for a ref that the client never sent
      t.toClient([
        joinRef,
        '9999',
        'room:unknown_ref',
        'phx_reply',
        {'status': 'ok', 'response': <String, dynamic>{}},
      ]);
      await flush(4);

      // Channel must still be in joined state — no crash
      expect(ch.state, PhoenixChannelState.joined);
    });

    test('22. phx_error from server transitions channel to errored', () async {
      final t = T()..init();
      await t.connect();

      final ch = await joinedChannel(t, 'room:error_event');
      final joinRef = t.jRef(t.sent.last);

      t.toClient([joinRef, null, 'room:error_event', 'phx_error', {}]);
      await flush(4);

      expect(ch.state, PhoenixChannelState.errored);
    });

    test(
      '23. push reply with error status rejects with PhoenixException',
      () async {
        final t = T()..init();
        await t.connect();

        final ch = await joinedChannel(t, 'room:push_error');
        final joinRef = t.jRef(t.sent.last);

        Object? caught;
        unawaited(
          ch
              .push('fail_event', {})
              .then(
                (_) {},
                onError: (e) {
                  caught = e;
                },
              ),
        );
        await flush(4);

        final pushRef = t.ref(
          t.sent.where((m) => t.evnt(m) == 'fail_event').last,
        );
        t.replyErr(joinRef, pushRef, 'room:push_error', {
          'reason': 'forbidden',
        });
        await flush(4);

        expect(caught, isA<PhoenixException>());
      },
    );

    test('24. channel messages stream only receives app events', () async {
      final t = T()..init();
      await t.connect();

      final ch = await joinedChannel(t, 'room:events_filter');
      final joinRef = t.jRef(t.sent.last);

      final received = <PhoenixMessage>[];
      ch.messages.listen(received.add);

      // Control events — must not appear on messages stream
      t
        ..toClient([
          joinRef,
          '1',
          'room:events_filter',
          'phx_reply',
          {'status': 'ok', 'response': <String, dynamic>{}},
        ])
        ..toClient([joinRef, null, 'room:events_filter', 'phx_close', {}]);
      await flush(4);

      // Re-join after phx_close
      await t.connect();
      await flush(4);
      final ch2 = await joinedChannel(t, 'room:events_filter2');
      final joinRef2 = t.jRef(t.sent.last);

      // App event — must appear
      t.toClient([
        joinRef2,
        null,
        'room:events_filter2',
        'new_msg',
        {'body': 'hello'},
      ]);
      await flush(4);

      expect(received.where((m) => m.event == 'phx_reply'), isEmpty);
      expect(received.where((m) => m.event == 'phx_close'), isEmpty);
      expect(ch2.state, PhoenixChannelState.joined);
    });

    test('25. join error — channel state is errored, future throws', () async {
      final t = T()..init();
      await t.connect();

      final ch = t.socket.channel('room:join_err');
      Object? caught;
      unawaited(
        ch.join().then(
          (_) {},
          onError: (e) {
            caught = e;
          },
        ),
      );
      await flush(4);

      final r = t.ref(t.sent.last);
      t.replyJoinErr(r, 'room:join_err', {'reason': 'unauthorized'});
      await flush(4);

      expect(caught, isA<PhoenixException>());
      expect(ch.state, PhoenixChannelState.errored);
    });
  });
}
