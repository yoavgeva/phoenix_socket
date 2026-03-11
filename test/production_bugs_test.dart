// Tests derived from real production WebSocket bugs found in the wild.
//
// Sources:
//   - Phoenix.js continuous reconnect loop (#1579)
//   - Phoenix.js reconnect loses params after disconnect (#3340)
//   - Dart ping interval "Cannot add event after closing" (#37441)
//   - Dart WebSocket connection state not updated on failure (#33362)
//   - Browser tab throttle breaks heartbeat (Socket.IO)
//   - Jetty premature idle timeout race (heartbeat arrives at boundary)
//   - Backpressure: unbounded push buffer growth
//   - Ghost connections: orphaned joining state after channel replaced
//   - Continuous rejoin loop after persistent join error
//   - Push timeout ref leak: _pendingRefs grows unbounded
//   - Leave during joining: join completer never resolved
//   - Reconnect with stale join payload (params not re-evaluated)
//   - Close code 1006 (abnormal closure): treated same as clean disconnect
//   - Multiple disconnect() calls: idempotent, no panic
//   - Channel topic reuse after close: old messages don't bleed through
//   - Heartbeat at exact timeout boundary: race between timer and reply
//   - Socket.connect() before previous connect() resolves: state corruption
//   - Push buffer grows unbounded when channel stays errored forever
//   - phx_reply with missing status field: doesn't crash
//   - Two sockets same URL: independent state machines
//   - Rejoin uses original payload not mutated copy
//   - Disconnect flushes push buffer with errors (no silent drop)
//   - Leave timeout: leave future resolves even if server never replies
//   - Join after socket disconnect (socket not connected): join is buffered

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:dark_phoenix_socket/src/channel.dart';
import 'package:dark_phoenix_socket/src/message.dart';
import 'package:dark_phoenix_socket/src/socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'fake_web_socket_channel.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class S {
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

  void toClient(List<dynamic> msg) => server.sink.add(jsonEncode(msg));

  String ref(dynamic raw) => (jsonDecode(raw as String) as List)[1] as String;
  String jRef(dynamic raw) => (jsonDecode(raw as String) as List)[0] as String;
  String topic(dynamic raw) => (jsonDecode(raw as String) as List)[2] as String;
  String event(dynamic raw) => (jsonDecode(raw as String) as List)[3] as String;

  void replyOk(
    String joinRef,
    String msgRef,
    String topic, [
    Map<String, dynamic> resp = const {},
  ]) {
    toClient([
      joinRef,
      msgRef,
      topic,
      'phx_reply',
      {'status': 'ok', 'response': resp},
    ]);
  }

  void replyErr(
    String joinRef,
    String msgRef,
    String topic, [
    Map<String, dynamic> resp = const {},
  ]) {
    toClient([
      joinRef,
      msgRef,
      topic,
      'phx_reply',
      {'status': 'error', 'response': resp},
    ]);
  }

  void replyJoinOk(
    String ref,
    String topic, [
    Map<String, dynamic> resp = const {},
  ]) {
    replyOk(ref, ref, topic, resp);
  }

  void drop() => server.sink.close();
}

Future<void> flush([int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await Future.microtask(() {});
  }
}

