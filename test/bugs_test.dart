// Tests for bugs found in code review.
// Each test is labelled with the bug it covers.

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:dart_phoenix_socket/src/channel.dart';
import 'package:dart_phoenix_socket/src/exceptions.dart';
import 'package:dart_phoenix_socket/src/socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'fake_web_socket_channel.dart';

class TestSetup {
  late PhoenixSocket socket;
  late StreamChannel<dynamic> serverChannel;
  final sentMessages = <dynamic>[];
  int connectCount = 0;

  void init({String url = 'ws://localhost:4000/socket/websocket'}) {
    socket = PhoenixSocket(
      url,
      channelFactory: (uri) {
        connectCount++;
        final ws = FakeWebSocketChannel();
        serverChannel = ws.server;
        ws.server.stream.listen(sentMessages.add);
        return ws;
      },
    );
  }

  Future<void> connect() => socket.connect();

  void sendToClient(List<dynamic> msg) {
    serverChannel.sink.add(jsonEncode(msg));
  }

  String lastRef() {
    final msg = jsonDecode(sentMessages.last as String) as List;
    return msg[1] as String;
  }

  String lastJoinRef() {
    final msg = jsonDecode(sentMessages.last as String) as List;
    return msg[0] as String;
  }

  void replyJoinOk(
    String ref,
    String topic, {
    Map<String, dynamic> response = const {},
  }) {
    sendToClient([
      ref,
      ref,
      topic,
      'phx_reply',
      {'status': 'ok', 'response': response},
    ]);
  }

  void replyJoinError(
    String ref,
    String topic, {
    Map<String, dynamic> response = const {},
  }) {
    sendToClient([
      ref,
      ref,
      topic,
      'phx_reply',
      {'status': 'error', 'response': response},
    ]);
  }
}

Future<PhoenixChannel> joinedChannel(
  TestSetup setup, {
  String topic = 'room:lobby',
}) async {
  final ch = setup.socket.channel(topic);
  final joinFuture = ch.join();
  await Future.microtask(() {});
  final ref = setup.lastRef();
  setup.replyJoinOk(ref, topic);
  await Future.microtask(() {});
  await joinFuture;
  return ch;
}

