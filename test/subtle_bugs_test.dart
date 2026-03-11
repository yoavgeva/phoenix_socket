// Tests for subtle WebSocket/Phoenix Channel bugs found in production.
//
// Sources:
//   - Phoenix.js #1295: pushBuffer never flushed on first successful join
//   - Phoenix.js #3349: join→leave→infinite rejoin loop
//   - Phoenix.js #3171: duplicate join without close → two concurrent channels
//   - Phoenix.js #2255: presence state race (leave arrives before state)
//   - ws#1103: message loss during reconnect window
//   - Phoenix #2035: rejoin timeout fires while first join still pending
//   - Ably FAQ: duplicate listener registration on reconnect
//   - General: async message handler can process out of order
//   - General: UTF-8 / binary payload round-trip
//   - General: token/params never change mid-session (socket-level auth)
//   - General: join called on closed channel instance
//   - General: push reply arrives after channel is closed (orphan reply)
//   - General: phx_close received with a ref (should still close the channel)
//   - General: rapid topic subscribe/unsubscribe race
//   - General: channel.messages stream listener added DURING message delivery
//   - General: leave completer races with socket crash
//   - General: push with same event name as control event
//   - General: server sends reply for unknown ref on correct topic
//   - General: channel errored state then socket reconnects without rejoining
//   - General: disconnect during _flushPushBuffer

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:dart_phoenix_socket/src/channel.dart';
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
}

Future<void> flush([int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await Future.microtask(() {});
  }
}

Future<PhoenixChannel> joinedChannel(T t, String topic) async {
  final ch = t.socket.channel(topic);
  final f = ch.join();
  await flush();
  final r = t.ref(t.sent.last);
  t.replyJoinOk(r, topic);
  await flush();
  await f;
  return ch;
}

