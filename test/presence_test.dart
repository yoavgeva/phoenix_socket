// Presence tests ported from the official Phoenix JS test suite:
// https://github.com/phoenixframework/phoenix/blob/main/assets/test/presence_test.js
//
// Every describe/it block from the JS file is represented here as a
// group/test with the same name so they are easy to cross-reference.

import 'dart:convert';

import 'package:phoenix_socket/src/channel.dart';
import 'package:phoenix_socket/src/message.dart';
import 'package:phoenix_socket/src/presence.dart';
import 'package:phoenix_socket/src/socket.dart';
import 'package:test/test.dart';

import 'fake_web_socket_channel.dart';

// ---------------------------------------------------------------------------
// Fixtures — mirror JS fixtures exactly
// ---------------------------------------------------------------------------

Map<String, PresenceEntry> stateFixture() => {
  'u1': (
    metas: [
      {'id': 1, 'phx_ref': '1'},
    ],
  ),
  'u2': (
    metas: [
      {'id': 2, 'phx_ref': '2'},
    ],
  ),
  'u3': (
    metas: [
      {'id': 3, 'phx_ref': '3'},
    ],
  ),
};

Map<String, PresenceEntry> joinsFixture() => {
  'u1': (
    metas: [
      {'id': 1, 'phx_ref': '1.2'},
    ],
  ),
};

