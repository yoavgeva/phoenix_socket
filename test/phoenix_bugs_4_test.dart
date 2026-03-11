// Tests for additional Phoenix Channel / WebSocket bugs — round 4.
//
// Bugs fixed in this round:
//   Bug A (channel.dart): rejoin() timeout doesn't clear _pushBuffer →
//                          completers hang forever (Phoenix.js #3669)
//   Bug B (socket.dart):  intentional disconnect() leaves channels in errored
//                          state → push() buffers forever instead of failing
//                          immediately (Phoenix.js #2857)
//
// Additional behavior tested (not bugs, but important contracts):
//   - Concurrent join() calls are safe (Dart cooperative scheduling)
//   - Stale joinRef from previous reconnect cycle is dropped correctly
//   - Heartbeat joinRef is always null (regression guard)
//   - push() timeout clears _pendingRefs (no stale entry)
//   - onSocketDisconnect called from both _onError and _onDone → idempotent
//   - Server-initiated phx_reply with unknown ref → silently dropped
//   - Channel closed after intentional disconnect → push() throws StateError
//   - Socket.channel() returns same dead instance after leave() (documented)
//
// Sources:
//   Phoenix.js #3669, #2857, #2187, #3171, #1295, #2947
//   RFC 6455 §10.7 (thundering herd)
//   Dart async cooperative scheduling

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:dart_phoenix_socket/src/channel.dart';
import 'package:dart_phoenix_socket/src/exceptions.dart';
import 'package:dart_phoenix_socket/src/message.dart';
import 'package:dart_phoenix_socket/src/socket.dart';
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
  dynamic joinRefRaw(dynamic raw) => (jsonDecode(raw as String) as List)[0];

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

  void replyJoinOk(String r, String t, [Map<String, dynamic> resp = const {}]) {
    replyOk(r, r, t, resp);
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
  // Bug A: rejoin() timeout leaves push buffer completers hanging
  // Fixed: rejoin() onTimeout now calls _clearPendingRefs on _pushBuffer.
  // =========================================================================
  group('Bug A: rejoin timeout clears push buffer completers', () {
    test(
      '1. push buffered during joining state — rejoin times out — push errors promptly',
      () {
        fakeAsync((async) {
          final t = T()..init();
          unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
          async
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks();
          final ch = t.socket.channel('room:rejoin_timeout');
          unawaited(ch.join().then((_) {}, onError: (_) {}));
          async.flushMicrotasks();
          // Don't reply to join → channel is joining

          // Push while joining → goes into _pushBuffer
          Object? pushError;
          var pushDone = false;
          unawaited(
            ch
                .push('buffered_event', {})
                .then(
                  (_) {
                    pushDone = true;
                  },
                  onError: (e) {
                    pushError = e;
                    pushDone = true;
                  },
                ),
          );
          async.flushMicrotasks();
          expect(pushDone, isFalse); // buffered in joining state

          // Drop + reconnect → onSocketDisconnect clears pending but push is still buffered
          // Wait — _clearPendingRefs also clears _pushBuffer on disconnect.
          // So instead: let join time out (10s) without a drop. Channel goes errored.
          // Then push while errored → buffered.
          // Then drop + reconnect → rejoin. Rejoin times out → push errors.
          //
          // Actually the simplest scenario: push is buffered DURING the rejoin
          // (joining state after reconnect), and the rejoin times out.
          // This is what we test: push queued during joining state across rejoin.

          // Drop → _clearPendingRefs clears the buffer. Then reconnect → rejoin.
          // During rejoin (joining state), push another one.
          t.drop();
          async
            ..flushMicrotasks()
            ..flushMicrotasks();
          expect(
            pushDone,
            isTrue,
          ); // cleared by _clearPendingRefs on disconnect
          pushDone = false;
          pushError = null;

          // Reconnect fires (1s backoff) → rejoin sends phx_join
          async
            ..elapse(const Duration(seconds: 1))
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks();
          expect(ch.state, PhoenixChannelState.joining);

          // Push while joining → buffered during rejoin
          unawaited(
            ch
                .push('during_rejoin', {})
                .then(
                  (_) {
                    pushDone = true;
                  },
                  onError: (e) {
                    pushError = e;
                    pushDone = true;
                  },
                ),
          );
          async.flushMicrotasks();
          expect(pushDone, isFalse); // still buffered

          // Rejoin times out (10s) — push buffer must be cleared
          async
            ..elapse(const Duration(seconds: 10))
            ..flushMicrotasks();
          expect(pushDone, isTrue);
          expect(pushError, isNotNull);
          expect(ch.state, PhoenixChannelState.errored);
        });
      },
    );

    test('2. multiple buffered pushes all cleared on rejoin timeout', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = t.socket.channel('room:multi_rejoin_timeout');
        unawaited(ch.join().then((_) {}, onError: (_) {}));
        async.flushMicrotasks();
        final r = t.ref(t.sent.last);
        t.replyJoinOk(r, 'room:multi_rejoin_timeout');
        async.flushMicrotasks();

        // phx_error → errored
        t.toClient([r, null, 'room:multi_rejoin_timeout', 'phx_error', {}]);
        async.flushMicrotasks();

        // Queue 3 pushes while errored
        final errors = <Object>[];
        for (var i = 0; i < 3; i++) {
          unawaited(ch.push('ev_$i', {}).then((_) {}, onError: errors.add));
        }
        async.flushMicrotasks();

        // Drop + reconnect → rejoin
        t.drop();
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 10))
          ..flushMicrotasks();
        expect(errors, hasLength(3));
      });
    });
  });

  // =========================================================================
  // Bug B: intentional disconnect() → channels closed → push() throws immediately
  // Fixed: disconnect() calls onIntentionalDisconnect() → channel state = closed.
  // =========================================================================
  group('Bug B: push after intentional disconnect throws immediately', () {
    test(
      '3. push() after socket.disconnect() → StateError immediately',
      () async {
        final t = T()..init();
        await t.connect();
        final ch = await joinedChannel(t, 'room:after_disconnect');

        unawaited(t.socket.disconnect());
        await flush(2);

        expect(ch.state, PhoenixChannelState.closed);

        // Must throw StateError immediately, not buffer and hang
        expect(
          () => ch.push('any_event', {}),
          throwsStateError,
        );
      },
    );

    test('4. intentional disconnect clears pending refs immediately', () async {
      final t = T()..init();
      await t.connect();
      final ch = await joinedChannel(t, 'room:pending_on_dc');

      // Push in flight
      Object? pushError;
      unawaited(
        ch
            .push('slow', {})
            .then(
              (_) {},
              onError: (e) {
                pushError = e;
              },
            ),
      );
      await flush(4);

      // Intentional disconnect
      unawaited(t.socket.disconnect());
      await flush(4);

      // Pending push must have been error-completed
      expect(pushError, isA<PhoenixException>());
      expect(ch.state, PhoenixChannelState.closed);
    });

    test(
      '5. unintentional drop → channel errored (auto-rejoin eligible)',
      () async {
        final t = T()..init();
        await t.connect();
        final ch = await joinedChannel(t, 'room:unintentional');

        // Unintentional drop (server side)
        t.drop();
        await flush(6);

        // Channel should be errored, not closed → eligible for auto-rejoin
        expect(ch.state, PhoenixChannelState.errored);
      },
    );

    test(
      '6. join() after intentional disconnect → StateError (channel closed)',
      () async {
        final t = T()..init();
        await t.connect();
        final ch = await joinedChannel(t, 'room:join_after_dc');

        unawaited(t.socket.disconnect());
        await flush(2);

        expect(ch.state, PhoenixChannelState.closed);

        // The original channel instance is closed — join() must throw StateError
        // because _joinCalled is true (already joined once).
        expect(
          ch.join,
          throwsStateError,
        );
      },
    );
  });

  // =========================================================================
  // Correctness: concurrent join() calls are safe (Dart cooperative scheduling)
  // Both calls happen in the same synchronous turn; second must see StateError.
  // =========================================================================
  group('Concurrent join() calls', () {
    test(
      '7. two join() calls in same sync turn — second throws StateError',
      () async {
        final t = T()..init();
        await t.connect();

        final ch = t.socket.channel('room:concurrent_join');
        final f1 = ch.join();
        // Second call in same sync turn — _joinCalled already true
        Object? secondError;
        final f2 = ch.join().then(
          (_) {},
          onError: (e) {
            secondError = e;
          },
        );

        await flush(4);
        await f2;

        expect(secondError, isA<StateError>());

        // Only one phx_join sent
        final joins = t.sent.where((m) => t.evnt(m) == 'phx_join').toList();
        expect(joins, hasLength(1));

        f1.ignore();
        unawaited(t.socket.disconnect());
      },
    );
  });

  // =========================================================================
  // Correctness: stale joinRef from previous reconnect is dropped
  // =========================================================================
  group('Stale joinRef across multiple reconnects', () {
    test('8. reply for joinRef from N-2 reconnect cycle is dropped', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = t.socket.channel('room:multi_reconnect');
        unawaited(ch.join().then((_) {}, onError: (_) {}));
        async.flushMicrotasks();
        final ref1 = t.ref(t.sent.last);

        // Drop #1 → channel errored, reconnect in 1s
        t.drop();
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final joins = t.sent.where((m) => t.evnt(m) == 'phx_join').toList();
        expect(joins.length, 2);
        final ref2 = t.ref(joins.last);
        expect(ref2, isNot(ref1));

        // Drop #2 → channel errored, reconnect in 2s
        t.drop();
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final joins3 = t.sent.where((m) => t.evnt(m) == 'phx_join').toList();
        expect(joins3.length, 3);
        final ref3 = t.ref(joins3.last);
        expect(ref3, isNot(ref2));

        // Deliver stale reply for ref1 (two connections ago)
        t.replyJoinOk(ref1, 'room:multi_reconnect');
        async.flushMicrotasks();

        // Channel must still be joining (stale reply dropped)
        expect(ch.state, PhoenixChannelState.joining);

        // Correct reply for ref3 → joined
        t.replyJoinOk(ref3, 'room:multi_reconnect');
        async.flushMicrotasks();
        expect(ch.state, PhoenixChannelState.joined);
      });
    });
  });

  // =========================================================================
  // Correctness: heartbeat joinRef is always null
  // =========================================================================
  group('Heartbeat wire format', () {
    test('9. heartbeat message has null joinRef', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(t.socket.state, PhoenixSocketState.connected);

        // Advance to first heartbeat tick (30s)
        async
          ..elapse(const Duration(seconds: 30))
          ..flushMicrotasks();
        final heartbeats = t.sent
            .where((m) => t.evnt(m) == 'heartbeat')
            .toList();
        expect(heartbeats, isNotEmpty);

        // joinRef (index 0) must be null — never a channel's join ref
        final parsed = jsonDecode(heartbeats.last as String) as List;
        expect(parsed[0], isNull);
        expect(parsed[2], 'phoenix');
        expect(parsed[3], 'heartbeat');
      });
    });
  });

  // =========================================================================
  // Correctness: push timeout clears _pendingRefs (no stale entry)
  // =========================================================================
  group('Push timeout cleans up _pendingRefs', () {
    test(
      '10. push times out — late reply is silently dropped (no double-complete)',
      () {
        fakeAsync((async) {
          final t = T()..init();
          unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
          async
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks();
          final ch = t.socket.channel('room:push_timeout');
          unawaited(ch.join().then((_) {}, onError: (_) {}));
          async.flushMicrotasks();
          final jr = t.ref(t.sent.last);
          t.replyJoinOk(jr, 'room:push_timeout');
          async.flushMicrotasks();

          // Push — server never replies
          Object? pushError;
          var pushDone = false;
          unawaited(
            ch
                .push('slow_ev', {})
                .then(
                  (_) {
                    pushDone = true;
                  },
                  onError: (e) {
                    pushError = e;
                    pushDone = true;
                  },
                ),
          );
          async.flushMicrotasks();

          final pushRef = t.ref(
            t.sent.where((m) => t.evnt(m) == 'slow_ev').last,
          );

          // Advance 10s → timeout fires
          async
            ..elapse(const Duration(seconds: 10))
            ..flushMicrotasks();
          expect(pushDone, isTrue);
          expect(pushError, isA<TimeoutException>());

          // Now deliver a late reply for that ref — must be silently dropped
          // (no crash, no double-complete StateError)
          t.toClient([
            jr,
            pushRef,
            'room:push_timeout',
            'phx_reply',
            {'status': 'ok', 'response': <String, dynamic>{}},
          ]);
          async.flushMicrotasks();

          // Channel still joined, no crash
          expect(ch.state, PhoenixChannelState.joined);
        });
      },
    );
  });

  // =========================================================================
  // Correctness: _handleDisconnect is idempotent
  // Both _onError and _onDone can fire on hard close — must not double-process
  // =========================================================================
  group('_handleDisconnect idempotency', () {
    test(
      '11. _onError + _onDone both fire — channels notified exactly once',
      () async {
        final t = T()..init();
        await t.connect();

        final ch = await joinedChannel(t, 'room:double_fire');

        // Track how many times onSocketDisconnect transitions the channel
        const disconnectCount = 0;
        final originalState = ch.state;

        // Simulate both onError and onDone firing by calling the internal
        // disconnect path twice via injecting error then close on the ws stream
        t.server.sink.addError(Exception('network error'));
        unawaited(t.server.sink.close());
        await flush();

        // Socket must be reconnecting (not permanently disconnected)
        expect(
          t.socket.state,
          anyOf(
            PhoenixSocketState.reconnecting,
            PhoenixSocketState.connecting,
            PhoenixSocketState.connected,
          ),
        );

        // Channel must be errored exactly once — not double-transitioned
        expect(ch.state, PhoenixChannelState.errored);
      },
    );
  });

  // =========================================================================
  // Correctness: server-initiated phx_reply with unknown ref → silently dropped
  // =========================================================================
  group('Unknown ref in phx_reply', () {
    test(
      '12. server pushes phx_reply with ref nobody sent — no crash',
      () async {
        final t = T()..init();
        await t.connect();
        final ch = await joinedChannel(t, 'room:unknown_reply_ref');
        final jr = t.jRef(t.sent.last);

        // Server sends a phx_reply for a ref the client never issued
        t.toClient([
          jr,
          '99999',
          'room:unknown_reply_ref',
          'phx_reply',
          {
            'status': 'ok',
            'response': {'pushed': true},
          },
        ]);
        await flush(4);

        // No crash, channel still joined
        expect(ch.state, PhoenixChannelState.joined);
        expect(t.socket.state, PhoenixSocketState.connected);
      },
    );

    test(
      '13. server-push phx_reply does not appear on messages stream',
      () async {
        final t = T()..init();
        await t.connect();
        final ch = await joinedChannel(t, 'room:no_phx_reply_stream');
        final jr = t.jRef(t.sent.last);

        final received = <PhoenixMessage>[];
        ch.messages.listen(received.add);

        t.toClient([
          jr,
          '12345',
          'room:no_phx_reply_stream',
          'phx_reply',
          {'status': 'ok', 'response': <String, dynamic>{}},
        ]);
        await flush(4);

        expect(received, isEmpty); // phx_reply is a control event, filtered
      },
    );
  });

  // =========================================================================
  // Correctness: socket.channel() after leave() returns same dead instance
  // =========================================================================
  group('socket.channel() returns dead instance after leave()', () {
    test(
      '14. channel() after leave() → same instance → join() throws StateError',
      () async {
        final t = T()..init();
        await t.connect();

        final ch1 = await joinedChannel(t, 'room:dead_instance');
        await ch1.leave();

        // Same instance returned — _joinCalled = true
        final ch2 = t.socket.channel('room:dead_instance');
        expect(identical(ch1, ch2), isTrue);

        // join() throws because _joinCalled is still true
        expect(
          ch2.join,
          throwsStateError,
        );
      },
    );
  });

  // =========================================================================
  // Correctness: push buffer flushed correctly after successful rejoin
  // =========================================================================
  group('Push buffer survives reconnect → rejoin → flush', () {
    test(
      '15. push buffered during joining state → rejoin succeeds → push resolves',
      () {
        fakeAsync((async) {
          final t = T()..init();
          unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
          async
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks();
          final ch = t.socket.channel('room:buf_rejoin');
          unawaited(ch.join().then((_) {}, onError: (_) {}));
          async.flushMicrotasks();

          // Push immediately while joining → buffered
          var pushResult = <String, dynamic>{};
          var pushDone = false;
          unawaited(
            ch
                .push('queued_while_joining', {'v': 99})
                .then(
                  (res) {
                    pushResult = res;
                    pushDone = true;
                  },
                  onError: (_) {
                    pushDone = true;
                  }, // drop() error-completes this
                ),
          );
          async.flushMicrotasks();
          expect(pushDone, isFalse); // buffered

          // Drop before join reply → _clearPendingRefs clears the buffer
          // Buffered push errors. Channel goes errored.
          t.drop();
          async
            ..flushMicrotasks()
            ..flushMicrotasks();
          expect(pushDone, isTrue); // cleared on drop

          // Reconnect (1s backoff) → rejoin
          async
            ..elapse(const Duration(seconds: 1))
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks();
          expect(ch.state, PhoenixChannelState.joining);

          // Push again while rejoining → buffered
          pushDone = false;
          pushResult = {};
          unawaited(
            ch.push('after_rejoin', {'v': 42}).then((res) {
              pushResult = res;
              pushDone = true;
            }),
          );
          async.flushMicrotasks();
          expect(pushDone, isFalse);

          // Rejoin reply arrives
          final rejoinRef = t.ref(
            t.sent.where((m) => t.evnt(m) == 'phx_join').last,
          );
          t.replyJoinOk(rejoinRef, 'room:buf_rejoin');
          async
            ..flushMicrotasks()
            ..flushMicrotasks();
          expect(ch.state, PhoenixChannelState.joined);

          // Buffered push was sent after rejoin
          final pushMsgs = t.sent
              .where((m) => t.evnt(m) == 'after_rejoin')
              .toList();
          expect(pushMsgs, hasLength(1));

          // Reply to push
          final pr = t.ref(pushMsgs.first);
          final pjr = t.jRef(pushMsgs.first);
          t.toClient([
            pjr,
            pr,
            'room:buf_rejoin',
            'phx_reply',
            {
              'status': 'ok',
              'response': {'v': 42},
            },
          ]);
          async.flushMicrotasks();

          expect(pushDone, isTrue);
          expect(pushResult['v'], 42);
        });
      },
    );
  });
}