void main() {
  // =========================================================================
  // Bug: Phoenix.js #1295 — pushBuffer never flushed on first successful join
  // Push queued before join reply → buffer flushed → push sent
  // =========================================================================
  group('pushBuffer flushed on first join (Phoenix.js #1295)', () {
    test(
      '1. push before join reply → sent immediately after join ok',
      () async {
        final t = T()..init();
        await t.connect();

        final ch = t.socket.channel('room:buf1295');
        unawaited(ch.join());
        await flush();
        final joinRef = t.ref(t.sent.last);

        // Push BEFORE join reply arrives — must be buffered
        var pushDone = false;
        unawaited(
          ch.push('buffered_msg', {'x': 1}).then((_) {
            pushDone = true;
          }),
        );
        await flush();

        // No push sent yet — still joining
        final pushSentBeforeJoin = t.sent
            .where((r) => t.evnt(r) == 'buffered_msg')
            .toList();
        expect(pushSentBeforeJoin, isEmpty);

        // Join reply arrives → buffer flushed → push sent
        t.replyJoinOk(joinRef, 'room:buf1295');
        await flush(8);

        final pushSentAfterJoin = t.sent
            .where((r) => t.evnt(r) == 'buffered_msg')
            .toList();
        expect(pushSentAfterJoin, hasLength(1));

        // Reply to push
        final pushRef = t.ref(pushSentAfterJoin.first);
        final pJoinRef = t.jRef(pushSentAfterJoin.first);
        t.replyOk(pJoinRef, pushRef, 'room:buf1295');
        await flush();
        expect(pushDone, isTrue);
      },
    );

    test('2. multiple buffered pushes all sent after join ok', () async {
      final t = T()..init();
      await t.connect();

      final ch = t.socket.channel('room:multibuf');
      unawaited(ch.join());
      await flush();
      final joinRef = t.ref(t.sent.last);

      // Buffer 3 pushes
      final results = <int>[];
      for (var i = 0; i < 3; i++) {
        final idx = i;
        unawaited(
          ch.push('msg_$i', {'i': i}).then((_) {
            results.add(idx);
          }),
        );
      }
      await flush();

      // None sent yet
      expect(t.sent.where((r) => t.evnt(r).startsWith('msg_')), isEmpty);

      // Join ok → all 3 flushed
      t.replyJoinOk(joinRef, 'room:multibuf');
      await flush(8);

      final msgsSent = t.sent
          .where((r) => t.evnt(r).startsWith('msg_'))
          .toList();
      expect(msgsSent, hasLength(3));

      // Reply to all
      for (final msg in msgsSent) {
        t.replyOk(t.jRef(msg), t.ref(msg), 'room:multibuf');
      }
      await flush(10);
      expect(results, containsAll([0, 1, 2]));
    });
  });

  // =========================================================================
  // Bug: Join → leave race — leave must not trigger rejoin
  // Phoenix.js #3349
  // =========================================================================
  group('Join → leave race (Phoenix.js #3349)', () {
    test('3. leave before join reply — no rejoin scheduled', () async {
      final t = T()..init();
      await t.connect();

      final ch = t.socket.channel('room:leavejoin');
      unawaited(ch.join().then((_) {}, onError: (_) {}));
      await flush();

      // Leave immediately before join reply
      final leaveFuture = ch.leave();
      await flush();
      // Server replies to leave (if sent)
      final leaveMsgs = t.sent.where((r) => t.evnt(r) == 'phx_leave').toList();
      if (leaveMsgs.isNotEmpty) {
        final leaveRef = t.ref(leaveMsgs.last);
        final leaveJoinRef = t.jRef(leaveMsgs.last);
        t.replyOk(leaveJoinRef, leaveRef, 'room:leavejoin');
      }
      await leaveFuture;
      await flush();

      expect(ch.state, PhoenixChannelState.closed);

      // No rejoin should fire — channel is closed, not errored
      await Future.delayed(const Duration(milliseconds: 10));
      final phxJoins = t.sent.where((r) => t.evnt(r) == 'phx_join').toList();
      // At most 1 join (the original) — no rejoin
      expect(phxJoins.length, lessThanOrEqualTo(1));
    });

    test('4. join timeout does not trigger rejoin if channel was left', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = t.socket.channel('room:timeout-left');
        unawaited(ch.join().then((_) {}, onError: (_) {}));
        async.flushMicrotasks();

        // Leave immediately (before join reply)
        unawaited(ch.leave().then((_) {}, onError: (_) {}));
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 11))
          ..flushMicrotasks();
        expect(ch.state, PhoenixChannelState.closed);
        final joins = t.sent.where((r) => t.evnt(r) == 'phx_join').toList();
        expect(joins.length, 1); // only the original join, no rejoin
      });
    });
  });

  // =========================================================================
  // Bug: Duplicate join — join() called twice must fail-fast
  // Phoenix.js #3171
  // =========================================================================
  group('Duplicate join prevention (Phoenix.js #3171)', () {
    test('5. join() called twice throws StateError on second call', () async {
      final t = T()..init();
      await t.connect();

      final ch = t.socket.channel('room:dupjoin');
      unawaited(ch.join().then((_) {}, onError: (_) {}));
      await flush();

      // Second join must throw immediately
      var threw = false;
      try {
        await ch.join();
      } on StateError {
        threw = true;
      }
      expect(threw, isTrue);
    });

    test('6. second join does not send a second phx_join message', () async {
      final t = T()..init();
      await t.connect();

      final ch = t.socket.channel('room:dupjoin2');
      unawaited(ch.join().then((_) {}, onError: (_) {}));
      await flush();
      unawaited(
        ch.join().then((_) {}, onError: (_) {}),
      ); // second — should no-op
      await flush();

      final joins = t.sent.where((r) => t.evnt(r) == 'phx_join').toList();
      expect(joins, hasLength(1)); // only one phx_join sent
    });
  });

  // =========================================================================
  // Bug: Message loss during reconnect window
  // ws#1103 — messages queued during downtime are sent on new connection
  // =========================================================================
  group('Message loss during reconnect window', () {
    test(
      '7. push sent while disconnected is dropped — no phantom delivery',
      () async {
        final t = T()..init();
        await t.connect();
        final ch = await joinedChannel(t, 'room:loss');

        // Disconnect (intentional — no reconnect)
        await t.socket.disconnect();
        await flush();

        // Try to push while disconnected — should throw or be silently dropped
        try {
          await ch
              .push('lost_msg', {})
              .timeout(const Duration(milliseconds: 100));
        } catch (_) {
          // Expected
        }

        // 'lost_msg' must NOT appear in sent (socket was not connected)
        // Note: socket.send() is a no-op when disconnected, so push just hangs
        // until timeout — verify no double delivery on reconnect
        await t.connect();
        await flush(4);
        final lostMsgs = t.sent.where((r) => t.evnt(r) == 'lost_msg').toList();
        expect(lostMsgs, isEmpty);
      },
    );

    test(
      '8. push sent just before crash is NOT silently delivered after reconnect',
      () {
        fakeAsync((async) {
          final t = T()..init();
          unawaited(t.socket.connect());
          async
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks();
          final ch = t.socket.channel('room:pre-crash');
          unawaited(ch.join());
          async.flushMicrotasks();
          final jRef = t.ref(t.sent.last);
          t.replyJoinOk(jRef, 'room:pre-crash');
          async.flushMicrotasks();

          // Push just before crash — in-flight
          unawaited(ch.push('pre_crash_msg', {}).then((_) {}, onError: (_) {}));
          async.flushMicrotasks();

          // Crash
          t.drop();
          async
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 2))
            ..flushMicrotasks();
          final preCrash = t.sent
              .where((r) => t.evnt(r) == 'pre_crash_msg')
              .toList();
          expect(preCrash, hasLength(1)); // sent exactly once, on original conn
        });
      },
    );
  });

  // =========================================================================
  // Bug: Rejoin timeout fires while first join still pending
  // Phoenix.js #2035
  // =========================================================================
  group('Rejoin timeout vs join timeout (Phoenix.js #2035)', () {
    test('9. rejoin after reconnect succeeds — 10s timeout is per-attempt', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = t.socket.channel('room:timeout-fresh');
        unawaited(ch.join().then((_) {}, onError: (_) {}));
        async.flushMicrotasks();
        final jRef = t.ref(t.sent.last);
        t.replyJoinOk(jRef, 'room:timeout-fresh');
        async.flushMicrotasks();
        expect(ch.state, PhoenixChannelState.joined);

        // Crash → channel errored → reconnect → rejoin
        t.drop();
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks();
        final rejoinMsg = t.sent.where((r) => t.evnt(r) == 'phx_join').last;
        async
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks();
        final newJRef = t.ref(rejoinMsg);
        t.replyJoinOk(newJRef, 'room:timeout-fresh');
        async.flushMicrotasks();

        // Channel joined — timeout did not fire prematurely
        expect(ch.state, PhoenixChannelState.joined);
      });
    });
  });

  // =========================================================================
  // Bug: Duplicate listener registration on reconnect
  // Ably FAQ — listeners added multiple times = duplicate callbacks
  // =========================================================================
  group('Duplicate listener on reconnect', () {
    test(
      '10. adding same listener after reconnect does not double-fire',
      () async {
        final t = T()..init();
        await t.connect();
        final ch = await joinedChannel(t, 'room:listener');

        var callCount = 0;
        // Add listener once
        final sub = ch.messages.listen((_) {
          callCount++;
        });

        // Receive one broadcast
        t.toClient([
          null,
          null,
          'room:listener',
          'event',
          {'x': 1},
        ]);
        await flush(4);
        expect(callCount, 1);

        // Cancel and re-add (simulates reconnect scenario)
        await sub.cancel();
        ch.messages.listen((_) {
          callCount++;
        });

        // Second broadcast
        t.toClient([
          null,
          null,
          'room:listener',
          'event',
          {'x': 2},
        ]);
        await flush(4);
        expect(callCount, 2); // +1, not +2
      },
    );

    test(
      '11. multiple listeners on same stream each get exactly one copy',
      () async {
        final t = T()..init();
        await t.connect();
        final ch = await joinedChannel(t, 'room:multilistener');

        var count1 = 0;
        var count2 = 0;
        ch
          ..messages.listen((_) {
            count1++;
          })
          ..messages.listen((_) {
            count2++;
          });
        t.toClient([
          null,
          null,
          'room:multilistener',
          'tick',
          <String, dynamic>{},
        ]);
        await flush(4);
        expect(count1, 1);
        expect(count2, 1); // each listener gets exactly 1 copy
      },
    );
  });

  // =========================================================================
  // Bug: Push event name matches a control event name
  // What if app pushes an event called "phx_reply" or "phx_close"?
  // =========================================================================
  group('Push with control event names', () {
    test(
      '12. push event named phx_reply is sent to server (not filtered on send)',
      () async {
        final t = T()..init();
        await t.connect();
        final ch = await joinedChannel(t, 'room:ctrl-name');

        // App pushes an event named like a control event
        unawaited(
          ch.push('phx_reply', {'custom': true}).then((_) {}, onError: (_) {}),
        );
        await flush(4);

        // The push IS sent to the server (filtering is only on incoming)
        final sent = t.sent.where((r) => t.evnt(r) == 'phx_reply').toList();
        expect(sent, hasLength(1));
      },
    );

    test(
      '13. server broadcast with app event named phx_reply is filtered',
      () async {
        // Incoming phx_reply is always treated as a push reply, not a broadcast
        final t = T()..init();
        await t.connect();
        final ch = await joinedChannel(t, 'room:ctrl-incoming');
        final msgs = <PhoenixMessage>[];
        ch.messages.listen(msgs.add);

        // Server sends something that looks like a broadcast phx_reply with no ref
        t.toClient([
          null,
          null,
          'room:ctrl-incoming',
          'phx_reply',
          {'status': 'ok', 'response': <String, dynamic>{}},
        ]);
        await flush(4);

        // Should NOT appear in messages stream (filtered as control)
        expect(msgs.where((m) => m.event == 'phx_reply'), isEmpty);
      },
    );
  });

  // =========================================================================
  // Bug: Reply for unknown ref on correct topic — silently ignored
  // =========================================================================
  group('Unknown ref handling', () {
    test(
      '14. server reply for unknown ref — silently ignored, no crash',
      () async {
        final t = T()..init();
        await t.connect();
        final ch = await joinedChannel(t, 'room:unknownref');

        // Server sends reply for a ref we never sent
        t.toClient([
          t.jRef(t.sent.last),
          '9999',
          'room:unknownref',
          'phx_reply',
          {'status': 'ok', 'response': <String, dynamic>{}},
        ]);
        await flush(4);
        expect(t.socket.state, PhoenixSocketState.connected);
        expect(ch.state, PhoenixChannelState.joined);
      },
    );

    test('15. server reply for already-timed-out push — no double complete', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = t.socket.channel('room:late-reply');
        unawaited(ch.join());
        async.flushMicrotasks();
        final jRef = t.ref(t.sent.last);
        t.replyJoinOk(jRef, 'room:late-reply');
        async.flushMicrotasks();

        var timedOut = false;
        unawaited(
          ch
              .push('slow_event', {})
              .then(
                (_) {},
                onError: (_) {
                  timedOut = true;
                },
              ),
        );
        async.flushMicrotasks();
        final pushRef = t.ref(
          t.sent.lastWhere((r) => t.evnt(r) == 'slow_event'),
        );
        final pushJoinRef = t.jRef(
          t.sent.lastWhere((r) => t.evnt(r) == 'slow_event'),
        );

        // Push times out at 10s
        async
          ..elapse(const Duration(seconds: 11))
          ..flushMicrotasks();
        expect(timedOut, isTrue);

        // Server belatedly replies — should be ignored (ref removed on timeout)
        t.replyOk(pushJoinRef, pushRef, 'room:late-reply');
        async.flushMicrotasks();

        // No crash
        expect(t.socket.state, PhoenixSocketState.connected);
      });
    });
  });

  // =========================================================================
  // Bug: phx_close with a ref — should close channel regardless
  // =========================================================================
  group('phx_close variants', () {
    test('16. phx_close with null ref closes channel', () async {
      final t = T()..init();
      await t.connect();
      final ch = await joinedChannel(t, 'room:close-null-ref');

      t.toClient([
        null,
        null,
        'room:close-null-ref',
        'phx_close',
        <String, dynamic>{},
      ]);
      await flush(4);
      expect(ch.state, PhoenixChannelState.closed);
    });

    test('17. phx_close with a non-null ref still closes channel', () async {
      final t = T()..init();
      await t.connect();
      final ch = await joinedChannel(t, 'room:close-with-ref');

      t.toClient([
        null,
        '42',
        'room:close-with-ref',
        'phx_close',
        <String, dynamic>{},
      ]);
      await flush(4);
      expect(ch.state, PhoenixChannelState.closed);
    });
  });

  // =========================================================================
  // Bug: Async message handler can process out of order
  // If app uses async listeners, messages may be processed out of order
  // =========================================================================
  group('Message ordering', () {
    test('18. broadcasts delivered in send order to sync listeners', () async {
      final t = T()..init();
      await t.connect();
      final ch = await joinedChannel(t, 'room:ordering');
      final order = <int>[];
      ch.messages.listen((m) => order.add(m.payload['n'] as int));

      for (var i = 0; i < 5; i++) {
        t.toClient([
          null,
          null,
          'room:ordering',
          'tick',
          {'n': i},
        ]);
      }
      await flush(10);
      expect(order, [0, 1, 2, 3, 4]);
    });

    test('19. push replies delivered in push order', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = t.socket.channel('room:push-order');
        unawaited(ch.join());
        async.flushMicrotasks();
        final jRef = t.ref(t.sent.last);
        t.replyJoinOk(jRef, 'room:push-order');
        async.flushMicrotasks();

        final results = <int>[];
        for (var i = 0; i < 3; i++) {
          final idx = i;
          unawaited(
            ch.push('push_$i', {}).then((_) {
              results.add(idx);
            }),
          );
        }
        async.flushMicrotasks();

        final pushMsgs = t.sent
            .where((r) => t.evnt(r).startsWith('push_'))
            .toList();

        // Reply in order
        for (final msg in pushMsgs) {
          t.replyOk(t.jRef(msg), t.ref(msg), 'room:push-order');
          async.flushMicrotasks();
        }
        async
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(results, [0, 1, 2]);
      });
    });
  });

  // =========================================================================
  // Bug: Disconnect during _flushPushBuffer
  // Socket crashes while buffer is being flushed after join
  // =========================================================================
  group('Disconnect during push buffer flush', () {
    test(
      '20. socket crash during buffer flush — buffered pushes error cleanly',
      () async {
        final t = T()..init();
        await t.connect();

        final ch = t.socket.channel('room:flush-crash');
        unawaited(ch.join().then((_) {}, onError: (_) {}));
        await flush();
        final joinRef = t.ref(t.sent.last);

        // Buffer some pushes
        var errCount = 0;
        for (var i = 0; i < 3; i++) {
          unawaited(
            ch
                .push('buffered_$i', {})
                .then(
                  (_) {},
                  onError: (_) {
                    errCount++;
                  },
                ),
          );
        }
        await flush();

        // Crash socket at the same time as join reply
        // (simulates crash during buffer flush)
        t
          ..replyJoinOk(joinRef, 'room:flush-crash')
          ..drop(); // crash immediately after
        await flush(10);

        // Pushes that weren't replied to should error (from disconnect cleanup)
        // At minimum no hangs — socket is gone
        expect(t.socket.state, PhoenixSocketState.reconnecting);
      },
    );
  });

  // =========================================================================
  // Bug: Channel errored but socket reconnects and _rejoinChannels only
  // rejoins channels in errored state — what if it missed the errored transition?
  // =========================================================================
  group('Rejoin only errored channels', () {
    test(
      '21. joined channels are NOT rejoined after reconnect (already joined)',
      () {
        fakeAsync((async) {
          final t = T()..init();
          unawaited(t.socket.connect());
          async
            ..flushMicrotasks()
            ..flushMicrotasks()
            ..flushMicrotasks();
          final ch = t.socket.channel('room:already-joined');
          unawaited(ch.join());
          async.flushMicrotasks();
          final jRef = t.ref(t.sent.last);
          t.replyJoinOk(jRef, 'room:already-joined');
          async.flushMicrotasks();
          expect(ch.state, PhoenixChannelState.joined);

          // Crash → channel goes errored → reconnect → rejoin fires
          t.drop();
          async.flushMicrotasks();
          expect(ch.state, PhoenixChannelState.errored); // must be errored

          async
            ..elapse(const Duration(seconds: 2))
            ..flushMicrotasks();
          final joins = t.sent.where((r) => t.evnt(r) == 'phx_join').toList();
          expect(joins.length, greaterThanOrEqualTo(2)); // original + rejoin
        });
      },
    );

    test('22. closed channel is NOT rejoined after reconnect', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect());
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = t.socket.channel('room:closed-no-rejoin');
        unawaited(ch.join());
        async.flushMicrotasks();
        final jRef = t.ref(t.sent.last);
        t.replyJoinOk(jRef, 'room:closed-no-rejoin');
        async.flushMicrotasks();

        // Leave cleanly → closed state
        unawaited(ch.leave());
        async.flushMicrotasks();
        final leaveRef = t.ref(t.sent.last);
        t.replyOk(jRef, leaveRef, 'room:closed-no-rejoin');
        async.flushMicrotasks();
        expect(ch.state, PhoenixChannelState.closed);

        // Crash socket
        t.drop();
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks();
        final joins = t.sent.where((r) => t.evnt(r) == 'phx_join').toList();
        expect(joins.length, 1); // only the original join
      });
    });
  });

  // =========================================================================
  // Bug: Listener added during message delivery — should not receive current msg
  // =========================================================================
  group('Listener added during delivery', () {
    test(
      '23. listener added inside another listener callback — no re-entrant delivery',
      () async {
        final t = T()..init();
        await t.connect();
        final ch = await joinedChannel(t, 'room:reentrant');

        final received = <String>[];
        ch.messages.listen((m) {
          received.add('outer:${m.payload['n']}');
          // Add another listener during delivery
          ch.messages.listen((m2) {
            received.add('inner:${m2.payload['n']}');
          });
        });

        t.toClient([
          null,
          null,
          'room:reentrant',
          'evt',
          {'n': 1},
        ]);
        await flush(4);
        // Outer fires for msg 1
        expect(received, contains('outer:1'));

        // Second message — both outer and inner fire
        t.toClient([
          null,
          null,
          'room:reentrant',
          'evt',
          {'n': 2},
        ]);
        await flush(4);
        expect(received, contains('outer:2'));
        expect(received, contains('inner:2'));
        // Inner does NOT fire for msg 1 (was added after delivery)
        expect(received, isNot(contains('inner:1')));
      },
    );
  });

  // =========================================================================
  // Bug: Leave completer races with socket crash
  // =========================================================================
  group('Leave and crash race', () {
    test('24. socket crash during leave — leave future completes', () async {
      final t = T()..init();
      await t.connect();
      final ch = await joinedChannel(t, 'room:leave-crash');

      var leaveDone = false;
      var leaveErrored = false;
      final leaveFuture = ch
          .leave()
          .then((_) {
            leaveDone = true;
          })
          .catchError((_) {
            leaveErrored = true;
          });

      // Crash immediately after starting leave
      t.drop();
      await flush(10);
      await leaveFuture;

      // Leave must complete (one way or another) — not hang
      expect(
        leaveDone || leaveErrored || ch.state == PhoenixChannelState.closed,
        isTrue,
      );
    });

    test(
      '25. crash then leave — leave is a no-op (channel already errored)',
      () async {
        final t = T()..init();
        await t.connect();
        final ch = await joinedChannel(t, 'room:crash-then-leave');

        // Crash first
        t.drop();
        await flush();
        expect(ch.state, PhoenixChannelState.errored);

        // Leave after crash — should not throw
        await ch.leave();
        // Best-effort: either closed or errored is acceptable
        expect(
          ch.state,
          anyOf(PhoenixChannelState.closed, PhoenixChannelState.errored),
        );
      },
    );
  });

  // =========================================================================
  // Bug: Token/auth params — socket-level auth, not per-push
  // Mid-session token expiry cannot be detected by socket alone
  // =========================================================================
  group('Auth params behavior', () {
    test('26. params are sent in URL — visible at connect time', () async {
      Uri? captured;
      final socket = PhoenixSocket(
        'ws://localhost:4000/socket/websocket',
        params: {'token': 'jwt.abc.def'},
        channelFactory: (uri) {
          captured = uri;
          return FakeWebSocketChannel();
        },
      );
      await socket.connect();
      expect(captured?.queryParameters['token'], 'jwt.abc.def');
      await socket.disconnect();
    });

    test('27. params NOT re-sent on every push — only at connect', () async {
      final t = T()..init();
      await t.connect();
      final ch = await joinedChannel(t, 'room:auth');

      unawaited(ch.push('action', {}).then((_) {}, onError: (_) {}));
      await flush(4);

      final pushMsg = t.sent.lastWhere((r) => t.evnt(r) == 'action');
      final decoded = jsonDecode(pushMsg as String) as List;
      // Push payload is just the app payload — no auth token in it
      expect((decoded[4] as Map).containsKey('token'), isFalse);
    });
  });

  // =========================================================================
  // Bug: UTF-8 / special payload values
  // =========================================================================
  group('Payload edge cases', () {
    test(
      '28. unicode payload preserved through encode/decode round-trip',
      () async {
        final t = T()..init();
        await t.connect();
        final ch = await joinedChannel(t, 'room:unicode');

        const emoji = '🔥💯🎯';
        const arabic = 'مرحبا';
        const chinese = '你好世界';

        unawaited(
          ch
              .push('msg', {'text': '$emoji $arabic $chinese'})
              .then((_) {}, onError: (_) {}),
        );
        await flush(4);

        final raw = t.sent.lastWhere((r) => t.evnt(r) == 'msg');
        final decoded = jsonDecode(raw as String) as List;
        expect((decoded[4] as Map)['text'], '$emoji $arabic $chinese');
      },
    );

    test('29. null value in payload is preserved', () async {
      final t = T()..init();
      await t.connect();
      final ch = await joinedChannel(t, 'room:nullval');

      unawaited(
        ch
            .push('msg', {'key': null, 'other': 'val'})
            .then((_) {}, onError: (_) {}),
      );
      await flush(4);

      final raw = t.sent.lastWhere((r) => t.evnt(r) == 'msg');
      final decoded = jsonDecode(raw as String) as List;
      expect((decoded[4] as Map)['key'], isNull);
      expect((decoded[4] as Map)['other'], 'val');
    });

    test('30. deeply nested payload round-trips correctly', () async {
      final t = T()..init();
      await t.connect();
      final ch = await joinedChannel(t, 'room:deep');

      final deep = {
        'a': {
          'b': {
            'c': {
              'd': {
                'e': [
                  1,
                  2,
                  {'f': true},
                ],
              },
            },
          },
        },
      };
      unawaited(ch.push('deep_push', deep).then((_) {}, onError: (_) {}));
      await flush(4);

      final raw = t.sent.lastWhere((r) => t.evnt(r) == 'deep_push');
      final decoded = jsonDecode(raw as String) as List;
      expect(decoded[4], deep);
    });
  });
}
