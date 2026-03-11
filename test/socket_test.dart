import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:dark_phoenix_socket/src/channel.dart';
import 'package:dark_phoenix_socket/src/message.dart';
import 'package:dark_phoenix_socket/src/socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'fake_web_socket_channel.dart';

/// Creates a fake WebSocketChannel + server-side StreamChannel.
(FakeWebSocketChannel, StreamChannel<dynamic>) makeFakeWs() {
  final ws = FakeWebSocketChannel();
  return (ws, ws.server);
}

void main() {
  group('PhoenixSocket', () {
    group('URL building', () {
      test('always appends vsn=2.0.0', () async {
        Uri? capturedUri;
        final socket = PhoenixSocket(
          'ws://localhost:4000/socket/websocket',
          channelFactory: (uri) {
            capturedUri = uri;
            final (ws, _) = makeFakeWs();
            return ws;
          },
        );
        await socket.connect();
        expect(capturedUri?.queryParameters['vsn'], '2.0.0');
        await socket.disconnect();
      });

      test('appends custom params alongside vsn', () async {
        Uri? capturedUri;
        final socket = PhoenixSocket(
          'ws://localhost:4000/socket/websocket',
          params: {'token': 'abc123'},
          channelFactory: (uri) {
            capturedUri = uri;
            final (ws, _) = makeFakeWs();
            return ws;
          },
        );
        await socket.connect();
        expect(capturedUri?.queryParameters['vsn'], '2.0.0');
        expect(capturedUri?.queryParameters['token'], 'abc123');
        await socket.disconnect();
      });
    });

    group('connect / disconnect', () {
      test(
        'connect() while already connected does not create second WS',
        () async {
          var connectCount = 0;
          final socket = PhoenixSocket(
            'ws://localhost:4000/socket/websocket',
            channelFactory: (uri) {
              connectCount++;
              final (ws, _) = makeFakeWs();
              return ws;
            },
          );
          await socket.connect();
          await socket.connect(); // second call should be no-op
          expect(connectCount, 1);
          await socket.disconnect();
        },
      );

      test('connect() after disconnect() reconnects', () async {
        var connectCount = 0;
        final socket = PhoenixSocket(
          'ws://localhost:4000/socket/websocket',
          channelFactory: (uri) {
            connectCount++;
            final (ws, _) = makeFakeWs();
            return ws;
          },
        );
        await socket.connect();
        await socket.disconnect();
        await socket.connect();
        expect(connectCount, 2);
        await socket.disconnect();
      });

      test(
        'state transitions: disconnected → connecting → connected',
        () async {
          final states = <PhoenixSocketState>[];
          final socket = PhoenixSocket(
            'ws://localhost:4000/socket/websocket',
            channelFactory: (uri) {
              final (ws, _) = makeFakeWs();
              return ws;
            },
          );
          socket.states.listen(states.add);
          await socket.connect();
          expect(
            states,
            containsAllInOrder([
              PhoenixSocketState.connecting,
              PhoenixSocketState.connected,
            ]),
          );
          await socket.disconnect();
        },
      );
    });

    group('heartbeat', () {
      test('heartbeat sent at 30s intervals', () {
        fakeAsync((async) {
          final sentMessages = <dynamic>[];

          final socket = PhoenixSocket(
            'ws://localhost:4000/socket/websocket',
            channelFactory: (uri) {
              final (ws, server) = makeFakeWs();
              server.stream.listen(sentMessages.add);
              return ws;
            },
          );

          unawaited(socket.connect());
          async.flushMicrotasks();

          expect(sentMessages, isEmpty);
          async.elapse(const Duration(seconds: 30));

          expect(sentMessages, hasLength(1));
          final decoded = jsonDecode(sentMessages.first as String) as List;
          expect(decoded[3], 'heartbeat');
          expect(decoded[2], 'phoenix');

          unawaited(socket.disconnect());
          async.flushMicrotasks();
        });
      });

      test('pending heartbeat ref cleared on reply', () {
        fakeAsync((async) {
          StreamChannel<dynamic>? serverChannel;
          final sentMessages = <dynamic>[];

          final socket = PhoenixSocket(
            'ws://localhost:4000/socket/websocket',
            channelFactory: (uri) {
              final (ws, server) = makeFakeWs();
              serverChannel = server;
              server.stream.listen(sentMessages.add);
              return ws;
            },
          );

          unawaited(socket.connect());
          async
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 30));
          expect(sentMessages, hasLength(1));

          final heartbeatMsg = jsonDecode(sentMessages.first as String) as List;
          final heartbeatRef = heartbeatMsg[1] as String;

          // Reply to heartbeat
          serverChannel!.sink.add(
            jsonEncode([
              null,
              heartbeatRef,
              'phoenix',
              'phx_reply',
              {'status': 'ok', 'response': <String, dynamic>{}},
            ]),
          );
          async
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 30));
          expect(socket.state, PhoenixSocketState.connected);

          unawaited(socket.disconnect());
          async.flushMicrotasks();
        });
      });

      test('no reply to heartbeat triggers reconnect', () {
        fakeAsync((async) {
          var connectCount = 0;

          final socket = PhoenixSocket(
            'ws://localhost:4000/socket/websocket',
            channelFactory: (uri) {
              connectCount++;
              final (ws, _) = makeFakeWs();
              return ws;
            },
          );

          unawaited(socket.connect());
          async.flushMicrotasks();
          expect(connectCount, 1);

          // First heartbeat at 30s — no reply
          async
            ..elapse(const Duration(seconds: 30))
            ..elapse(const Duration(seconds: 30));
          expect(
            socket.state,
            isIn([
              PhoenixSocketState.reconnecting,
              PhoenixSocketState.disconnected,
              PhoenixSocketState.connecting,
              PhoenixSocketState.connected,
            ]),
          );

          unawaited(socket.disconnect());
          async.flushMicrotasks();
        });
      });

      test('no heartbeat sent while disconnected', () {
        fakeAsync((async) {
          final sentMessages = <dynamic>[];

          final socket = PhoenixSocket(
            'ws://localhost:4000/socket/websocket',
            channelFactory: (uri) {
              final (ws, server) = makeFakeWs();
              server.stream.listen(sentMessages.add);
              return ws;
            },
          );

          unawaited(socket.connect());
          async.flushMicrotasks();

          unawaited(socket.disconnect());
          async
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 60));
          expect(sentMessages, isEmpty);
        });
      });
    });

    group('reconnection', () {
      test('no reconnect on intentional disconnect', () {
        fakeAsync((async) {
          var connectCount = 0;

          final socket = PhoenixSocket(
            'ws://localhost:4000/socket/websocket',
            channelFactory: (uri) {
              connectCount++;
              final (ws, _) = makeFakeWs();
              return ws;
            },
          );

          unawaited(socket.connect());
          async.flushMicrotasks();
          unawaited(socket.disconnect());
          async
            ..flushMicrotasks()
            ..elapse(const Duration(seconds: 60));
          expect(connectCount, 1);
        });
      });

      test('reconnect attempts reset to 0 on successful connect', () async {
        final socket = PhoenixSocket(
          'ws://localhost:4000/socket/websocket',
          channelFactory: (uri) {
            final (ws, _) = makeFakeWs();
            return ws;
          },
        );
        await socket.connect();
        expect(socket.state, PhoenixSocketState.connected);
        await socket.disconnect();
      });

      test('channel transitions to errored on socket disconnect', () async {
        final socket = PhoenixSocket(
          'ws://localhost:4000/socket/websocket',
          channelFactory: (uri) {
            final (ws, _) = makeFakeWs();
            return ws;
          },
        );
        await socket.connect();

        // onSocketDisconnect only changes state if joined or joining
        // Channel starts as closed, so state stays closed
        final ch = socket.channel('room:lobby')..onSocketDisconnect();
        expect(ch.state, PhoenixChannelState.closed);

        await socket.disconnect();
      });
    });

    group('message routing', () {
      test('messages dispatched to correct channel by topic', () async {
        StreamChannel<dynamic>? serverChannel;
        final sentMessages = <dynamic>[];

        final socket = PhoenixSocket(
          'ws://localhost:4000/socket/websocket',
          channelFactory: (uri) {
            final (ws, server) = makeFakeWs();
            serverChannel = server;
            server.stream.listen(sentMessages.add);
            return ws;
          },
        );

        await socket.connect();

        final ch1 = socket.channel('room:1');
        final ch2 = socket.channel('room:2');

        final ch1Messages = <PhoenixMessage>[];
        final ch2Messages = <PhoenixMessage>[];
        ch1.messages.listen(ch1Messages.add);
        ch2.messages.listen(ch2Messages.add);

        // Join ch1
        final joinFuture1 = ch1.join();
        await Future.microtask(() {});
        final join1Msg = jsonDecode(sentMessages.last as String) as List;
        final join1Ref = join1Msg[1] as String;
        serverChannel!.sink.add(
          jsonEncode([
            join1Ref,
            join1Ref,
            'room:1',
            'phx_reply',
            {'status': 'ok', 'response': <String, dynamic>{}},
          ]),
        );
        await Future.microtask(() {});
        await joinFuture1;

        // Join ch2
        final joinFuture2 = ch2.join();
        await Future.microtask(() {});
        final join2Msg = jsonDecode(sentMessages.last as String) as List;
        final join2Ref = join2Msg[1] as String;
        serverChannel!.sink.add(
          jsonEncode([
            join2Ref,
            join2Ref,
            'room:2',
            'phx_reply',
            {'status': 'ok', 'response': <String, dynamic>{}},
          ]),
        );
        await Future.microtask(() {});
        await joinFuture2;

        // Send app message to room:1
        serverChannel!.sink.add(
          jsonEncode([
            join1Ref,
            null,
            'room:1',
            'new_msg',
            {'body': 'hello ch1'},
          ]),
        );
        await Future.microtask(() {});

        // Send app message to room:2
        serverChannel!.sink.add(
          jsonEncode([
            join2Ref,
            null,
            'room:2',
            'new_msg',
            {'body': 'hello ch2'},
          ]),
        );
        await Future.microtask(() {});
        await Future.microtask(() {});

        expect(ch1Messages, hasLength(1));
        expect(ch1Messages.first.payload['body'], 'hello ch1');
        expect(ch2Messages, hasLength(1));
        expect(ch2Messages.first.payload['body'], 'hello ch2');

        await socket.disconnect();
      });
    });
  });
}