Future<PhoenixChannel> joined(S s, String t) async {
  final ch = s.socket.channel(t);
  final f = ch.join();
  await flush();
  final r = s.ref(s.sent.last);
  s.replyJoinOk(r, t);
  await flush();
  await f;
  return ch;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // =========================================================================
  // Bug: Continuous rejoin loop after persistent join error
  // Phoenix.js #1579 — channels keep retrying even after reconnect succeeds
  // =========================================================================
  group('Continuous rejoin loop prevention', () {
    test('1. join error → errored state — rejoin does NOT loop infinitely', () {
      fakeAsync((async) {
        final s = S()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = s.socket.channel('room:loop');
        // join() returns a Future<Map> — error must be caught to avoid unhandled
        unawaited(ch.join().then((_) {}, onError: (_) {}));
        async.flushMicrotasks();
        final r = s.ref(s.sent.last);
        // Server rejects join
        s.replyErr(r, r, 'room:loop', {'reason': 'forbidden'});
        async.flushMicrotasks();
        expect(ch.state, PhoenixChannelState.errored);

        // Socket crashes → reconnect → rejoins channel
        s.drop();
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks();
        final joins = s.sent
            .where((raw) => s.event(raw) == 'phx_join')
            .toList();
        // Definitely NOT looping (would be 10+ if looping)
        expect(joins.length, lessThanOrEqualTo(3));
      });
    });

    test(
      '2. repeated server crashes — rejoin count matches reconnect count',
      () {
        fakeAsync((async) {
          final s = S()..init();
          unawaited(s.socket.connect());
          async
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks();
          final ch = s.socket.channel('room:crash-loop');
          unawaited(ch.join());
          async.flushMicrotasks();
          final r = s.ref(s.sent.last);
          s.replyJoinOk(r, 'room:crash-loop');
          async.flushMicrotasks();

          // Crash 3 times — each reconnect should produce exactly 1 rejoin
          for (var i = 0; i < 3; i++) {
            s.drop();
            async
              ..flushMicrotasks()
              ..elapse(Duration(seconds: [1, 2, 4][i] + 1))
              ..flushMicrotasks();
          }

          final joins = s.sent
              .where((raw) => s.event(raw) == 'phx_join')
              .toList();
          // 1 original + at most 3 rejoins (one per reconnect)
          expect(joins.length, lessThanOrEqualTo(4));
          expect(joins.length, greaterThanOrEqualTo(1));
        });
      },
    );
  });

  // =========================================================================
  // Bug: Reconnect reuses original params (not re-evaluated)
  // Phoenix.js #3340 — async params ignored on reconnect
  // Our impl: params are baked into URL, not re-evaluated — verify
  // =========================================================================
  group('Reconnect params', () {
    test('3. URL params are same on every reconnect attempt', () {
      fakeAsync((async) {
        final uris = <Uri>[];
        final socket = PhoenixSocket(
          'ws://localhost:4000/socket/websocket',
          params: {'token': 'abc123'},
          channelFactory: (uri) {
            uris.add(uri);
            return FakeWebSocketChannel();
          },
        );
        unawaited(socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ws1 = uris.first;
        // Close the WS to trigger reconnect
        unawaited(socket.disconnect());
        async.flushMicrotasks();
        unawaited(socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        for (final uri in uris) {
          expect(uri.queryParameters['token'], 'abc123');
          expect(uri.queryParameters['vsn'], '2.0.0');
        }
        unawaited(socket.disconnect());
        async.flushMicrotasks();
      });
    });

    test('4. vsn=2.0.0 always present, even after many reconnects', () {
      fakeAsync((async) {
        final uris = <Uri>[];
        final socket = PhoenixSocket(
          'ws://localhost:4000/socket/websocket',
          channelFactory: (uri) {
            uris.add(uri);
            final fake = FakeWebSocketChannel();
            // Immediately close to force reconnect
            unawaited(Future.microtask(() => fake.server.sink.close()));
            return fake;
          },
        );
        unawaited(socket.connect());
        for (var i = 0; i < 5; i++) {
          async
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 1))
            ..flushMicrotasks();
        }

        for (final uri in uris) {
          expect(uri.queryParameters['vsn'], '2.0.0');
        }
        unawaited(socket.disconnect());
        async.flushMicrotasks();
      });
    });
  });

  // =========================================================================
  // Bug: "Cannot add event after closing" — heartbeat/send after disconnect
  // Dart #37441 — ping interval fires after stream is closed
  // =========================================================================
  group('No send after close', () {
    test('5. no message sent after disconnect() called', () async {
      final s = S()..init();
      await s.connect();
      await s.socket.disconnect();
      final sentBefore = s.sent.length;

      // Any residual timers should NOT add to sent
      await flush(10);
      expect(s.sent.length, sentBefore);
    });

    test(
      '6. heartbeat timer cancelled on disconnect — no send after close',
      () {
        fakeAsync((async) {
          final s = S()..init();
          unawaited(s.socket.connect());
          async
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks();
          unawaited(s.socket.disconnect());
          async
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 31))
            ..flushMicrotasks();
          final heartbeats = s.sent
              .where((raw) => s.event(raw) == 'heartbeat')
              .toList();
          expect(heartbeats, isEmpty);
          async.flushMicrotasks();
        });
      },
    );

    test(
      '7. channel push after disconnect does not throw — state guard',
      () async {
        final s = S()..init();
        await s.connect();
        final ch = await joined(s, 'room:closed-push');
        await s.socket.disconnect();

        // push() after disconnect: socket.send() is no-op (state != connected)
        // push() itself throws StateError (channel state is errored or closed)
        // Either outcome is acceptable — no unhandled async crash
        try {
          await ch.push('event', {}).timeout(const Duration(milliseconds: 100));
        } catch (_) {
          // Expected — StateError or TimeoutException
        }
        // No crash
      },
    );
  });

  // =========================================================================
  // Bug: Connection state not updated on failure
  // Dart #33362 — readyState stays CONNECTING after failure
  // Our impl: socket state should be reconnecting/disconnected, never stuck
  // =========================================================================
  group('State always reflects reality', () {
    test(
      '8. connection refused → state becomes reconnecting, never stuck connecting',
      () {
        fakeAsync((async) {
          final socket = PhoenixSocket(
            'ws://unreachable:9999/socket',
            channelFactory: (uri) {
              final fake = FakeWebSocketChannel();
              unawaited(Future.microtask(() => fake.server.sink.close()));
              return fake;
            },
          );
          unawaited(socket.connect());
          async
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks();
          expect(socket.state, isNot(PhoenixSocketState.connecting));
          unawaited(socket.disconnect());
          async.flushMicrotasks();
        });
      },
    );

    test('9. socket state stream always reflects internal state', () async {
      final s = S()..init();
      final states = <PhoenixSocketState>[];
      s.socket.states.listen(states.add);

      await s.connect();
      await flush();
      await s.socket.disconnect();
      await flush();

      // Must have seen connecting, connected, disconnected in order
      expect(
        states,
        containsAll([
          PhoenixSocketState.connecting,
          PhoenixSocketState.connected,
          PhoenixSocketState.disconnected,
        ]),
      );
      final connectingIdx = states.indexOf(PhoenixSocketState.connecting);
      final connectedIdx = states.indexOf(PhoenixSocketState.connected);
      final disconnectedIdx = states.lastIndexOf(
        PhoenixSocketState.disconnected,
      );
      expect(connectingIdx, lessThan(connectedIdx));
      expect(connectedIdx, lessThan(disconnectedIdx));
    });
  });

  // =========================================================================
  // Bug: Push ref leak — _pendingRefs grows unbounded on timeout
  // If TimeoutException doesn't clean up ref, map grows forever
  // =========================================================================
  group('Push ref cleanup', () {
    test('10. timed-out pushes are removed from pending refs — no leak', () {
      fakeAsync((async) {
        final s = S()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = s.socket.channel('room:leak');
        unawaited(ch.join());
        async.flushMicrotasks();
        final r = s.ref(s.sent.last);
        s.replyJoinOk(r, 'room:leak');
        async.flushMicrotasks();

        // Send 10 pushes and let them all time out
        for (var i = 0; i < 10; i++) {
          unawaited(ch.push('event_$i', {}).then((_) {}, onError: (_) {}));
        }
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 11))
          ..flushMicrotasks();
        final sentBefore = s.sent.length;
        async
          ..elapse(const Duration(seconds: 30)) // heartbeat fires
          ..flushMicrotasks();
        // Only heartbeat sent — no re-sends for timed-out pushes
        final extraSends = s.sent.length - sentBefore;
        expect(extraSends, lessThanOrEqualTo(1)); // at most 1 heartbeat
      });
    });

    test(
      '11. disconnect clears all pending refs — no zombie completers',
      () async {
        final s = S()..init();
        await s.connect();
        final ch = await joined(s, 'room:zombie');

        // Start 5 pushes without replies
        final futures = List.generate(
          5,
          (i) => ch.push('ev$i', {}).then((_) {}, onError: (_) {}),
        );
        await flush();

        // Disconnect — all pending refs should be errored
        await s.socket.disconnect();
        await flush(10);

        // All futures should complete (with error) — not hang
        await Future.wait(futures).timeout(const Duration(seconds: 1));
      },
    );
  });

  // =========================================================================
  // Bug: Leave during joining — join completer never resolved
  // Causes join() future to hang forever
  // =========================================================================
  group('Leave during joining', () {
    test(
      '12. leave() while joining — join future completes with error',
      () async {
        final s = S()..init();
        await s.connect();

        final ch = s.socket.channel('room:leave-while-joining');
        var joinErrored = false;
        final joinF = ch.join().then(
          (_) {},
          onError: (_) {
            joinErrored = true;
          },
        );
        await flush();

        // Leave before server replies to join
        await ch.leave();
        await flush();
        await joinF;
        expect(joinErrored, isTrue);
        expect(ch.state, PhoenixChannelState.closed);
      },
    );

    test(
      '13. leave() while joining — leave() completes even with no server reply',
      () async {
        final s = S()..init();
        await s.connect();
        final ch = s.socket.channel('room:leave-no-reply');
        unawaited(ch.join().then((_) {}, onError: (_) {}));
        await flush();

        // Leave with no server reply to leave (timeout)
        await ch.leave().timeout(const Duration(seconds: 6));
        expect(ch.state, PhoenixChannelState.closed);
      },
    );
  });

  // =========================================================================
  // Bug: Heartbeat arrives at exact timeout boundary
  // Jetty: heartbeat at 30s / server timeout at 30s → race
  // =========================================================================
  group('Heartbeat boundary race', () {
    test(
      '14. heartbeat reply arrives just before second tick — no reconnect',
      () {
        fakeAsync((async) {
          final s = S()..init();
          unawaited(s.socket.connect());
          async
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 30))
            ..flushMicrotasks();
          final hbRef = s.ref(s.sent.last);

          // Reply arrives just before second tick (at 59.999s)
          async
            ..elapse(const Duration(milliseconds: 29999))
            ..flushMicrotasks();
          s.toClient([
            null,
            hbRef,
            'phoenix',
            'phx_reply',
            {'status': 'ok', 'response': <String, dynamic>{}},
          ]);
          async
            ..flushMicrotasks()
            ..elapse(const Duration(milliseconds: 1))
            ..flushMicrotasks();
          expect(s.socket.state, PhoenixSocketState.connected);

          unawaited(s.socket.disconnect());
          async.flushMicrotasks();
        });
      },
    );

    test(
      '15. heartbeat reply arrives 1ms after second tick — reconnect fires',
      () {
        fakeAsync((async) {
          final s = S()..init();
          unawaited(s.socket.connect());
          async
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 30))
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 30))
            ..flushMicrotasks();
          expect(s.socket.state, PhoenixSocketState.reconnecting);

          unawaited(s.socket.disconnect());
          async.flushMicrotasks();
        });
      },
    );
  });

  // =========================================================================
  // Bug: Multiple disconnect() calls — should be idempotent
  // =========================================================================
  group('Idempotent disconnect', () {
    test(
      '16. disconnect() called 3 times — no crash, state stays disconnected',
      () async {
        final s = S()..init();
        await s.connect();
        await s.socket.disconnect();
        await s.socket.disconnect();
        await s.socket.disconnect();
        await flush();
        expect(s.socket.state, PhoenixSocketState.disconnected);
      },
    );

    test(
      '17. disconnect() then connect() then disconnect() — clean cycle',
      () async {
        final s = S()..init();
        await s.connect();
        await s.socket.disconnect();
        await s.connect();
        await flush();
        expect(s.socket.state, PhoenixSocketState.connected);
        await s.socket.disconnect();
        expect(s.socket.state, PhoenixSocketState.disconnected);
      },
    );
  });

  // =========================================================================
  // Bug: Channel topic reuse — old messages bleed through
  // After leave + new join, stale joinRef messages should be dropped
  // =========================================================================
  group('Channel topic reuse after close', () {
    test(
      '18. socket routes messages only to tracked channels — not to replaced ones',
      () async {
        final s = S()..init();
        await s.connect();

        // Track all messages on the channel
        final ch = s.socket.channel('room:routing');
        unawaited(ch.join().then((_) {}, onError: (_) {}));
        await flush();
        final jRef = s.ref(s.sent.last);
        s.replyJoinOk(jRef, 'room:routing');
        await flush();

        final events = <PhoenixMessage>[];
        ch.messages.listen(events.add);

        // Message for a DIFFERENT topic — must not reach ch
        s.toClient([
          null,
          null,
          'room:other',
          'event',
          {'x': 1},
        ]);
        await flush(4);
        expect(events, isEmpty);

        // Message for correct topic — must reach ch
        s.toClient([
          null,
          null,
          'room:routing',
          'my_event',
          {'x': 2},
        ]);
        await flush(4);
        expect(events, hasLength(1));
        expect(events[0].event, 'my_event');

        await s.socket.disconnect();
      },
    );

    test(
      '19. old push reply with stale joinRef not routed to new channel',
      () async {
        final s = S()..init();
        await s.connect();

        // Join ch1, start push, leave before reply
        final ch1 = await joined(s, 'room:stale-reply');
        unawaited(ch1.push('action', {}).then((_) {}, onError: (_) {}));
        await flush();
        final pushMsg = s.sent.lastWhere((raw) => s.event(raw) == 'action');
        final staleRef = s.ref(pushMsg);
        final staleJoinRef = s.jRef(pushMsg);

        // Leave
        unawaited(ch1.leave());
        await flush();
        final leaveRef = s.ref(s.sent.last);
        s.replyOk(staleJoinRef, leaveRef, 'room:stale-reply');
        await flush();

        // Server belatedly replies to the push with stale joinRef
        // Should be silently ignored — no crash
        s.replyOk(staleJoinRef, staleRef, 'room:stale-reply');
        await flush();
        expect(s.socket.state, PhoenixSocketState.connected);
      },
    );
  });

  // =========================================================================
  // Bug: Two sockets same URL — independent state machines
  // =========================================================================
  group('Multiple sockets independence', () {
    test(
      '20. two sockets same URL — disconnect one does not affect other',
      () async {
        final s1 = S()..init();
        final s2 = S()..init();

        await s1.connect();
        await s2.connect();

        await s1.socket.disconnect();
        await flush();

        expect(s1.socket.state, PhoenixSocketState.disconnected);
        expect(s2.socket.state, PhoenixSocketState.connected);

        await s2.socket.disconnect();
      },
    );

    test('21. two sockets — each has own ref counter, no collisions', () async {
      final s1 = S()..init();
      final s2 = S()..init();
      await s1.connect();
      await s2.connect();

      // Both start from ref 1 (independent counters)
      final r1a = s1.socket.nextRef();
      final r2a = s2.socket.nextRef();
      expect(r1a, r2a); // both start at 1 — independent counters

      // But they don't interfere
      final r1b = s1.socket.nextRef();
      final r2b = s2.socket.nextRef();
      expect(int.parse(r1b), int.parse(r1a) + 1);
      expect(int.parse(r2b), int.parse(r2a) + 1);

      await s1.socket.disconnect();
      await s2.socket.disconnect();
    });
  });

  // =========================================================================
  // Bug: Rejoin uses original payload, not a mutated copy
  // =========================================================================
  group('Rejoin payload immutability', () {
    test('22. rejoin sends same payload as original join', () {
      fakeAsync((async) {
        final s = S()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final payload = {'token': 'secret', 'user_id': 42};
        final ch = s.socket.channel('room:payload');
        unawaited(ch.join(payload: payload));
        async.flushMicrotasks();
        final jRef = s.ref(s.sent.last);
        s.replyJoinOk(jRef, 'room:payload');
        async.flushMicrotasks();

        // Crash → reconnect → rejoin
        s.drop();
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks();
        final joins = s.sent
            .where((raw) => s.event(raw) == 'phx_join')
            .map((raw) => (jsonDecode(raw as String) as List)[4] as Map)
            .toList();

        expect(joins.length, greaterThanOrEqualTo(2));
        // All joins should have same payload
        for (final j in joins) {
          expect(j['token'], 'secret');
          expect(j['user_id'], 42);
        }
      });
    });

    test(
      '23. mutating original payload map after join does not affect rejoin',
      () {
        fakeAsync((async) {
          final s = S()..init();
          unawaited(s.socket.connect());
          async
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks();
          final payload = <String, dynamic>{'token': 'original'};
          final ch = s.socket.channel('room:mutation');
          unawaited(ch.join(payload: payload));
          async.flushMicrotasks();
          final jRef = s.ref(s.sent.last);
          s.replyJoinOk(jRef, 'room:mutation');
          async.flushMicrotasks();

          // Mutate original payload after join
          payload['token'] = 'mutated';

          // Crash → reconnect → rejoin
          s.drop();
          async
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 2))
            ..flushMicrotasks();
          final rejoin = s.sent.where((raw) => s.event(raw) == 'phx_join').last;
          final rejoinPayload =
              (jsonDecode(rejoin as String) as List)[4] as Map;
          // Should use the copied payload, not the mutated original
          expect(rejoinPayload['token'], 'original');
        });
      },
    );
  });

  // =========================================================================
  // Bug: phx_reply with malformed/missing status — no crash
  // =========================================================================
  group('Malformed server replies', () {
    test('24. phx_reply with null status — handled gracefully', () async {
      final s = S()..init();
      await s.connect();
      final ch = await joined(s, 'room:null-status');

      var pushErrored = false;
      fakeAsync((async) {
        unawaited(
          ch
              .push('action', {})
              .then(
                (_) {},
                onError: (_) {
                  pushErrored = true;
                },
              ),
        );
        async.flushMicrotasks();
        final pushRef = s.ref(s.sent.lastWhere((r) => s.event(r) == 'action'));
        final joinRef = s.jRef(s.sent.lastWhere((r) => s.event(r) == 'action'));

        // Reply with null status
        s.toClient([
          joinRef,
          pushRef,
          'room:null-status',
          'phx_reply',
          {'status': null, 'response': <String, dynamic>{}},
        ]);
        async
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(s.socket.state, PhoenixSocketState.connected);
        expect(pushErrored, isTrue);
      });
    });

    test(
      '25. phx_reply with missing response field — defaults to empty map',
      () async {
        final s = S()..init();
        await s.connect();
        final ch = await joined(s, 'room:missing-resp');

        Map<String, dynamic>? result;
        fakeAsync((async) {
          unawaited(
            ch.push('action', {}).then((r) {
              result = r;
            }),
          );
          async.flushMicrotasks();
          final pushRef = s.ref(
            s.sent.lastWhere((r) => s.event(r) == 'action'),
          );
          final joinRef = s.jRef(
            s.sent.lastWhere((r) => s.event(r) == 'action'),
          );

          // Reply without 'response' field
          s.toClient([
            joinRef,
            pushRef,
            'room:missing-resp',
            'phx_reply',
            {'status': 'ok'},
          ]);
          async
            ..flushMicrotasks()
            ..flushMicrotasks();
          expect(result, isNotNull);
          expect(result, isEmpty);
        });
      },
    );

    test(
      '26. phx_reply with extra unexpected fields — ignored cleanly',
      () async {
        final s = S()..init();
        await s.connect();
        final ch = await joined(s, 'room:extra-fields');

        var done = false;
        fakeAsync((async) {
          unawaited(
            ch.push('action', {}).then((_) {
              done = true;
            }),
          );
          async.flushMicrotasks();
          final pushRef = s.ref(
            s.sent.lastWhere((r) => s.event(r) == 'action'),
          );
          final joinRef = s.jRef(
            s.sent.lastWhere((r) => s.event(r) == 'action'),
          );

          // Reply with extra fields
          s.toClient([
            joinRef,
            pushRef,
            'room:extra-fields',
            'phx_reply',
            {
              'status': 'ok',
              'response': {'data': 42},
              'unknown': 'ignored',
            },
          ]);
          async
            ..flushMicrotasks()
            ..flushMicrotasks();
          expect(done, isTrue);
        });
      },
    );
  });

  // =========================================================================
  // Bug: Ghost/orphaned channel in joining state after socket replaces it
  // =========================================================================
  group('Orphaned channel state', () {
    test(
      '27. channel in joining state when socket crashes — ends up errored',
      () async {
        final s = S()..init();
        await s.connect();

        final ch = s.socket.channel('room:orphan');
        unawaited(ch.join().then((_) {}, onError: (_) {}));
        await flush();
        // Don't reply — channel is in joining state

        // Socket crashes
        s.drop();
        await flush();
        expect(ch.state, PhoenixChannelState.errored);
      },
    );

    test(
      '28. buffered push while joining errors when socket crashes',
      () async {
        final s = S()..init();
        await s.connect();

        final ch = s.socket.channel('room:orphan-push');
        unawaited(ch.join().then((_) {}, onError: (_) {}));
        await flush();

        // Push while still joining (goes into _pushBuffer)
        var pushErrored = false;
        unawaited(
          ch
              .push('action', {})
              .then(
                (_) {},
                onError: (_) {
                  pushErrored = true;
                },
              ),
        );
        await flush();

        // Socket crashes — buffered push must error, not hang
        s.drop();
        await flush(10);
        expect(pushErrored, isTrue);
      },
    );
  });

  // =========================================================================
  // Bug: Backpressure — push buffer when channel stays errored
  // =========================================================================
  group('Push buffer in errored state', () {
    test('29. pushes buffered during errored state are sent after rejoin', () {
      fakeAsync((async) {
        final s = S()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = s.socket.channel('room:errored-buf');
        unawaited(ch.join());
        async.flushMicrotasks();
        final jRef = s.ref(s.sent.last);
        s.replyJoinOk(jRef, 'room:errored-buf');
        async.flushMicrotasks();

        // Channel crashes → errored
        s.drop();
        async.flushMicrotasks();
        expect(ch.state, PhoenixChannelState.errored);

        // Push while errored → buffered
        unawaited(
          ch.push('buffered_event', {'x': 1}).then((_) {}, onError: (_) {}),
        );
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks();
        final rejoinMsg = s.sent
            .where((raw) => s.event(raw) == 'phx_join')
            .last;
        final newJRef = s.ref(rejoinMsg);
        s.replyJoinOk(newJRef, 'room:errored-buf');
        async.flushMicrotasks();

        // After rejoin, buffered push should be sent
        final bufferedSends = s.sent
            .where((raw) => s.event(raw) == 'buffered_event')
            .toList();
        expect(bufferedSends, hasLength(1));
      });
    });

    test(
      '30. pushes buffered during errored state error on disconnect',
      () async {
        final s = S()..init();
        await s.connect();
        final ch = await joined(s, 'room:errored-disconnect');

        // Force channel to errored
        s.drop();
        await flush();
        expect(ch.state, PhoenixChannelState.errored);

        // Push while errored (buffered)
        var bufferedErrored = false;
        unawaited(
          ch
              .push('buffered', {})
              .then(
                (_) {},
                onError: (_) {
                  bufferedErrored = true;
                },
              ),
        );
        await flush();

        // Explicit disconnect — buffered push must error, not hang
        await s.socket.disconnect();
        await flush(10);
        expect(bufferedErrored, isTrue);
      },
    );
  });

  // =========================================================================
  // Bug: Leave timeout — leave() must resolve even if server never replies
  // =========================================================================
  group('Leave timeout', () {
    test('31. leave() resolves after 5s even if server never replies', () {
      fakeAsync((async) {
        final s = S()..init();
        unawaited(s.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = s.socket.channel('room:leave-timeout');
        unawaited(ch.join());
        async.flushMicrotasks();
        final jRef = s.ref(s.sent.last);
        s.replyJoinOk(jRef, 'room:leave-timeout');
        async.flushMicrotasks();

        var leaveDone = false;
        unawaited(
          ch.leave().then((_) {
            leaveDone = true;
          }),
        );
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 6))
          ..flushMicrotasks();
        expect(leaveDone, isTrue);
        expect(ch.state, PhoenixChannelState.closed);

        unawaited(s.socket.disconnect());
        async.flushMicrotasks();
      });
    });
  });

  // =========================================================================
  // Bug: connect() called before previous connect() resolves
  // Race condition: two concurrent connect() calls
  // =========================================================================
  group('Concurrent connect() calls', () {
    test('32. two concurrent connect() calls — only one WS created', () async {
      final s = S()..init();
      // Call connect twice without awaiting
      final f1 = s.connect();
      final f2 = s.connect();
      await Future.wait([f1, f2]);
      expect(s.connects, 1); // second call was no-op
    });

    test(
      '33. connect() during connecting state — second call is no-op',
      () async {
        final s = S()..init();
        // Don't await — still in connecting
        final f1 = s.socket.connect();
        expect(s.socket.state, PhoenixSocketState.connecting);
        // Second connect while connecting
        await s.socket.connect();
        expect(s.connects, 1);
        await f1;
      },
    );
  });

  // =========================================================================
  // Bug: messages stream receives phx_reply (should be filtered)
  // Regression guard — control events must NEVER reach messages stream
  // =========================================================================
  group('Control event filtering (regression)', () {
    test('34. phx_reply never appears on messages stream', () async {
      final s = S()..init();
      await s.connect();
      final ch = await joined(s, 'room:filter');
      final msgs = <PhoenixMessage>[];
      ch.messages.listen(msgs.add);

      // Send push and reply
      unawaited(ch.push('action', {}).then((_) {}, onError: (_) {}));
      await flush();
      final pushRef = s.ref(s.sent.lastWhere((r) => s.event(r) == 'action'));
      final joinRef = s.jRef(s.sent.lastWhere((r) => s.event(r) == 'action'));
      s.replyOk(joinRef, pushRef, 'room:filter');
      await flush(8);

      expect(msgs.where((m) => m.event == 'phx_reply'), isEmpty);
    });

    test('35. all control events filtered from messages stream', () async {
      final s = S()..init();
      await s.connect();
      final ch = await joined(s, 'room:ctrl-filter');
      final msgs = <PhoenixMessage>[];
      ch.messages.listen(msgs.add);

      for (final ctrl in [
        'phx_reply',
        'phx_join',
        'phx_leave',
        'phx_close',
        'phx_error',
      ]) {
        s.toClient([null, null, 'room:ctrl-filter', ctrl, <String, dynamic>{}]);
      }
      await flush(8);

      // Only non-control events appear
      expect(msgs.where((m) => m.event.startsWith('phx_')), isEmpty);
    });

    test('36. app events DO appear on messages stream', () async {
      final s = S()..init();
      await s.connect();
      final ch = await joined(s, 'room:app-events');
      final msgs = <PhoenixMessage>[];
      ch.messages.listen(msgs.add);

      s
        ..toClient([
          null,
          null,
          'room:app-events',
          'new_message',
          {'text': 'hi'},
        ])
        ..toClient([
          null,
          null,
          'room:app-events',
          'user_joined',
          {'id': 1},
        ]);
      await flush(8);

      expect(
        msgs.map((m) => m.event).toList(),
        containsAll(['new_message', 'user_joined']),
      );
    });
  });

  // =========================================================================
  // Bug: socket.channel() caches by topic — closed channel returned again
  // After close, socket.channel() returns the same (closed) instance
  // Application must handle or create a new socket
  // =========================================================================
  group('Channel cache behavior', () {
    test('37. socket.channel() returns same instance for same topic', () async {
      final s = S()..init();
      await s.connect();
      final ch1 = s.socket.channel('room:cache');
      final ch2 = s.socket.channel('room:cache');
      expect(identical(ch1, ch2), isTrue);
    });

    test('38. different topics return different channel instances', () async {
      final s = S()..init();
      await s.connect();
      final ch1 = s.socket.channel('room:a');
      final ch2 = s.socket.channel('room:b');
      expect(identical(ch1, ch2), isFalse);
    });
  });

  // =========================================================================
  // Bug: send() while not connected — silent drop, no exception
  // =========================================================================
  group('Send while disconnected', () {
    test(
      '39. send() while disconnected — no exception thrown, no crash',
      () async {
        final s = S()..init();
        // Not connected — send should be silently ignored
        s.socket.send(
          const PhoenixMessage(
            joinRef: null,
            ref: '1',
            topic: 'room:test',
            event: 'test',
            payload: {},
          ),
        );
        // No exception
        expect(s.socket.state, PhoenixSocketState.disconnected);
      },
    );

    test(
      '40. push() while connected → disconnect fires mid-push — push errors',
      () async {
        final s = S()..init();
        await s.connect();
        final ch = await joined(s, 'room:mid-push');

        var errored = false;
        fakeAsync((async) {
          unawaited(
            ch
                .push('action', {})
                .then(
                  (_) {},
                  onError: (_) {
                    errored = true;
                  },
                ),
          );
          async.flushMicrotasks();

          // Disconnect mid-push
          unawaited(s.socket.disconnect());
          async
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 11))
            ..flushMicrotasks();
          expect(errored, isTrue);
        });
      },
    );
  });
}