Map<String, PresenceEntry> leavesFixture() => {
  'u2': (
    metas: [
      {'id': 2, 'phx_ref': '2'},
    ],
  ),
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Deep-clones a PresenceState via JSON (same as JS clone()).
PresenceState cloneState(PresenceState s) {
  final encoded = jsonEncode(s.map((k, v) => MapEntry(k, {'metas': v.metas})));
  final decoded = jsonDecode(encoded) as Map<String, dynamic>;
  return decoded.map((k, v) {
    final metas = (v['metas'] as List)
        .map((m) => (m as Map).cast<String, dynamic>())
        .toList();
    return MapEntry(k, (metas: metas));
  });
}

/// Converts a PresenceState to a plain map for comparison.
Map<String, dynamic> stateToMap(PresenceState s) =>
    s.map((k, v) => MapEntry(k, {'metas': v.metas}));

// ---------------------------------------------------------------------------
// Channel stub — mirrors JS channelStub
// ---------------------------------------------------------------------------

/// A minimal fake PhoenixChannel that lets tests trigger presence_state /
/// presence_diff events and simulate disconnect+reconnect (ref increment).
class ChannelStub extends PhoenixChannel {
  ChannelStub() : super('room:stub', _makeSocket());
  int _ref = 1;

  // We need a real PhoenixSocket for the super constructor, but we never
  // actually connect it in these tests.
  static PhoenixSocket _makeSocket() {
    return PhoenixSocket(
      'ws://localhost:4000/socket/websocket',
      channelFactory: (uri) => FakeWebSocketChannel(),
    );
  }

  @override
  String? get joinRef => '$_ref';

  /// Deliver a presence_state or presence_diff payload directly to the
  /// channel's message stream (bypasses the socket routing layer).
  void trigger(String event, Map<String, dynamic> payload) {
    receive(
      PhoenixMessage(
        joinRef: '$_ref',
        ref: null,
        topic: 'room:stub',
        event: event,
        payload: payload,
      ),
    );
  }

  /// Simulate a disconnect + reconnect: increments the join ref so that
  /// [PhoenixPresence.inPendingSyncState] returns true until the next
  /// presence_state arrives.
  void simulateDisconnectAndReconnect() {
    _ref++;
  }
}

// ---------------------------------------------------------------------------
// Encode helpers: convert PresenceEntry maps to raw wire payloads
// ---------------------------------------------------------------------------

Map<String, dynamic> encodeState(Map<String, PresenceEntry> state) =>
    state.map((k, v) => MapEntry(k, {'metas': v.metas}));

Map<String, dynamic> encodeDiff({
  Map<String, PresenceEntry> joins = const {},
  Map<String, PresenceEntry> leaves = const {},
}) => {
  'joins': joins.map((k, v) => MapEntry(k, {'metas': v.metas})),
  'leaves': leaves.map((k, v) => MapEntry(k, {'metas': v.metas})),
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // =========================================================================
  // syncState
  // =========================================================================
  group('syncState', () {
    test('syncs empty state', () {
      final newState = {
        'u1': (
          metas:
              [
                    {'id': 1, 'phx_ref': '1'},
                  ]
                  as List<Map<String, dynamic>>,
        ),
      };
      var state = <String, PresenceEntry>{};
      final stateBefore = cloneState(state);

      // Calling syncState does NOT mutate the input
      PhoenixPresence.syncState(state, newState);
      expect(stateToMap(state), equals(stateToMap(stateBefore)));

      state = PhoenixPresence.syncState(state, newState);
      expect(stateToMap(state), equals(stateToMap(newState)));
    });

    test('onJoins new presences and onLeaves left presences', () {
      final newState = stateFixture();
      var state = {
        'u4': (
          metas:
              [
                    {'id': 4, 'phx_ref': '4'},
                  ]
                  as List<Map<String, dynamic>>,
        ),
      };
      final joined = <String, Map<String, dynamic>>{};
      final left = <String, Map<String, dynamic>>{};

      state = PhoenixPresence.syncState(
        state,
        newState,
        onJoin: (key, current, newPres) {
          joined[key] = {
            'current': current == null ? null : {'metas': current.metas},
            'newPres': {'metas': newPres.metas},
          };
        },
        onLeave: (key, current, leftPres) {
          left[key] = {
            'current': {'metas': current.metas},
            'leftPres': {'metas': leftPres.metas},
          };
        },
      );

      expect(stateToMap(state), equals(stateToMap(newState)));

      expect(
        joined,
        equals({
          'u1': {
            'current': null,
            'newPres': {
              'metas': [
                {'id': 1, 'phx_ref': '1'},
              ],
            },
          },
          'u2': {
            'current': null,
            'newPres': {
              'metas': [
                {'id': 2, 'phx_ref': '2'},
              ],
            },
          },
          'u3': {
            'current': null,
            'newPres': {
              'metas': [
                {'id': 3, 'phx_ref': '3'},
              ],
            },
          },
        }),
      );

      expect(
        left,
        equals({
          'u4': {
            'current': {'metas': []}, // after removal metas is empty
            'leftPres': {
              'metas': [
                {'id': 4, 'phx_ref': '4'},
              ],
            },
          },
        }),
      );
    });

    test('onJoins only newly added metas', () {
      final newState = {
        'u3': (
          metas:
              [
                    {'id': 3, 'phx_ref': '3'},
                    {'id': 3, 'phx_ref': '3.new'},
                  ]
                  as List<Map<String, dynamic>>,
        ),
      };
      var state = {
        'u3': (
          metas:
              [
                    {'id': 3, 'phx_ref': '3'},
                  ]
                  as List<Map<String, dynamic>>,
        ),
      };
      final joined = <List<dynamic>>[];
      final left = <List<dynamic>>[];

      state = PhoenixPresence.syncState(
        state,
        cloneState(newState),
        onJoin: (key, current, newPres) {
          joined.add([
            key,
            {
              'current': current == null ? null : {'metas': current.metas},
              'newPres': {'metas': newPres.metas},
            },
          ]);
        },
        onLeave: (key, current, leftPres) {
          left.add([
            key,
            {
              'current': {'metas': current.metas},
              'leftPres': {'metas': leftPres.metas},
            },
          ]);
        },
      );

      expect(stateToMap(state), equals(stateToMap(newState)));
      expect(
        joined,
        equals([
          [
            'u3',
            {
              'current': {
                'metas': [
                  {'id': 3, 'phx_ref': '3'},
                ],
              },
              'newPres': {
                'metas': [
                  {'id': 3, 'phx_ref': '3.new'},
                ],
              },
            },
          ],
        ]),
      );
      expect(left, isEmpty);
    });
  });

  // =========================================================================
  // syncDiff
  // =========================================================================
  group('syncDiff', () {
    test('syncs empty state', () {
      final joins = {
        'u1': (
          metas:
              [
                    {'id': 1, 'phx_ref': '1'},
                  ]
                  as List<Map<String, dynamic>>,
        ),
      };
      final state = PhoenixPresence.syncDiff(
        {},
        joins: joins,
        leaves: {},
      );
      expect(stateToMap(state), equals(stateToMap(joins)));
    });

    test('removes presence when meta is empty and adds additional meta', () {
      var state = stateFixture();
      state = PhoenixPresence.syncDiff(
        state,
        joins: joinsFixture(),
        leaves: leavesFixture(),
      );

      expect(
        stateToMap(state),
        equals({
          'u1': {
            'metas': [
              {'id': 1, 'phx_ref': '1'},
              {'id': 1, 'phx_ref': '1.2'},
            ],
          },
          'u3': {
            'metas': [
              {'id': 3, 'phx_ref': '3'},
            ],
          },
        }),
      );
    });

    test('removes meta while leaving key if other metas exist', () {
      var state = {
        'u1': (
          metas:
              [
                    {'id': 1, 'phx_ref': '1'},
                    {'id': 1, 'phx_ref': '1.2'},
                  ]
                  as List<Map<String, dynamic>>,
        ),
      };
      state = PhoenixPresence.syncDiff(
        state,
        joins: {},
        leaves: {
          'u1': (
            metas:
                [
                      {'id': 1, 'phx_ref': '1'},
                    ]
                    as List<Map<String, dynamic>>,
          ),
        },
      );

      expect(
        stateToMap(state),
        equals({
          'u1': {
            'metas': [
              {'id': 1, 'phx_ref': '1.2'},
            ],
          },
        }),
      );
    });
  });

  // =========================================================================
  // list
  // =========================================================================
  group('list', () {
    test('lists full presence by default', () {
      final state = stateFixture();
      final result = PhoenixPresence.listPresences(
        state,
        (key, entry) => entry,
      );
      expect(
        result.map((e) => {'metas': e.metas}).toList(),
        equals([
          {
            'metas': [
              {'id': 1, 'phx_ref': '1'},
            ],
          },
          {
            'metas': [
              {'id': 2, 'phx_ref': '2'},
            ],
          },
          {
            'metas': [
              {'id': 3, 'phx_ref': '3'},
            ],
          },
        ]),
      );
    });

    test('lists with custom function', () {
      final state = {
        'u1': (
          metas:
              [
                    {'id': 1, 'phx_ref': '1.first'},
                    {'id': 1, 'phx_ref': '1.second'},
                  ]
                  as List<Map<String, dynamic>>,
        ),
      };
      final result = PhoenixPresence.listPresences(
        state,
        (key, entry) => entry.metas.first,
      );
      expect(
        result,
        equals([
          {'id': 1, 'phx_ref': '1.first'},
        ]),
      );
    });
  });

  // =========================================================================
  // instance (integration with PhoenixChannel)
  // =========================================================================
  group('instance', () {
    late ChannelStub channel;

    setUp(() => channel = ChannelStub());

    test('syncs state and diffs', () {
      final presence = PhoenixPresence(channel: channel);
      final user1 = (
        metas:
            [
                  {'id': 1, 'phx_ref': '1'},
                ]
                as List<Map<String, dynamic>>,
      );
      final user2 = (
        metas:
            [
                  {'id': 2, 'phx_ref': '2'},
                ]
                as List<Map<String, dynamic>>,
      );

      channel.trigger(
        'presence_state',
        encodeState({'u1': user1, 'u2': user2}),
      );

      expect(
        presence.list((key, e) => e.metas.first),
        equals([
          {'id': 1, 'phx_ref': '1'},
          {'id': 2, 'phx_ref': '2'},
        ]),
      );

      channel.trigger('presence_diff', encodeDiff(leaves: {'u1': user1}));

      expect(
        presence.list((key, e) => e.metas.first),
        equals([
          {'id': 2, 'phx_ref': '2'},
        ]),
      );
    });

    test('applies pending diff if state is not yet synced', () {
      final presence = PhoenixPresence(channel: channel);
      final onJoins = <Map<String, dynamic>>[];
      final onLeaves = <Map<String, dynamic>>[];

      presence
        ..onJoin = (id, current, newPres) {
          onJoins.add({
            'id': id,
            'current': current == null ? null : {'metas': current.metas},
            'newPres': {'metas': newPres.metas},
          });
        }
        ..onLeave = (id, current, leftPres) {
          onLeaves.add({
            'id': id,
            'current': {'metas': current.metas},
            'leftPres': {'metas': leftPres.metas},
          });
        };

      final user1 = (
        metas:
            [
                  {'id': 1, 'phx_ref': '1'},
                ]
                as List<Map<String, dynamic>>,
      );
      final user2 = (
        metas:
            [
                  {'id': 2, 'phx_ref': '2'},
                ]
                as List<Map<String, dynamic>>,
      );
      final user3 = (
        metas:
            [
                  {'id': 3, 'phx_ref': '3'},
                ]
                as List<Map<String, dynamic>>,
      );

      // Diff arrives BEFORE state snapshot
      channel.trigger('presence_diff', encodeDiff(leaves: {'u2': user2}));

      expect(presence.list((k, e) => e.metas.first), isEmpty);
      expect(presence.inPendingSyncState, isTrue);

      // State snapshot arrives — pending diff applied in order
      channel.trigger(
        'presence_state',
        encodeState({'u1': user1, 'u2': user2}),
      );

      expect(
        onLeaves,
        equals([
          {
            'id': 'u2',
            'current': {'metas': []},
            'leftPres': {
              'metas': [
                {'id': 2, 'phx_ref': '2'},
              ],
            },
          },
        ]),
      );
      expect(
        presence.list((k, e) => e.metas.first),
        equals([
          {'id': 1, 'phx_ref': '1'},
        ]),
      );
      expect(presence.inPendingSyncState, isFalse);
      expect(
        onJoins,
        equals([
          {
            'id': 'u1',
            'current': null,
            'newPres': {
              'metas': [
                {'id': 1, 'phx_ref': '1'},
              ],
            },
          },
          {
            'id': 'u2',
            'current': null,
            'newPres': {
              'metas': [
                {'id': 2, 'phx_ref': '2'},
              ],
            },
          },
        ]),
      );

      // Simulate reconnect — joinRef changes → back to pending sync state
      channel.simulateDisconnectAndReconnect();
      expect(presence.inPendingSyncState, isTrue);

      // Diff arrives before new snapshot — queued
      channel.trigger('presence_diff', encodeDiff(leaves: {'u1': user1}));
      // State still shows u1 (diff not applied yet)
      expect(
        presence.list((k, e) => e.metas.first),
        equals([
          {'id': 1, 'phx_ref': '1'},
        ]),
      );

      // New state snapshot arrives with u1 + u3 — pending diff applied after
      channel.trigger(
        'presence_state',
        encodeState({'u1': user1, 'u3': user3}),
      );
      expect(
        presence.list((k, e) => e.metas.first),
        equals([
          {'id': 3, 'phx_ref': '3'},
        ]),
      );
    });

    test('updates existing meta for a presence update (leave + join)', () {
      final presence = PhoenixPresence(channel: channel);
      final onJoins = <Map<String, dynamic>>[];
      final onLeaves = <Map<String, dynamic>>[];

      final user1 = (
        metas:
            [
                  {'id': 1, 'phx_ref': '1'},
                ]
                as List<Map<String, dynamic>>,
      );
      final user2 = (
        metas:
            [
                  {'id': 2, 'name': 'chris', 'phx_ref': '2'},
                ]
                as List<Map<String, dynamic>>,
      );

      channel.trigger(
        'presence_state',
        encodeState({'u1': user1, 'u2': user2}),
      );

      presence
        ..onJoin = (id, current, newPres) {
          onJoins.add({
            'id': id,
            'current': current == null ? null : {'metas': current.metas},
            'newPres': {'metas': newPres.metas},
          });
        }
        ..onLeave = (id, current, leftPres) {
          onLeaves.add({
            'id': id,
            'current': {'metas': current.metas},
            'leftPres': {'metas': leftPres.metas},
          });
        };

      expect(
        presence.list((id, e) => e.metas),
        equals([
          [
            {'id': 1, 'phx_ref': '1'},
          ],
          [
            {'id': 2, 'name': 'chris', 'phx_ref': '2'},
          ],
        ]),
      );

      // Server sends leave+join for u2 (meta update)
      final user2Updated = (
        metas:
            [
                  {
                    'id': 2,
                    'name': 'chris.2',
                    'phx_ref': '2.2',
                    'phx_ref_prev': '2',
                  },
                ]
                as List<Map<String, dynamic>>,
      );

      channel.trigger(
        'presence_diff',
        encodeDiff(
          joins: {'u2': user2Updated},
          leaves: {'u2': user2},
        ),
      );

      expect(
        presence.list((id, e) => e.metas),
        equals([
          [
            {'id': 1, 'phx_ref': '1'},
          ],
          [
            {'id': 2, 'name': 'chris.2', 'phx_ref': '2.2', 'phx_ref_prev': '2'},
          ],
        ]),
      );

      expect(
        onJoins,
        equals([
          {
            'id': 'u2',
            'current': {
              'metas': [
                {'id': 2, 'name': 'chris', 'phx_ref': '2'},
              ],
            },
            'newPres': {
              'metas': [
                {
                  'id': 2,
                  'name': 'chris.2',
                  'phx_ref': '2.2',
                  'phx_ref_prev': '2',
                },
              ],
            },
          },
        ]),
      );
    });

    test('onSync callback fired after state and diff', () {
      var syncCount = 0;
      final presence = PhoenixPresence(channel: channel)
        ..onSync = () => syncCount++;

      final user1 = (
        metas:
            [
                  {'id': 1, 'phx_ref': '1'},
                ]
                as List<Map<String, dynamic>>,
      );

      channel.trigger('presence_state', encodeState({'u1': user1}));
      expect(syncCount, 1);

      channel.trigger('presence_diff', encodeDiff(leaves: {'u1': user1}));
      expect(syncCount, 2);
    });

    test(
      'pending diffs flushed once each — onSync fires once per state event',
      () {
        var syncCount = 0;
        final presence = PhoenixPresence(channel: channel)
          ..onSync = () => syncCount++;

        final user1 = (
          metas:
              [
                    {'id': 1, 'phx_ref': '1'},
                  ]
                  as List<Map<String, dynamic>>,
        );
        final user2 = (
          metas:
              [
                    {'id': 2, 'phx_ref': '2'},
                  ]
                  as List<Map<String, dynamic>>,
        );

        // Two diffs queued before state
        channel
          ..trigger('presence_diff', encodeDiff(joins: {'u1': user1}))
          ..trigger('presence_diff', encodeDiff(joins: {'u2': user2}));
        expect(syncCount, 0); // pending — no sync yet

        channel.trigger('presence_state', encodeState({}));
        expect(
          syncCount,
          1,
        ); // one sync after state + both pending diffs applied

        expect(
          presence.list((k, e) => e.metas.first),
          equals([
            {'id': 1, 'phx_ref': '1'},
            {'id': 2, 'phx_ref': '2'},
          ]),
        );
      },
    );

    test('multi-device: same user on two devices — metas merged correctly', () {
      final presence = PhoenixPresence(channel: channel);

      final device1 = (
        metas:
            [
                  {'phx_ref': 'ref_a', 'device': 'phone'},
                ]
                as List<Map<String, dynamic>>,
      );
      final device2 = (
        metas:
            [
                  {'phx_ref': 'ref_b', 'device': 'laptop'},
                ]
                as List<Map<String, dynamic>>,
      );

      channel.trigger('presence_state', encodeState({'u1': device1}));
      expect(presence.list((k, e) => e.metas).first, hasLength(1));

      // Second device joins
      channel.trigger('presence_diff', encodeDiff(joins: {'u1': device2}));
      final metas = presence.list((k, e) => e.metas).first;
      expect(metas, hasLength(2));
      expect(
        metas.map((m) => m['phx_ref']).toSet(),
        equals({'ref_a', 'ref_b'}),
      );

      // First device leaves
      channel.trigger('presence_diff', encodeDiff(leaves: {'u1': device1}));
      final remaining = presence.list((k, e) => e.metas).first;
      expect(remaining, hasLength(1));
      expect(remaining.first['phx_ref'], 'ref_b');
    });
  });
}
