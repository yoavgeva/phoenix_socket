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

/// Test harness: socket + fake server side.
class TestSetup {
  late PhoenixSocket socket;
  late StreamChannel<dynamic> serverChannel;
  final sentMessages = <dynamic>[];

  void init({String url = 'ws://localhost:4000/socket/websocket'}) {
    socket = PhoenixSocket(
      url,
      channelFactory: (uri) {
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

  void replyPushOk(
    String joinRef,
    String ref,
    String topic, {
    Map<String, dynamic> response = const {},
  }) {
    sendToClient([
      joinRef,
      ref,
      topic,
      'phx_reply',
      {'status': 'ok', 'response': response},
    ]);
  }

  void replyPushError(
    String joinRef,
    String ref,
    String topic, {
    Map<String, dynamic> response = const {},
  }) {
    sendToClient([
      joinRef,
      ref,
      topic,
      'phx_reply',
      {'status': 'error', 'response': response},
    ]);
  }
}

/// Joins a channel and returns it (in joined state).
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
  group('PhoenixChannel', () {
    group('join', () {
      test(
        'join ok: state joining → joined, future resolves with response',
        () async {
          final setup = TestSetup()..init();
          await setup.connect();

          final ch = setup.socket.channel('room:lobby');
          expect(ch.state, PhoenixChannelState.closed);

          final joinFuture = ch.join();
          await Future.microtask(() {});
          expect(ch.state, PhoenixChannelState.joining);

          final ref = setup.lastRef();
          setup.replyJoinOk(ref, 'room:lobby', response: {'user_count': 5});
          await Future.microtask(() {});

          final response = await joinFuture;
          expect(ch.state, PhoenixChannelState.joined);
          expect(response['user_count'], 5);

          await setup.socket.disconnect();
        },
      );

      test('join error: throws PhoenixException, state errored', () async {
        final setup = TestSetup()..init();
        await setup.connect();

        final ch = setup.socket.channel('room:lobby');
        Object? caughtError;
        final joinFuture = ch.join().catchError((Object e) {
          caughtError = e;
          return <String, dynamic>{};
        });
        await Future.microtask(() {});

        final ref = setup.lastRef();
        setup.replyJoinError(
          ref,
          'room:lobby',
          response: {'reason': 'unauthorized'},
        );
        await Future.microtask(() {});
        await joinFuture;

        expect(caughtError, isA<PhoenixException>());
        expect(ch.state, PhoenixChannelState.errored);

        await setup.socket.disconnect();
      });

      test('join timeout (fake_async): state errored', () {
        fakeAsync((async) {
          final setup = TestSetup()..init();
          unawaited(setup.connect());
          async.flushMicrotasks();

          final ch = setup.socket.channel('room:lobby');
          Object? error;
          unawaited(
            ch.join().catchError((Object e) {
              error = e;
              return <String, dynamic>{};
            }),
          );
          async
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 11))
            ..flushMicrotasks();
          expect(error, isA<TimeoutException>());
          expect(ch.state, PhoenixChannelState.errored);

          unawaited(setup.socket.disconnect());
          async.flushMicrotasks();
        });
      });

      test('join called twice throws StateError', () async {
        final setup = TestSetup()..init();
        await setup.connect();

        final ch = setup.socket.channel('room:lobby');
        // Suppress firstJoin error before disconnect() fires onSocketDisconnect
        // synchronously (which errors the join completer).
        final firstJoin = ch.join()..ignore();
        await expectLater(ch.join(), throwsStateError);

        await setup.socket.disconnect();
      });

      test(
        'phx_close before join reply: state closed, join future fails',
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
            'phx_close',
            <String, dynamic>{},
          ]);
          await Future.microtask(() {});
          await joinFuture;

          expect(ch.state, PhoenixChannelState.closed);
          expect(joinError, isA<PhoenixException>());
          await setup.socket.disconnect();
        },
      );

      test('phx_error event: state errored, join future fails', () async {
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

        expect(ch.state, PhoenixChannelState.errored);
        expect(joinError, isA<PhoenixException>());
        await setup.socket.disconnect();
      });
    });

    group('push', () {
      test('push ok: future resolves with reply payload', () async {
        final setup = TestSetup()..init();
        await setup.connect();
        final ch = await joinedChannel(setup);
        final joinRef = setup.lastJoinRef();

        final pushFuture = ch.push('new_msg', {'body': 'hello'});
        await Future.microtask(() {});

        final pushRef = setup.lastRef();
        setup.replyPushOk(joinRef, pushRef, 'room:lobby', response: {'id': 42});
        await Future.microtask(() {});

        final response = await pushFuture;
        expect(response['id'], 42);

        await setup.socket.disconnect();
      });

      test('push error: throws PhoenixException', () async {
        final setup = TestSetup()..init();
        await setup.connect();
        final ch = await joinedChannel(setup);
        final joinRef = setup.lastJoinRef();

        Object? caughtError;
        final pushFuture = ch.push('new_msg', {'body': 'hello'}).catchError((
          Object e,
        ) {
          caughtError = e;
          return <String, dynamic>{};
        });
        await Future.microtask(() {});

        final pushRef = setup.lastRef();
        setup.replyPushError(
          joinRef,
          pushRef,
          'room:lobby',
          response: {'reason': 'forbidden'},
        );
        await Future.microtask(() {});
        await pushFuture;

        expect(caughtError, isA<PhoenixException>());

        await setup.socket.disconnect();
      });

      test('push timeout (fake_async): throws TimeoutException', () {
        fakeAsync((async) {
          final setup = TestSetup()..init();
          unawaited(setup.connect());
          async.flushMicrotasks();

          final ch = setup.socket.channel('room:lobby');
          final joinFuture = ch.join();
          async.flushMicrotasks();

          final joinRef = setup.lastRef();
          setup.replyJoinOk(joinRef, 'room:lobby');
          async.flushMicrotasks();

          Object? error;
          unawaited(
            ch.push('new_msg', {'body': 'hi'}).catchError((Object e) {
              error = e;
              return <String, dynamic>{};
            }),
          );
          async
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 11))
            ..flushMicrotasks();
          expect(error, isA<TimeoutException>());

          unawaited(setup.socket.disconnect());
          async.flushMicrotasks();
          joinFuture.ignore();
        });
      });

      test('push before join() called throws StateError', () async {
        final setup = TestSetup()..init();
        await setup.connect();

        final ch = setup.socket.channel('room:lobby');
        expect(
          () => ch.push('new_msg', {'body': 'hi'}),
          throwsStateError,
        );

        await setup.socket.disconnect();
      });

      test('push while joining is buffered and sent after join', () async {
        final setup = TestSetup()..init();
        await setup.connect();

        final ch = setup.socket.channel('room:lobby');
        final joinFuture = ch.join();
        await Future.microtask(() {});

        // Push while still in joining state — should be buffered
        final pushFuture = ch.push('new_msg', {'body': 'buffered'});
        await Future.microtask(() {});

        // Reply to join
        final joinRef = setup.lastJoinRef();
        final joinMsgRef = setup.lastRef();
        setup.replyJoinOk(joinMsgRef, 'room:lobby');
        await Future.microtask(() {});
        await Future.microtask(() {});
        await joinFuture;

        // Buffered push should now be sent
        await Future.microtask(() {});
        final pushRef = setup.lastRef();
        setup.replyPushOk(
          joinRef,
          pushRef,
          'room:lobby',
          response: {'sent': true},
        );
        await Future.microtask(() {});

        final response = await pushFuture;
        expect(response['sent'], true);

        await setup.socket.disconnect();
      });

      test('push after leave() throws StateError', () async {
        final setup = TestSetup()..init();
        await setup.connect();
        final ch = await joinedChannel(setup);
        final joinRef = setup.lastJoinRef();

        final leaveFuture = ch.leave();
        await Future.microtask(() {});
        final leaveRef = setup.lastRef();
        setup.sendToClient([
          joinRef,
          leaveRef,
          'room:lobby',
          'phx_reply',
          {'status': 'ok', 'response': <String, dynamic>{}},
        ]);
        await Future.microtask(() {});
        await leaveFuture;

        expect(ch.state, PhoenixChannelState.closed);
        expect(() => ch.push('new_msg', {'body': 'late'}), throwsStateError);

        await setup.socket.disconnect();
      });
    });

    group('messages stream', () {
      test('app events emitted on messages stream', () async {
        final setup = TestSetup()..init();
        await setup.connect();
        final ch = await joinedChannel(setup);
        final joinRef = setup.lastJoinRef();

        final received = <PhoenixMessage>[];
        ch.messages.listen(received.add);

        setup.sendToClient([
          joinRef,
          null,
          'room:lobby',
          'new_msg',
          {'body': 'hi'},
        ]);
        await Future.microtask(() {});
        await Future.microtask(() {});

        expect(received, hasLength(1));
        expect(received.first.event, 'new_msg');
        expect(received.first.payload['body'], 'hi');

        await setup.socket.disconnect();
      });

      test('phx_reply events NOT emitted on messages stream', () async {
        final setup = TestSetup()..init();
        await setup.connect();
        final ch = await joinedChannel(setup);
        final joinRef = setup.lastJoinRef();

        final received = <PhoenixMessage>[];
        ch.messages.listen(received.add);

        setup.sendToClient([
          joinRef,
          '99',
          'room:lobby',
          'phx_reply',
          {'status': 'ok', 'response': <String, dynamic>{}},
        ]);
        await Future.microtask(() {});
        await Future.microtask(() {});

        expect(received, isEmpty);

        await setup.socket.disconnect();
      });

      test(
        'phx_join/phx_leave/phx_close NOT emitted on messages stream',
        () async {
          final setup = TestSetup()..init();
          await setup.connect();
          final ch = await joinedChannel(setup);

          final received = <PhoenixMessage>[];
          ch.messages.listen(received.add);

          for (final evt in ['phx_join', 'phx_leave', 'phx_close']) {
            setup.sendToClient([
              null,
              null,
              'room:lobby',
              evt,
              <String, dynamic>{},
            ]);
          }
          await Future.microtask(() {});
          await Future.microtask(() {});

          expect(received, isEmpty);

          await setup.socket.disconnect();
        },
      );

      test('messages with stale joinRef are dropped silently', () async {
        final setup = TestSetup()..init();
        await setup.connect();
        final ch = await joinedChannel(setup);

        final received = <PhoenixMessage>[];
        ch.messages.listen(received.add);

        setup.sendToClient([
          'stale-join-ref',
          null,
          'room:lobby',
          'new_msg',
          {'body': 'stale'},
        ]);
        await Future.microtask(() {});
        await Future.microtask(() {});

        expect(received, isEmpty);

        await setup.socket.disconnect();
      });

      test('messages stream is broadcast (multiple listeners)', () async {
        final setup = TestSetup()..init();
        await setup.connect();
        final ch = await joinedChannel(setup);
        final joinRef = setup.lastJoinRef();

        final received1 = <PhoenixMessage>[];
        final received2 = <PhoenixMessage>[];
        ch
          ..messages.listen(received1.add)
          ..messages.listen(received2.add);
        setup.sendToClient([
          joinRef,
          null,
          'room:lobby',
          'new_msg',
          {'body': 'broadcast'},
        ]);
        await Future.microtask(() {});
        await Future.microtask(() {});

        expect(received1, hasLength(1));
        expect(received2, hasLength(1));

        await setup.socket.disconnect();
      });
    });

    group('leave', () {
      test('leave: state leaving → closed', () async {
        final setup = TestSetup()..init();
        await setup.connect();
        final ch = await joinedChannel(setup);
        final joinRef = setup.lastJoinRef();

        expect(ch.state, PhoenixChannelState.joined);

        final leaveFuture = ch.leave();
        await Future.microtask(() {});
        expect(ch.state, PhoenixChannelState.leaving);

        final leaveRef = setup.lastRef();
        setup.sendToClient([
          joinRef,
          leaveRef,
          'room:lobby',
          'phx_reply',
          {'status': 'ok', 'response': <String, dynamic>{}},
        ]);
        await Future.microtask(() {});
        await leaveFuture;

        expect(ch.state, PhoenixChannelState.closed);

        await setup.socket.disconnect();
      });

      test(
        'pending push Completers error-completed on socket disconnect',
        () async {
          final setup = TestSetup()..init();
          await setup.connect();
          final ch = await joinedChannel(setup);

          Object? pushError;
          unawaited(
            ch.push('new_msg', {'body': 'hi'}).catchError((Object e) {
              pushError = e;
              return <String, dynamic>{};
            }),
          );
          await Future.microtask(() {});

          await setup.socket.disconnect();
          await Future.microtask(() {});

          expect(pushError, isA<PhoenixException>());
        },
      );
    });

    group('rejoin', () {
      test('rejoin re-sends phx_join with original payload', () async {
        final setup = TestSetup()..init();
        await setup.connect();

        final ch = setup.socket.channel('room:lobby');
        final joinFuture = ch.join(payload: {'token': 'mytoken'});
        await Future.microtask(() {});
        final joinRef = setup.lastRef();
        setup.replyJoinOk(joinRef, 'room:lobby');
        await Future.microtask(() {});
        await joinFuture;

        final countBefore = setup.sentMessages.length;
        ch.rejoin();
        await Future.microtask(() {});

        expect(setup.sentMessages.length, countBefore + 1);
        final rejoinMsg = jsonDecode(setup.sentMessages.last as String) as List;
        expect(rejoinMsg[3], 'phx_join');
        expect(rejoinMsg[4], {'token': 'mytoken'});

        await setup.socket.disconnect();
      });

      test(
        'channel transitions to errored state when joined and disconnected',
        () async {
          final setup = TestSetup()..init();
          await setup.connect();

          final ch = await joinedChannel(setup);
          expect(ch.state, PhoenixChannelState.joined);

          ch.onSocketDisconnect();
          expect(ch.state, PhoenixChannelState.errored);

          await setup.socket.disconnect();
        },
      );

      test('rejoin failure sets state back to errored', () async {
        final setup = TestSetup()..init();
        await setup.connect();

        final ch = setup.socket.channel('room:lobby');
        final joinFuture = ch.join(payload: {'x': 1});
        await Future.microtask(() {});
        final joinRef = setup.lastRef();
        setup.replyJoinOk(joinRef, 'room:lobby');
        await Future.microtask(() {});
        await joinFuture;

        // Trigger rejoin
        ch.rejoin();
        await Future.microtask(() {});

        // Reply with error
        final rejoinRef = setup.lastRef();
        setup.replyJoinError(rejoinRef, 'room:lobby');
        await Future.microtask(() {});
        await Future.microtask(() {});

        expect(ch.state, PhoenixChannelState.errored);

        await setup.socket.disconnect();
      });
    });
  });
}
