import 'dart:convert';

import 'package:phoenix_socket/src/message.dart';
import 'package:test/test.dart';

void main() {
  group('PhoenixMessage', () {
    group('fromJson', () {
      test('parses a complete message', () {
        final msg = PhoenixMessage.fromJson(const [
          '1',
          '2',
          'room:lobby',
          'new_msg',
          {'body': 'hello'}
        ]);
        expect(msg.joinRef, '1');
        expect(msg.ref, '2');
        expect(msg.topic, 'room:lobby');
        expect(msg.event, 'new_msg');
        expect(msg.payload, {'body': 'hello'});
      });

      test('parses null joinRef (server broadcast)', () {
        final msg = PhoenixMessage.fromJson(
            const [null, '2', 'room:lobby', 'presence_state', <String, dynamic>{}]);
        expect(msg.joinRef, isNull);
        expect(msg.ref, '2');
      });

      test('parses null ref (server push without reply)', () {
        final msg = PhoenixMessage.fromJson(const [
          null,
          null,
          'room:lobby',
          'new_msg',
          {'body': 'hi'}
        ]);
        expect(msg.ref, isNull);
      });

      test('preserves all 5 fields', () {
        final msg = PhoenixMessage.fromJson(const [
          'j1',
          'r1',
          'topic',
          'event',
          {'key': 'value'}
        ]);
        expect(msg.joinRef, 'j1');
        expect(msg.ref, 'r1');
        expect(msg.topic, 'topic');
        expect(msg.event, 'event');
        expect(msg.payload, {'key': 'value'});
      });

      test('throws on array too short', () {
        expect(
          () => PhoenixMessage.fromJson(const ['a', 'b', 'c']),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws on array too long', () {
        expect(
          () => PhoenixMessage.fromJson(const ['a', 'b', 'c', 'd', 'e', 'f']),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws on null topic', () {
        expect(
          () => PhoenixMessage.fromJson(const [null, null, null, 'event', <String, dynamic>{}]),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws on null event', () {
        expect(
          () => PhoenixMessage.fromJson(const [null, null, 'topic', null, <String, dynamic>{}]),
          throwsA(isA<FormatException>()),
        );
      });
    });

    group('toJson / encode', () {
      test('round-trip serialization matches original', () {
        final original = [
          '1',
          '2',
          'room:lobby',
          'new_msg',
          {'body': 'hello'}
        ];
        final msg = PhoenixMessage.fromJson(original);
        expect(msg.toJson(), original);
      });

      test('round-trip with null fields', () {
        final original = [null, null, 'topic', 'event', <String, dynamic>{}];
        final msg = PhoenixMessage.fromJson(original);
        expect(msg.toJson()[0], isNull);
        expect(msg.toJson()[1], isNull);
      });

      test('encode produces valid JSON array string', () {
        final msg = PhoenixMessage.fromJson(const [
          '1',
          '2',
          'topic',
          'event',
          {'k': 'v'}
        ]);
        final encoded = msg.encode();
        final decoded = jsonDecode(encoded) as List<dynamic>;
        expect(decoded, isA<List<dynamic>>());
        expect(decoded[2], 'topic');
        expect(decoded[3], 'event');
      });

      test('fromJson(toJson()) round-trip is equal', () {
        final msg = PhoenixMessage.fromJson(const [
          'j1',
          'r1',
          'room:test',
          'my_event',
          {'x': 1}
        ]);
        final roundTripped = PhoenixMessage.fromJson(msg.toJson());
        expect(roundTripped, equals(msg));
      });
    });
  });
}
