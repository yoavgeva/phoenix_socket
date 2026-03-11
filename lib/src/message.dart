import 'dart:convert';

import 'package:meta/meta.dart';

/// Represents a Phoenix Channel V2 message.
///
/// Wire format: `[join_ref, ref, topic, event, payload]`
@immutable
class PhoenixMessage {
  /// Creates a [PhoenixMessage].
  const PhoenixMessage({
    required this.joinRef,
    required this.ref,
    required this.topic,
    required this.event,
    required this.payload,
  });

  /// Parses a V2 Phoenix message from its JSON array representation.
  ///
  /// Expects: `[join_ref, ref, topic, event, payload]`
  factory PhoenixMessage.fromJson(List<dynamic> json) {
    if (json.length != 5) {
      throw const FormatException(
        'PhoenixMessage expects a 5-element array',
      );
    }
    final topic = json[2];
    if (topic == null) {
      throw const FormatException(
        'PhoenixMessage topic must not be null',
      );
    }
    final event = json[3];
    if (event == null) {
      throw const FormatException(
        'PhoenixMessage event must not be null',
      );
    }
    return PhoenixMessage(
      joinRef: json[0] as String?,
      ref: json[1] as String?,
      topic: topic as String,
      event: event as String,
      // Bug fix: payload may be null (some servers send null for empty
      // payloads) or a non-map type. Default to empty map rather than
      // throwing TypeError.
      payload: json[4] == null
          ? const <String, dynamic>{}
          : (json[4] as Map<dynamic, dynamic>).cast<String, dynamic>(),
    );
  }

  /// The join reference. May be null for server broadcasts.
  final String? joinRef;

  /// The message reference used to correlate replies.
  /// May be null for server pushes.
  final String? ref;

  /// The topic this message belongs to (e.g. `"room:lobby"`).
  final String topic;

  /// The event name (e.g. `"new_msg"`, `"phx_join"`, `"phx_reply"`).
  final String event;

  /// The message payload.
  final Map<String, dynamic> payload;

  /// Serializes this message to a JSON array.
  List<dynamic> toJson() => [joinRef, ref, topic, event, payload];

  /// Encodes this message to a JSON string for transmission.
  String encode() => jsonEncode(toJson());

  @override
  String toString() =>
      'PhoenixMessage('
      'joinRef: $joinRef, '
      'ref: $ref, '
      'topic: $topic, '
      'event: $event, '
      'payload: $payload)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PhoenixMessage &&
          joinRef == other.joinRef &&
          ref == other.ref &&
          topic == other.topic &&
          event == other.event &&
          payload.toString() == other.payload.toString();

  @override
  int get hashCode =>
      Object.hash(joinRef, ref, topic, event, payload.toString());
}
