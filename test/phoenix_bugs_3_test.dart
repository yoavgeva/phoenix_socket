// Tests for newly found Phoenix Channel / WebSocket bugs.
//
// Bugs fixed in this round:
//   Bug A (channel.dart): phx_error doesn't clear _pendingRefs — push completers hang
//   Bug B (channel.dart): onSocketDisconnect doesn't handle `leaving` state
//   Bug C (socket.dart): _rejoinChannels skips channels in `joining` state
//   Bug D (message.dart): null payload throws TypeError, silently dropped
//
// Additional behavior verified (not bugs, but edge cases worth documenting):
//   - leave() when disconnected resolves without 5s wait (send is no-op)
//   - binary/non-string frames silently dropped (by design, no crash)
//   - channel() returns same instance after leave() (cached, not evicted)
//   - phx_error on live socket leaves channel errored (no auto-retry)
//
// Sources:
//   Phoenix.js #2976 / #3669: phx_error doesn't clear in-flight pushes
//   Phoenix.js #1739:          leaving state not handled on disconnect
//   Phoenix.js #2251:          _rejoinChannels only checks errored, not joining
//   Phoenix heartbeat #2947:   null payload fromJson crash

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:dark_phoenix_socket/src/channel.dart';
import 'package:dark_phoenix_socket/src/exceptions.dart';
import 'package:dark_phoenix_socket/src/message.dart';
import 'package:dark_phoenix_socket/src/socket.dart';
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
  // Bug A: phx_error from server doesn't clear _pendingRefs
  // In-flight push completers hang until their 10s timeout fires.
  // Fixed: phx_error handler now calls _clearPendingRefs().
  // =========================================================================
  group('Bug A: phx_error clears in-flight push completers', () {
    test(
      '1. push in-flight when phx_error arrives — errors promptly',
      () async {
        final t = T()..init();
        await t.connect();

        final ch = await joinedChannel(t, 'room:phxerr1');
        final joinRef = t.jRef(t.sent.last);

        // Send a push — server never replies
        Object? pushError;
        var pushDone = false;
        unawaited(
          ch
              .push('slow_event', {})
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
        await flush(4);

        // Push is now in-flight (_pendingRefs has the completer)
        expect(pushDone, isFalse);

        // Server sends phx_error — channel transitions to errored
        t.toClient([joinRef, null, 'room:phxerr1', 'phx_error', {}]);
        await flush(6);

        // Push must have been rejected immediately, not after 10s timeout
        expect(pushDone, isTrue);
        expect(pushError, isA<PhoenixException>());
        expect(ch.state, PhoenixChannelState.errored);
      },
    );

    test('2. multiple in-flight pushes cleared on phx_error', () async {
      final t = T()..init();
      await t.connect();

      final ch = await joinedChannel(t, 'room:phxerr2');
      final joinRef = t.jRef(t.sent.last);

      final errors = <Object>[];
      for (var i = 0; i < 3; i++) {
        unawaited(
          ch
              .push('event_$i', {})
              .then(
                (_) {},
                onError: errors.add,
              ),
        );
      }
      await flush(4);

      t.toClient([joinRef, null, 'room:phxerr2', 'phx_error', {}]);
      await flush(6);

      expect(errors, hasLength(3));
      expect(errors.every((e) => e is PhoenixException), isTrue);
    });

    test('3. phx_error with no in-flight pushes — no crash', () async {
      final t = T()..init();
      await t.connect();

      final ch = await joinedChannel(t, 'room:phxerr3');
      final joinRef = t.jRef(t.sent.last);

      // No pending pushes
      t.toClient([joinRef, null, 'room:phxerr3', 'phx_error', {}]);
      await flush(4);

      expect(ch.state, PhoenixChannelState.errored);
    });
  });

  // =========================================================================
  // Bug B: onSocketDisconnect() didn't handle `leaving` state
  // A channel in `leaving` when the socket drops stays `leaving` forever.
  // Fixed: leaving → errored on disconnect.
  // =========================================================================
  group('Bug B: leaving channel transitions to errored on socket disconnect', () {
    test(
      '4. socket drops while channel is leaving — channel not stuck in leaving',
      () async {
        final t = T()..init();
        await t.connect();

        final ch = await joinedChannel(t, 'room:leave_dc');

        // Start leave — server never replies (leave pending)
        unawaited(ch.leave().then((_) {}, onError: (_) {}));
        await flush(2);

        expect(ch.state, PhoenixChannelState.leaving);

        // Socket drops while leave is in-flight
        t.drop();
        await flush(6);

        // Channel must not be stuck in leaving.
        // leave() catches the disconnect error and transitions to closed.
        // (onSocketDisconnect sets errored, but leave() completes and sets closed)
        expect(ch.state, isNot(PhoenixChannelState.leaving));
      },
    );

    test(
      '5. leaving channel not stuck — leave future resolves (not hangs)',
      () async {
        final t = T()..init();
        await t.connect();

        final ch = await joinedChannel(t, 'room:leave_dc2');

        var leaveDone = false;
        unawaited(
          ch.leave().then(
            (_) {
              leaveDone = true;
            },
            onError: (_) {
              leaveDone = true;
            },
          ),
        );
        await flush(2);

        expect(ch.state, PhoenixChannelState.leaving);

        // Drop the socket — the leave pending ref should be cleared
        t.drop();
        await flush(6);

        // Leave resolved (either ok or error) — not hanging
        // The leave completer's ref was in _pendingRefs which gets cleared on disconnect
        // After clearing, the leave() best-effort try/catch finishes
        expect(leaveDone, isTrue);
      },
    );

    test(
      '6. simultaneous leave+disconnect — socket goes disconnected cleanly',
      () async {
        final t = T()..init();
        await t.connect();

        final ch = await joinedChannel(t, 'room:leave_dc3');

        // Concurrent leave and socket drop
        unawaited(ch.leave().then((_) {}, onError: (_) {}));
        t.drop();
        await flush();

        // Socket in reconnecting state, channel errored
        expect(
          t.socket.state,
          anyOf(
            PhoenixSocketState.reconnecting,
            PhoenixSocketState.disconnected,
          ),
        );
        expect(ch.state, isNot(PhoenixChannelState.leaving));
      },
    );
  });

  // =========================================================================
  // Bug C: _rejoinChannels() only rejoined `errored` channels, not `joining`
  // A channel whose join was in-flight when the socket dropped stayed `joining`
  // (its state was set by onSocketDisconnect to errored — actually Bug B already
  // covers `joining → errored`). Additional: verify `joining` channels rejoin.
  // Fixed: _rejoinChannels now includes `joining` state.
  // =========================================================================
  group('Bug C: channels in joining state are rejoined on reconnect', () {
    test('7. channel joining when socket drops — rejoins after reconnect', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = t.socket.channel('room:join_on_drop');
        unawaited(ch.join().then((_) {}, onError: (_) {}));
        async.flushMicrotasks();

        // Channel is joining, socket drops before join reply
        t.drop();
        async
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(ch.state, PhoenixChannelState.errored);

        // Reconnect fires (1s backoff)
        async
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final joins = t.sent
            .where(
              (m) =>
                  t.evnt(m) == 'phx_join' &&
                  t.topicOf(m) == 'room:join_on_drop',
            )
            .toList();
        expect(joins.length, greaterThanOrEqualTo(2)); // original + rejoin
        expect(ch.state, PhoenixChannelState.joining);
      });
    });

    test('8. multiple channels: errored and closed — only errored rejoins', () {
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final chA = t.socket.channel('room:a');
        unawaited(chA.join().then((_) {}, onError: (_) {}));
        async.flushMicrotasks();
        final refA = t.ref(t.sent.last);
        t.replyJoinOk(refA, 'room:a');
        async.flushMicrotasks();
        expect(chA.state, PhoenixChannelState.joined);

        // Server closes channel A via phx_close → closed state
        t.toClient([refA, null, 'room:a', 'phx_close', {}]);
        async.flushMicrotasks();
        expect(chA.state, PhoenixChannelState.closed);

        // Join channel B — but socket drops before reply
        final chB = t.socket.channel('room:b');
        unawaited(chB.join().then((_) {}, onError: (_) {}));
        async.flushMicrotasks();
        // drop → B goes errored
        t.drop();
        async
          ..flushMicrotasks()
          ..flushMicrotasks();
        expect(chB.state, PhoenixChannelState.errored);

        // Reconnect
        async
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final bJoins = t.sent
            .where((m) => t.evnt(m) == 'phx_join' && t.topicOf(m) == 'room:b')
            .toList();
        expect(bJoins.length, greaterThanOrEqualTo(2));

        // Channel A (closed by server) must NOT rejoin
        final aJoins = t.sent
            .where((m) => t.evnt(m) == 'phx_join' && t.topicOf(m) == 'room:a')
            .toList();
        expect(aJoins.length, 1); // only the original join, no rejoin
        expect(chA.state, PhoenixChannelState.closed);
      });
    });
  });

  // =========================================================================
  // Bug D: null payload in PhoenixMessage.fromJson throws TypeError silently
  // Fixed: null payload defaults to {}.
  // =========================================================================
  group('Bug D: null payload in PhoenixMessage.fromJson handled gracefully', () {
    test('9. fromJson with null payload → defaults to empty map', () {
      final msg = PhoenixMessage.fromJson(
        const [null, '1', 'room:lobby', 'custom_event', null],
      );
      expect(msg.payload, isEmpty);
      expect(msg.event, 'custom_event');
    });

    test(
      '10. null payload message routed to channel messages stream',
      () async {
        final t = T()..init();
        await t.connect();

        final ch = await joinedChannel(t, 'room:nullpayload');
        final joinRef = t.jRef(t.sent.last);

        final received = <PhoenixMessage>[];
        ch.messages.listen(received.add);

        // Server sends message with null payload (raw JSON)
        t.server.sink.add(
          jsonEncode([joinRef, null, 'room:nullpayload', 'null_event', null]),
        );
        await flush(4);

        expect(received, hasLength(1));
        expect(received.first.event, 'null_event');
        expect(received.first.payload, isEmpty);
      },
    );

    test(
      '11. non-map payload (invalid) — silently dropped, no crash',
      () async {
        final t = T()..init();
        await t.connect();

        final ch = await joinedChannel(t, 'room:badpayload');

        final received = <PhoenixMessage>[];
        ch.messages.listen(received.add);

        // Server sends message with array payload (invalid Phoenix V2 format)
        t.server.sink.add(
          jsonEncode([
            null,
            null,
            'room:badpayload',
            'bad_event',
            [1, 2, 3],
          ]),
        );
        await flush(4);

        // Must not crash — message silently dropped (wrong payload type)
        expect(ch.state, PhoenixChannelState.joined);
        // payload [1,2,3] is not a Map → fromJson throws → caught in _onMessage
        expect(received, isEmpty);
      },
    );

    test(
      '12. binary (non-string) frame — silently dropped, no crash',
      () async {
        final t = T()..init();
        await t.connect();

        final ch = await joinedChannel(t, 'room:binary');

        // Inject a binary frame (Uint8List-like — we simulate with raw bytes)
        // The socket's _onMessage does `data as String` — if data is not a
        // String it throws TypeError which is caught and ignored.
        t.server.sink.add([0x00, 0x01, 0x02]); // List<int>, not String
        await flush(4);

        // Socket must still be connected, channel still joined
        expect(t.socket.state, PhoenixSocketState.connected);
        expect(ch.state, PhoenixChannelState.joined);
      },
    );
  });

  // =========================================================================
  // Additional edge cases
  // =========================================================================
  group('Additional edge cases', () {
    test('13. leave() when disconnected — resolves without 5s wait', () async {
      // When disconnected, send() is a no-op. The leave completer is added to
      // _pendingRefs but onSocketDisconnect already cleared them.
      // However, if leave() is called AFTER disconnect, _pendingRefs is empty.
      // The leave timeout (5s best-effort) fires, resolves.
      // This test verifies it doesn't hang forever.
      fakeAsync((async) {
        final t = T()..init();
        unawaited(t.socket.connect().then((_) {}, onError: (_) {}));
        async
          ..flushMicrotasks()
          ..flushMicrotasks()
          ..flushMicrotasks();
        final ch = t.socket.channel('room:leave_disconnected');
        unawaited(ch.join().then((_) {}, onError: (_) {}));
        async.flushMicrotasks();
        final r = t.ref(t.sent.last);
        t.replyJoinOk(r, 'room:leave_disconnected');
        async.flushMicrotasks();
        expect(ch.state, PhoenixChannelState.joined);

        unawaited(t.socket.disconnect());
        async.flushMicrotasks();

        // Intentional disconnect transitions channel to closed immediately.
        expect(ch.state, PhoenixChannelState.closed);

        // leave() on a closed channel is a no-op — resolves immediately.
        var leaveDone = false;
        unawaited(
          ch.leave().then(
            (_) {
              leaveDone = true;
            },
            onError: (_) {
              leaveDone = true;
            },
          ),
        );
        async.flushMicrotasks();

        expect(leaveDone, isTrue); // immediate — channel already closed
        expect(ch.state, PhoenixChannelState.closed);
      });
    });

    test(
      '14. socket.channel() after leave() returns same cached instance',
      () async {
        // This documents the current behavior: channel() never evicts from cache.
        // Users must be aware that after leave(), channel(topic) returns the same
        // dead instance, and join() will throw StateError.
        final t = T()..init();
        await t.connect();

        final ch1 = await joinedChannel(t, 'room:cached');
        await ch1.leave();

        final ch2 = t.socket.channel('room:cached');
        expect(identical(ch1, ch2), isTrue); // same object
        expect(ch2.state, PhoenixChannelState.closed);
      },
    );

    test(
      '15. phx_error on live socket — channel errored, no auto-retry on same socket',
      () async {
        // Per-channel phx_error on a live socket transitions to errored.
        // Auto-retry only happens when the SOCKET reconnects (via _rejoinChannels).
        // There is no per-channel retry without a socket reconnect.
        final t = T()..init();
        await t.connect();

        final ch = await joinedChannel(t, 'room:phxerr_live');
        final joinRef = t.jRef(t.sent.last);

        t.toClient([joinRef, null, 'room:phxerr_live', 'phx_error', {}]);
        await flush(4);

        expect(ch.state, PhoenixChannelState.errored);

        // No automatic rejoin on the same socket — this is documented behavior
        await flush(4);
        expect(ch.state, PhoenixChannelState.errored);

        // Sending a push on an errored channel buffers it (not an error)
        var pushDone = false;
        unawaited(
          ch
              .push('buffered', {})
              .then(
                (_) {},
                onError: (_) {
                  pushDone = true;
                },
              ),
        );
        await flush(2);
        // Push is buffered, not yet resolved
        expect(pushDone, isFalse);
      },
    );

    test(
      '16. phx_close on one channel does not affect sibling channels',
      () async {
        final t = T()..init();
        await t.connect();

        final chA = await joinedChannel(t, 'room:sibling_a');
        final chB = await joinedChannel(t, 'room:sibling_b');
        final joinRefA = t.jRef(
          t.sent.where((m) => t.topicOf(m) == 'room:sibling_a').last,
        );

        // Server closes channel A
        t.toClient([joinRefA, null, 'room:sibling_a', 'phx_close', {}]);
        await flush(4);

        expect(chA.state, PhoenixChannelState.closed);
        // Channel B must be unaffected
        expect(chB.state, PhoenixChannelState.joined);
      },
    );

    test('17. push reply arrives after channel left — no crash', () async {
      final t = T()..init();
      await t.connect();

      final ch = await joinedChannel(t, 'room:orphan_reply');
      final joinRef = t.jRef(t.sent.last);

      // Send push, capture its ref
      unawaited(ch.push('late_event', {}).then((_) {}, onError: (_) {}));
      await flush(4);
      final pushRef = t.ref(
        t.sent.where((m) => t.evnt(m) == 'late_event').last,
      );

      // Leave the channel
      unawaited(ch.leave().then((_) {}, onError: (_) {}));
      await flush(2);
      // Reply leave
      final leaveRef = t.ref(t.sent.last);
      t.replyOk(joinRef, leaveRef, 'room:orphan_reply');
      await flush(4);

      expect(ch.state, PhoenixChannelState.closed);

      // Now a late reply for the old push arrives — must not crash
      t.toClient([
        joinRef,
        pushRef,
        'room:orphan_reply',
        'phx_reply',
        {'status': 'ok', 'response': <String, dynamic>{}},
      ]);
      await flush(4);

      // No exception, socket still alive
      expect(t.socket.state, PhoenixSocketState.connected);
    });

    test('18. message with empty string topic — no crash', () async {
      final t = T()..init();
      await t.connect();

      // A message with topic "" — no channel registered for it
      // Should be silently dropped (no channel found in _channels)
      t.server.sink.add(
        jsonEncode([null, null, '', 'some_event', <String, dynamic>{}]),
      );
      await flush(4);

      expect(t.socket.state, PhoenixSocketState.connected);
    });

    test(
      '19. malformed JSON frame — no crash, socket stays connected',
      () async {
        final t = T()..init();
        await t.connect();

        // Inject malformed JSON
        t.server.sink.add('not valid json {{{');
        await flush(4);

        expect(t.socket.state, PhoenixSocketState.connected);
      },
    );

    test(
      '20. PhoenixMessage.fromJson round-trip with null joinRef and ref',
      () {
        const original = PhoenixMessage(
          joinRef: null,
          ref: null,
          topic: 'room:lobby',
          event: 'broadcast',
          payload: {'data': 'hello'},
        );
        final decoded = PhoenixMessage.fromJson(original.toJson());
        expect(decoded.joinRef, isNull);
        expect(decoded.ref, isNull);
        expect(decoded.topic, 'room:lobby');
        expect(decoded.event, 'broadcast');
        expect(decoded.payload['data'], 'hello');
      },
    );
  });
}