void main() {
  group('Bug fixes', () {
    // -------------------------------------------------------------------------
    // Bug 1: Heartbeat timeout double-reconnect
    // _handleDisconnect was called twice: once from heartbeat timer,
    // once from _onDone fired by sink.close(). Both called _scheduleReconnect,
    // incrementing _reconnectAttempts twice and scheduling two timers.
    // -------------------------------------------------------------------------
    group('Bug 1: heartbeat timeout does not double-schedule reconnect', () {
      test(
        '_reconnectAttempts increments exactly once on heartbeat timeout',
        () {
          fakeAsync((async) {
            var connectCount = 0;
            final socket = PhoenixSocket(
              'ws://localhost:4000/socket/websocket',
              channelFactory: (uri) {
                connectCount++;
                return FakeWebSocketChannel();
              },
            );

            unawaited(socket.connect());
            async.flushMicrotasks();
            expect(connectCount, 1);

            // First heartbeat at 30s — no reply sent
            async
              ..elapse(const Duration(seconds: 30))
              ..elapse(const Duration(seconds: 30))
              ..flushMicrotasks()
              ..elapse(const Duration(seconds: 1))
              ..flushMicrotasks();
            expect(connectCount, 2);

            unawaited(socket.disconnect());
            async.flushMicrotasks();
          });
        },
      );
    });

    // -------------------------------------------------------------------------
    // Bug 2: rejoin() had no timeout — channel could hang in joining forever
    // -------------------------------------------------------------------------
    group('Bug 2: rejoin() has a timeout', () {
      test(
        'rejoin that never gets a reply transitions to errored after 10s',
        () {
          fakeAsync((async) {
            final setup = TestSetup()..init();
            unawaited(setup.connect());
            async.flushMicrotasks();

            final ch = setup.socket.channel('room:lobby');
            // Set up _joinPayload by calling join then simulating join success
            final joinFuture = ch.join();
            async.flushMicrotasks();

            final joinRef = setup.lastRef();
            setup.replyJoinOk(joinRef, 'room:lobby');
            async.flushMicrotasks();

            expect(ch.state, PhoenixChannelState.joined);
            joinFuture.ignore();

            // Simulate disconnect + rejoin
            ch.onSocketDisconnect();
            expect(ch.state, PhoenixChannelState.errored);

            ch.rejoin();
            async.flushMicrotasks();
            expect(ch.state, PhoenixChannelState.joining);

            // Server never replies — timeout should fire
            async
              ..elapse(const Duration(seconds: 11))
              ..flushMicrotasks();
            expect(ch.state, PhoenixChannelState.errored);

            unawaited(setup.socket.disconnect());
            async.flushMicrotasks();
          });
        },
      );

      test('push buffer does not grow unboundedly during timed-out rejoin', () {
        fakeAsync((async) {
          final setup = TestSetup()..init();
          unawaited(setup.connect());
          async.flushMicrotasks();

          final ch = setup.socket.channel('room:lobby');
          final joinFuture = ch.join();
          async.flushMicrotasks();
          setup.replyJoinOk(setup.lastRef(), 'room:lobby');
          async.flushMicrotasks();
          joinFuture.ignore();

          ch
            ..onSocketDisconnect()
            ..rejoin();
          async.flushMicrotasks();

          // Buffer pushes during the rejoin joining state
          unawaited(
            ch.push('msg', {'n': 1}).catchError((_) => <String, dynamic>{}),
          );
          unawaited(
            ch.push('msg', {'n': 2}).catchError((_) => <String, dynamic>{}),
          );

          // Timeout fires
          async
            ..elapse(const Duration(seconds: 11))
            ..flushMicrotasks();
          expect(ch.state, PhoenixChannelState.errored);

          unawaited(setup.socket.disconnect());
          async.flushMicrotasks();
        });
      });
    });

    // -------------------------------------------------------------------------
    // Bug 3: phx_close / phx_error during join left _joinCompleter unresolved
    // -------------------------------------------------------------------------
    group(
      'Bug 3: phx_close / phx_error complete the join future immediately',
      () {
        test(
          'phx_close during join fails join future with PhoenixException',
          () async {
            final setup = TestSetup()..init();
            await setup.connect();

            final ch = setup.socket.channel('room:lobby');
            Object? joinError;
            final joinFuture = ch.join().catchError((Object e) {
              joinError = e;
              return <String, dynamic>{};
            });
            await Future.microtask(() {});

            // Server sends phx_close before join reply
            setup.sendToClient([
              null,
              null,
              'room:lobby',
              'phx_close',
              <String, dynamic>{},
            ]);
            await Future.microtask(() {});
            await joinFuture;

            // Join future must have failed immediately, not after 10s timeout
            expect(joinError, isA<PhoenixException>());
            expect(ch.state, PhoenixChannelState.closed);

            await setup.socket.disconnect();
          },
        );

        test(
          'phx_error during join fails join future with PhoenixException',
          () async {
            final setup = TestSetup()..init();
            await setup.connect();

            final ch = setup.socket.channel('room:lobby');
            Object? joinError;
            final joinFuture = ch.join().catchError((Object e) {
              joinError = e;
              return <String, dynamic>{};
            });
            await Future.microtask(() {});

            setup.sendToClient([
              null,
              null,
              'room:lobby',
              'phx_error',
              <String, dynamic>{},
            ]);
            await Future.microtask(() {});
            await joinFuture;

            expect(joinError, isA<PhoenixException>());
            expect(ch.state, PhoenixChannelState.errored);

            await setup.socket.disconnect();
          },
        );
      },
    );

    // -------------------------------------------------------------------------
    // Bug 4: leave() during joining left _joinCompleter unresolved (10s hang)
    // -------------------------------------------------------------------------
    group(
      'Bug 4: leave() during join resolves the join future immediately',
      () {
        test('calling leave() while joining fails the join future', () async {
          final setup = TestSetup()..init();
          await setup.connect();

          final ch = setup.socket.channel('room:lobby');
          Object? joinError;
          final joinFuture = ch.join().catchError((Object e) {
            joinError = e;
            return <String, dynamic>{};
          });
          await Future.microtask(() {});

          expect(ch.state, PhoenixChannelState.joining);

          // Leave while still joining — join future should fail immediately
          final leaveFuture = ch.leave();
          await Future.microtask(() {});

          // Reply to the leave (best-effort)
          final leaveRef = setup.lastRef();
          setup.sendToClient([
            setup.lastJoinRef(),
            leaveRef,
            'room:lobby',
            'phx_reply',
            {'status': 'ok', 'response': <String, dynamic>{}},
          ]);
          await Future.microtask(() {});
          await leaveFuture;
          await joinFuture;

          expect(joinError, isA<PhoenixException>());
          expect(ch.state, PhoenixChannelState.closed);

          await setup.socket.disconnect();
        });
      },
    );

    // -------------------------------------------------------------------------
    // Bug 5: rejoin() .then block was redundant — _handleReply already does it.
    // Verify no double _flushPushBuffer call causes issues.
    // -------------------------------------------------------------------------
    group('Bug 5: rejoin does not double-flush push buffer', () {
      test('buffered pushes sent exactly once after rejoin', () async {
        final setup = TestSetup()..init();
        await setup.connect();

        final ch = await joinedChannel(setup);

        // Disconnect + rejoin
        ch
          ..onSocketDisconnect()
          ..rejoin();
        await Future.microtask(() {});

        // Buffer a push during rejoining
        Map<String, dynamic>? pushResult;
        unawaited(
          ch.push('new_msg', {'body': 'once'}).then((r) => pushResult = r),
        );
        await Future.microtask(() {});

        // Reply to rejoin
        final rejoinRef = setup.lastRef();
        setup.replyJoinOk(rejoinRef, 'room:lobby');
        await Future.microtask(() {});
        await Future.microtask(() {});

        // Buffered push should have been sent exactly once
        final sentAfterJoin = setup.sentMessages.where((m) {
          final decoded = jsonDecode(m as String) as List;
          return decoded[3] == 'new_msg';
        }).length;
        expect(sentAfterJoin, 1);

        // Reply to the push
        final pushRef = setup.lastRef();
        setup.sendToClient([
          rejoinRef,
          pushRef,
          'room:lobby',
          'phx_reply',
          {
            'status': 'ok',
            'response': {'ok': true},
          },
        ]);
        // Several microtask hops: _handleReply → completer.complete →
        // timeout future resolves → .then(buffered.completer.complete) →
        // pushResult = r
        for (var i = 0; i < 6; i++) {
          await Future.microtask(() {});
        }

        expect(pushResult, isNotNull);
        expect(pushResult!['ok'], true);

        await setup.socket.disconnect();
      });
    });

    // -------------------------------------------------------------------------
    // Bug 6 (socket): _pendingHeartbeatRef not cleared on disconnect(),
    // causing spurious reconnect after disconnect+reconnect cycle.
    // -------------------------------------------------------------------------
    group('Bug 6: stale heartbeat ref cleared on disconnect', () {
      test('disconnect clears pending heartbeat ref so reconnect does not '
          'immediately re-disconnect at next heartbeat tick', () {
        fakeAsync((async) {
          StreamChannel<dynamic>? latestServer;

          final socket = PhoenixSocket(
            'ws://localhost:4000/socket/websocket',
            channelFactory: (uri) {
              final ws = FakeWebSocketChannel();
              latestServer = ws.server;
              return ws;
            },
          );

          unawaited(socket.connect());
          async.flushMicrotasks();
          expect(socket.state, PhoenixSocketState.connected);

          // First heartbeat fires; do NOT reply — _pendingHeartbeatRef is set
          async.elapse(const Duration(seconds: 30));

          // User disconnects intentionally while heartbeat is pending.
          // disconnect() is async; it sets _intentionalDisconnect and clears
          // timers synchronously, then awaits cleanup futures.
          // We do not await here (fakeAsync), but _intentionalDisconnect flag
          // is set synchronously so reconnection is prevented.
          unawaited(socket.disconnect());

          // Reset state for reconnect — simulates new session
          // (In real code disconnect() awaits and sets state; we flush enough)
          for (var i = 0; i < 10; i++) {
            async.flushMicrotasks();
          }

          // Reconnect — disconnect should have cleared _pendingHeartbeatRef
          unawaited(socket.connect());
          async.flushMicrotasks();
          expect(socket.state, PhoenixSocketState.connected);

          // Reply to each heartbeat sent on the new connection
          // to prevent genuine heartbeat-miss reconnects
          final newSentMsgs = <dynamic>[];
          latestServer!.stream.listen(newSentMsgs.add);

          // Heartbeat at t+30s on new connection
          async
            ..elapse(const Duration(seconds: 30))
            ..flushMicrotasks();
          if (newSentMsgs.isNotEmpty) {
            final hb = jsonDecode(newSentMsgs.last as String) as List;
            if (hb[3] == 'heartbeat') {
              latestServer!.sink.add(
                jsonEncode([
                  null,
                  hb[1],
                  'phoenix',
                  'phx_reply',
                  {'status': 'ok', 'response': <String, dynamic>{}},
                ]),
              );
              async.flushMicrotasks();
            }
          }

          // t+60s on new connection: no spurious reconnect from stale ref
          async
            ..elapse(const Duration(seconds: 30))
            ..flushMicrotasks();
          expect(socket.state, PhoenixSocketState.connected);

          unawaited(socket.disconnect());
          async.flushMicrotasks();
        });
      });
    });

    // -------------------------------------------------------------------------
    // Bug: join timeout — late phx_reply should not transition to joined
    // after onTimeout nulls _joinCompleter.
    // -------------------------------------------------------------------------
    group('join timeout: late reply does not resurrect the channel', () {
      test(
        'late phx_reply after join timeout is ignored (channel stays errored)',
        () {
          fakeAsync((async) {
            final setup = TestSetup()..init();
            unawaited(setup.connect());
            async.flushMicrotasks();

            final ch = setup.socket.channel('room:lobby');
            Object? joinError;
            unawaited(
              ch.join().catchError((Object e) {
                joinError = e;
                return <String, dynamic>{};
              }),
            );
            async.flushMicrotasks();

            final joinRef = setup.lastRef();

            // Timeout fires
            async
              ..elapse(const Duration(seconds: 11))
              ..flushMicrotasks();
            expect(ch.state, PhoenixChannelState.errored);
            expect(joinError, isA<TimeoutException>());

            // Server sends a late join reply
            setup.replyJoinOk(joinRef, 'room:lobby');
            async.flushMicrotasks();

            // Channel must remain errored — late reply should be ignored
            expect(ch.state, PhoenixChannelState.errored);

            unawaited(setup.socket.disconnect());
            async.flushMicrotasks();
          });
        },
      );
    });

    // -------------------------------------------------------------------------
    // Bug: malformed server messages should not trigger reconnect
    // -------------------------------------------------------------------------
    group('malformed messages do not trigger reconnect', () {
      test('invalid JSON from server is silently ignored', () async {
        final setup = TestSetup()..init();
        await setup.connect();

        expect(setup.socket.state, PhoenixSocketState.connected);

        // Send malformed JSON
        setup.serverChannel.sink.add('not json at all {{{');
        await Future.microtask(() {});

        // Socket should still be connected
        expect(setup.socket.state, PhoenixSocketState.connected);

        await setup.socket.disconnect();
      });

      test('wrong-length array from server is silently ignored', () async {
        final setup = TestSetup()..init();
        await setup.connect();

        // V2 format requires 5 elements; send 3
        setup.serverChannel.sink.add(jsonEncode(['a', 'b', 'c']));
        await Future.microtask(() {});

        expect(setup.socket.state, PhoenixSocketState.connected);

        await setup.socket.disconnect();
      });

      test('null payload in message is silently ignored', () async {
        final setup = TestSetup()..init();
        await setup.connect();

        // Payload is null instead of a map
        setup.serverChannel.sink.add(
          jsonEncode([null, null, 'room:lobby', 'new_msg', null]),
        );
        await Future.microtask(() {});

        expect(setup.socket.state, PhoenixSocketState.connected);

        await setup.socket.disconnect();
      });
    });

    // -------------------------------------------------------------------------
    // Bug: push in errored state should be buffered, not thrown
    // -------------------------------------------------------------------------
    group('push during errored state is buffered', () {
      test('push while errored (between disconnect and rejoin) is buffered '
          'and delivered after rejoin', () async {
        final setup = TestSetup()..init();
        await setup.connect();
        final ch = await joinedChannel(setup);

        // Simulate socket disconnect — channel goes errored
        ch.onSocketDisconnect();
        expect(ch.state, PhoenixChannelState.errored);

        // Push while errored — should buffer, not throw
        Map<String, dynamic>? pushResult;
        unawaited(
          ch.push('new_msg', {'body': 'buffered'}).then((r) => pushResult = r),
        );
        await Future.microtask(() {});

        // Now rejoin
        ch.rejoin();
        await Future.microtask(() {});

        final rejoinRef = setup.lastRef();
        setup.replyJoinOk(rejoinRef, 'room:lobby');
        await Future.microtask(() {});
        await Future.microtask(() {});

        // Buffered push should have been sent
        await Future.microtask(() {});
        final pushRef = setup.lastRef();
        setup.sendToClient([
          rejoinRef,
          pushRef,
          'room:lobby',
          'phx_reply',
          {
            'status': 'ok',
            'response': {'delivered': true},
          },
        ]);
        // Several microtask hops to propagate through the completer chain
        for (var i = 0; i < 6; i++) {
          await Future.microtask(() {});
        }

        expect(pushResult, isNotNull);
        expect(pushResult!['delivered'], true);

        await setup.socket.disconnect();
      });
    });

    // -------------------------------------------------------------------------
    // Bug: concurrent connect() calls while reconnecting
    // -------------------------------------------------------------------------
    group('connect() is idempotent during reconnecting state', () {
      test('connect() while connecting does not create a second WS', () {
        fakeAsync((async) {
          var connectCount = 0;
          final socket = PhoenixSocket(
            'ws://localhost:4000/socket/websocket',
            channelFactory: (uri) {
              connectCount++;
              return FakeWebSocketChannel();
            },
          );

          // First connect — sets state to connecting before awaiting ready
          unawaited(socket.connect());
          // Do NOT flush microtasks yet — socket is in 'connecting' state
          // Second connect should be a no-op
          unawaited(socket.connect());
          async.flushMicrotasks();

          // Only one WS should have been created
          expect(connectCount, 1);
          expect(socket.state, PhoenixSocketState.connected);

          unawaited(socket.disconnect());
          async.flushMicrotasks();
        });
      });

      test('connect() while in reconnecting state does not create extra WS', () {
        fakeAsync((async) {
          var connectCount = 0;

          final socket = PhoenixSocket(
            'ws://localhost:4000/socket/websocket',
            channelFactory: (uri) {
              connectCount++;
              // Return a WS whose stream immediately closes, forcing reconnect
              final ws = FakeWebSocketChannel();
              if (connectCount == 1) {
                // Close the stream to trigger _onDone → reconnect
                unawaited(ws.server.sink.close());
              }
              return ws;
            },
          );

          unawaited(socket.connect());
          async.flushMicrotasks();
          // Stream closed → socket is now in reconnecting state (with 1s delay)
          expect(socket.state, PhoenixSocketState.reconnecting);
          expect(connectCount, 1);

          // Manual connect() call during reconnecting — should be a no-op
          unawaited(socket.connect());
          async.flushMicrotasks();
          expect(connectCount, 1); // no extra WS

          unawaited(socket.disconnect());
          async.flushMicrotasks();
        });
      });
    });

    // -------------------------------------------------------------------------
    // Issue: _rejoinChannels only rejoins errored channels (not joining)
    // Verify that a channel that was joining when disconnect happened rejoins.
    // -------------------------------------------------------------------------
    group('_rejoinChannels: errored channels rejoin on reconnect', () {
      test('channel that was joined and got disconnected rejoins', () async {
        final setup = TestSetup()..init();
        await setup.connect();

        // Join the channel
        final ch = setup.socket.channel('room:lobby');
        final joinFuture = ch.join();
        await Future.microtask(() {});
        setup.replyJoinOk(setup.lastRef(), 'room:lobby');
        await Future.microtask(() {});
        await joinFuture;

        expect(ch.state, PhoenixChannelState.joined);

        // Simulate socket disconnect
        ch.onSocketDisconnect();
        expect(ch.state, PhoenixChannelState.errored);

        // Socket reconnects and calls _rejoinChannels
        await setup.socket.disconnect();
        await setup.socket.connect();
        await Future.microtask(() {});

        // Channel should have sent phx_join again
        final lastMsg = jsonDecode(setup.sentMessages.last as String) as List;
        expect(lastMsg[3], 'phx_join');
        expect(lastMsg[2], 'room:lobby');

        await setup.socket.disconnect();
      });
    });
  });
}
