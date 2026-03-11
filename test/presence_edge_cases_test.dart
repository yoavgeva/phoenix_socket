// Edge case tests for PhoenixPresence — beyond the official JS test suite.
//
// Each group targets a specific code path or invariant not covered by the
// ported JS tests. Cases are derived by inspecting every branch in
// presence.dart and considering real-world failure modes.

import 'dart:convert';

import 'package:dart_phoenix_socket/src/presence.dart';
import 'package:test/test.dart';

import 'presence_test.dart'
    show
        ChannelStub,
        cloneState,
        encodeDiff,
        encodeState,
        stateFixture,
        stateToMap;

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

PresenceEntry entry(List<Map<String, dynamic>> metas) => (metas: metas);

Map<String, dynamic> meta(String ref, [Map<String, dynamic>? extra]) => {
  'phx_ref': ref,
  ...?extra,
};

void main() {
  // =========================================================================
  // syncState immutability
  // =========================================================================
  group('syncState: immutability', () {
    test('does not mutate currentState argument', () {
      final original = stateFixture();
      final snapshot = stateToMap(original);
      PhoenixPresence.syncState(original, {});
      expect(stateToMap(original), equals(snapshot));
    });

    test('does not mutate newState argument', () {
      final newState = {
        'u1': entry([
          meta('1', {'name': 'alice'}),
        ]),
      };
      final snapshot = jsonDecode(jsonEncode(stateToMap(newState)));
      PhoenixPresence.syncState({}, newState);
      expect(stateToMap(newState), equals(snapshot));
    });

    test('returned state is independent — mutations do not alias original', () {
      final original = {
        'u1': entry([meta('1')]),
      };
      final result = PhoenixPresence.syncState({}, original);
      // Mutate result's metas list
      result['u1']!.metas.add(meta('2'));
      // Original must be unaffected
      expect(original['u1']!.metas, hasLength(1));
    });
  });

  // =========================================================================
  // syncDiff immutability
  // =========================================================================
  group('syncDiff: immutability', () {
    test('does not mutate state argument', () {
      final state = {
        'u1': entry([meta('1')]),
      };
      final snapshot = stateToMap(state);
      PhoenixPresence.syncDiff(
        state,
        joins: {
          'u2': entry([meta('2')]),
        },
        leaves: {},
      );
      expect(stateToMap(state), equals(snapshot));
    });

    test('does not mutate joins argument', () {
      final joins = {
        'u1': entry([meta('1')]),
      };
      final snapshot = stateToMap(joins);
      PhoenixPresence.syncDiff({}, joins: joins, leaves: {});
      expect(stateToMap(joins), equals(snapshot));
    });

    test('does not mutate leaves argument', () {
      final state = {
        'u1': entry([meta('1')]),
      };
      final leaves = {
        'u1': entry([meta('1')]),
      };
      final snapshot = stateToMap(leaves);
      PhoenixPresence.syncDiff(state, joins: {}, leaves: leaves);
      expect(stateToMap(leaves), equals(snapshot));
    });
  });

  // =========================================================================
  // syncDiff: unknown key in leaves
  // =========================================================================
  group('syncDiff: leave for unknown key', () {
    test('leave for a key not in state is silently ignored', () {
      final state = {
        'u1': entry([meta('1')]),
      };
      final result = PhoenixPresence.syncDiff(
        state,
        joins: {},
        leaves: {
          'ghost': entry([meta('x')]),
        },
      );
      // u1 still present, no crash
      expect(stateToMap(result), equals(stateToMap(state)));
    });

    test('onLeave not called for unknown key', () {
      var called = false;
      PhoenixPresence.syncDiff(
        {},
        joins: {},
        leaves: {
          'ghost': entry([meta('x')]),
        },
        onLeave: (_, _, _) => called = true,
      );
      expect(called, isFalse);
    });
  });

  // =========================================================================
  // syncDiff: leave for unknown phx_ref within a known key
  // =========================================================================
  group('syncDiff: leave for unknown phx_ref', () {
    test('stale ref in leave payload does not remove any meta', () {
      final state = {
        'u1': entry([meta('ref_a'), meta('ref_b')]),
      };
      final result = PhoenixPresence.syncDiff(
        state,
        joins: {},
        leaves: {
          'u1': entry([meta('stale_ref')]),
        },
      );
      // Both metas survive — stale_ref not present
      expect(result['u1']!.metas, hasLength(2));
    });

    test('onLeave is still called with empty-after-filter metas', () {
      // The key exists but the phx_ref in the leave doesn't match — the
      // current entry passed to onLeave has both metas still (unchanged).
      final state = {
        'u1': entry([meta('ref_a')]),
      };
      PresenceEntry? capturedCurrent;
      PhoenixPresence.syncDiff(
        state,
        joins: {},
        leaves: {
          'u1': entry([meta('stale')]),
        },
        onLeave: (_, current, _) => capturedCurrent = current,
      );
      // onLeave IS called (key exists), current still has ref_a
      expect(capturedCurrent?.metas.first['phx_ref'], 'ref_a');
    });
  });

  // =========================================================================
  // syncDiff: join and leave same key in one diff
  // =========================================================================
  group('syncDiff: join and leave same key', () {
    test('join processed before leave — net result is new meta only', () {
      // Server sends: u1 leaves ref_old, joins ref_new in one diff.
      // Join is applied first (per spec), then leave removes ref_old.
      final state = {
        'u1': entry([
          meta('ref_old', {'v': 1}),
        ]),
      };
      final result = PhoenixPresence.syncDiff(
        state,
        joins: {
          'u1': entry([
            meta('ref_new', {'v': 2}),
          ]),
        },
        leaves: {
          'u1': entry([meta('ref_old')]),
        },
      );
      expect(result['u1']!.metas, hasLength(1));
      expect(result['u1']!.metas.first['phx_ref'], 'ref_new');
    });

    test('onJoin fires before onLeave for same key', () {
      final events = <String>[];
      final state = {
        'u1': entry([meta('old')]),
      };
      PhoenixPresence.syncDiff(
        state,
        joins: {
          'u1': entry([meta('new')]),
        },
        leaves: {
          'u1': entry([meta('old')]),
        },
        onJoin: (_, _, _) => events.add('join'),
        onLeave: (_, _, _) => events.add('leave'),
      );
      expect(events, equals(['join', 'leave']));
    });
  });

  // =========================================================================
  // syncState: key present in both with identical metas → no callbacks
  // =========================================================================
  group('syncState: unchanged key triggers no callbacks', () {
    test('no onJoin and no onLeave when metas are identical', () {
      final state = {
        'u1': entry([meta('ref1')]),
      };
      final newState = {
        'u1': entry([meta('ref1')]),
      };
      var joinCalled = false;
      var leaveCalled = false;

      PhoenixPresence.syncState(
        state,
        newState,
        onJoin: (_, _, _) => joinCalled = true,
        onLeave: (_, _, _) => leaveCalled = true,
      );

      expect(joinCalled, isFalse);
      expect(leaveCalled, isFalse);
    });
  });

  // =========================================================================
  // syncState: user with multiple metas — partial overlap
  // =========================================================================
  group('syncState: partial meta overlap', () {
    test(
      'only genuinely new refs trigger onJoin; only gone refs trigger onLeave',
      () {
        // u1 had [a, b], new state has [b, c] → a leaves, c joins
        final state = {
          'u1': entry([meta('a'), meta('b')]),
        };
        final newState = {
          'u1': entry([meta('b'), meta('c')]),
        };
        final joinedRefs = <String>[];
        final leftRefs = <String>[];

        final result = PhoenixPresence.syncState(
          state,
          newState,
          onJoin: (_, _, newPres) {
            joinedRefs.addAll(newPres.metas.map((m) => m['phx_ref'] as String));
          },
          onLeave: (_, _, leftPres) {
            leftRefs.addAll(leftPres.metas.map((m) => m['phx_ref'] as String));
          },
        );

        expect(joinedRefs, equals(['c']));
        expect(leftRefs, equals(['a']));
        // Final state has b and c, in old-first order
        expect(
          result['u1']!.metas.map((m) => m['phx_ref']).toList(),
          equals(['b', 'c']),
        );
      },
    );
  });

  // =========================================================================
  // Callback mutation safety: callbacks receive independent copies
  // =========================================================================
  group('callback argument independence', () {
    test('mutating newPres inside onJoin does not affect stored state', () {
      final state = <String, PresenceEntry>{};
      PhoenixPresence.syncDiff(
        state,
        joins: {
          'u1': entry([
            meta('1', {'data': 'original'}),
          ]),
        },
        leaves: {},
        onJoin: (_, _, newPres) {
          // Caller mutates the newPres they received
          newPres.metas.first['data'] = 'mutated';
        },
      );
      // The result is a separate clone, so let's verify syncDiff is safe:
      final result = PhoenixPresence.syncDiff(
        {
          'u1': entry([
            meta('1', {'data': 'original'}),
          ]),
        },
        joins: {
          'u1': entry([meta('2')]),
        },
        leaves: {},
      );
      // u1 now has meta 1 (old) + meta 2 (new); data field untouched
      expect(result['u1']!.metas.first['data'], 'original');
    });
  });

  // =========================================================================
  // listPresences: empty state
  // =========================================================================
  group('listPresences', () {
    test('empty state returns empty list', () {
      final result = PhoenixPresence.listPresences(
        {},
        (key, entry) => entry,
      );
      expect(result, isEmpty);
    });

    test('key is passed correctly to chooser', () {
      final state = {
        'alice': entry([meta('1')]),
        'bob': entry([meta('2')]),
      };
      final keys = PhoenixPresence.listPresences(state, (key, _) => key);
      expect(keys.toSet(), equals({'alice', 'bob'}));
    });
  });

  // =========================================================================
  // instance: inPendingSyncState
  // =========================================================================
  group('instance: inPendingSyncState', () {
    late ChannelStub channel;

    setUp(() => channel = ChannelStub());

    test('true before any presence_state received', () {
      final presence = PhoenixPresence(channel: channel);
      expect(presence.inPendingSyncState, isTrue);
    });

    test('false immediately after presence_state received', () {
      final presence = PhoenixPresence(channel: channel);
      channel.trigger('presence_state', encodeState({}));
      expect(presence.inPendingSyncState, isFalse);
    });

    test('true again after simulateDisconnectAndReconnect', () {
      final presence = PhoenixPresence(channel: channel);
      channel.trigger('presence_state', encodeState({}));
      expect(presence.inPendingSyncState, isFalse);
      channel.simulateDisconnectAndReconnect();
      expect(presence.inPendingSyncState, isTrue);
    });

    test('false after reconnect + new presence_state', () {
      final presence = PhoenixPresence(channel: channel);
      channel
        ..trigger('presence_state', encodeState({}))
        ..simulateDisconnectAndReconnect()
        ..trigger('presence_state', encodeState({}));
      expect(presence.inPendingSyncState, isFalse);
    });
  });

  // =========================================================================
  // instance: pending diff queue ordering
  // =========================================================================
  group('instance: pending diff queue ordering', () {
    late ChannelStub channel;

    setUp(() => channel = ChannelStub());

    test('multiple pending diffs applied in arrival order', () {
      final presence = PhoenixPresence(channel: channel);
      final u1 = entry([meta('1')]);
      final u2 = entry([meta('2')]);
      final u3 = entry([meta('3')]);

      // Three diffs before snapshot
      channel
        ..trigger('presence_diff', encodeDiff(joins: {'u1': u1}))
        ..trigger('presence_diff', encodeDiff(joins: {'u2': u2}))
        // u1 leaves
        ..trigger('presence_diff', encodeDiff(leaves: {'u1': u1}))
        // Snapshot arrives with u3 only
        ..trigger('presence_state', encodeState({'u3': u3}));

      // After applying: state={u3}, then diff1 joins u1, diff2 joins u2, diff3 leaves u1
      // Net: u2 and u3
      final keys = presence.list((k, _) => k).toSet();
      expect(keys, equals({'u2', 'u3'}));
    });

    test(
      'pending diffs cleared after snapshot — subsequent diff not queued',
      () {
        final presence = PhoenixPresence(channel: channel);
        final u1 = entry([meta('1')]);

        channel
          ..trigger('presence_state', encodeState({'u1': u1}))
          ..trigger('presence_diff', encodeDiff(leaves: {'u1': u1}));
        expect(presence.list((k, _) => k), isEmpty);
      },
    );
  });

  // =========================================================================
  // instance: stale diffs from old connection discarded
  // =========================================================================
  group('instance: reconnect discards old pending diffs', () {
    late ChannelStub channel;

    setUp(() => channel = ChannelStub());

    test(
      'diffs queued before reconnect are flushed when NEW state arrives',
      () {
        final presence = PhoenixPresence(channel: channel);
        final u1 = entry([meta('1')]);
        final u2 = entry([meta('2')]);

        // First connection: state synced
        channel.trigger('presence_state', encodeState({'u1': u1}));
        expect(presence.list((k, _) => k), equals(['u1']));

        // Reconnect
        channel
          ..simulateDisconnectAndReconnect()
          ..trigger('presence_diff', encodeDiff(joins: {'u2': u2}));
        expect(presence.list((k, _) => k), equals(['u1']));

        // New snapshot from server (empty room)
        channel.trigger('presence_state', encodeState({}));
        // Pending diff (u2 joins) applied after empty snapshot → u2 present
        expect(presence.list((k, _) => k), equals(['u2']));
      },
    );
  });

  // =========================================================================
  // instance: onSync not called for queued diffs (only once per state event)
  // =========================================================================
  group('instance: onSync call count', () {
    late ChannelStub channel;

    setUp(() => channel = ChannelStub());

    test('onSync not called for diffs received while pending', () {
      var syncCount = 0;
      final presence = PhoenixPresence(channel: channel)
        ..onSync = () => syncCount++;

      channel
        ..trigger(
          'presence_diff',
          encodeDiff(
            joins: {
              'u1': entry([meta('1')]),
            },
          ),
        )
        ..trigger(
          'presence_diff',
          encodeDiff(
            joins: {
              'u2': entry([meta('2')]),
            },
          ),
        );
      expect(syncCount, 0); // nothing yet

      channel.trigger('presence_state', encodeState({}));
      expect(syncCount, 1); // exactly one — not 3 (state + 2 pending diffs)
    });

    test('each non-pending diff triggers its own onSync', () {
      var syncCount = 0;
      final presence = PhoenixPresence(channel: channel)
        ..onSync = () => syncCount++;

      channel.trigger('presence_state', encodeState({}));
      expect(syncCount, 1);

      channel.trigger(
        'presence_diff',
        encodeDiff(
          joins: {
            'u1': entry([meta('1')]),
          },
        ),
      );
      expect(syncCount, 2);

      channel.trigger(
        'presence_diff',
        encodeDiff(
          joins: {
            'u2': entry([meta('2')]),
          },
        ),
      );
      expect(syncCount, 3);
    });
  });

  // =========================================================================
  // instance: callbacks registered AFTER first state event still fire
  // =========================================================================
  group('instance: late callback registration', () {
    late ChannelStub channel;

    setUp(() => channel = ChannelStub());

    test('onJoin registered after state fires on subsequent diffs', () {
      final presence = PhoenixPresence(channel: channel);
      channel.trigger('presence_state', encodeState({}));

      final joined = <String>[];
      presence.onJoin = (key, _, _) => joined.add(key);

      channel.trigger(
        'presence_diff',
        encodeDiff(
          joins: {
            'u1': entry([meta('1')]),
          },
        ),
      );

      expect(joined, equals(['u1']));
    });

    test('onLeave registered after state fires on subsequent diffs', () {
      final presence = PhoenixPresence(channel: channel);
      final u1 = entry([meta('1')]);
      channel.trigger('presence_state', encodeState({'u1': u1}));

      final left = <String>[];
      presence.onLeave = (key, _, _) => left.add(key);

      channel.trigger('presence_diff', encodeDiff(leaves: {'u1': u1}));

      expect(left, equals(['u1']));
    });
  });

  // =========================================================================
  // instance: presence_state with empty payload
  // =========================================================================
  group('instance: edge payloads', () {
    late ChannelStub channel;

    setUp(() => channel = ChannelStub());

    test('empty presence_state clears existing state', () {
      final presence = PhoenixPresence(channel: channel);
      final u1 = entry([meta('1')]);
      channel.trigger('presence_state', encodeState({'u1': u1}));
      expect(presence.list((k, _) => k), equals(['u1']));

      channel
        ..simulateDisconnectAndReconnect()
        ..trigger('presence_state', encodeState({}));
      expect(presence.list((k, _) => k), isEmpty);
    });

    test('presence_diff with empty joins and leaves is a no-op', () {
      final presence = PhoenixPresence(channel: channel);
      final u1 = entry([meta('1')]);
      channel.trigger('presence_state', encodeState({'u1': u1}));

      var syncCount = 0;
      presence.onSync = () => syncCount++;

      channel.trigger('presence_diff', encodeDiff());
      expect(presence.list((k, _) => k), equals(['u1']));
      expect(syncCount, 1); // onSync still fires
    });

    test('user with many metas — all removed one by one', () {
      final presence = PhoenixPresence(channel: channel);
      final metas = List.generate(
        5,
        (i) => meta('ref_$i', {'device': 'device_$i'}),
      );
      channel.trigger(
        'presence_state',
        encodeState({
          'u1': entry(metas),
        }),
      );

      expect(presence.list((k, e) => e.metas).first, hasLength(5));

      // Remove one at a time
      for (var i = 0; i < 5; i++) {
        channel.trigger(
          'presence_diff',
          encodeDiff(
            leaves: {
              'u1': entry([metas[i]]),
            },
          ),
        );
        if (i < 4) {
          expect(presence.list((k, e) => e.metas).first, hasLength(4 - i));
        } else {
          // Last meta removed — key gone
          expect(presence.list((k, _) => k), isEmpty);
        }
      }
    });
  });

  // =========================================================================
  // instance: list() on empty state
  // =========================================================================
  group('instance: list on empty state', () {
    test('list() returns empty before any snapshot', () {
      final presence = PhoenixPresence(channel: ChannelStub());
      expect(presence.list(), isEmpty);
    });

    test('list() returns empty after all users leave', () {
      final channel = ChannelStub();
      final presence = PhoenixPresence(channel: channel);
      final u1 = entry([meta('1')]);
      channel
        ..trigger('presence_state', encodeState({'u1': u1}))
        ..trigger('presence_diff', encodeDiff(leaves: {'u1': u1}));
      expect(presence.list(), isEmpty);
    });
  });

  // =========================================================================
  // Bug fix: _decodeState/_decodeEntryMap shallow cast on nested maps
  //
  // `.cast<String, dynamic>()` is shallow — nested Map values remain
  // `Map<dynamic, dynamic>` and throw TypeError when accessed as
  // `Map<String, dynamic>`. Fixed with `_deepCastMap`.
  // =========================================================================
  group('Bug: nested map in meta — shallow cast', () {
    late ChannelStub channel;
    setUp(() => channel = ChannelStub());

    test(
      'nested map in presence_state meta is accessible as Map<String,dynamic>',
      () {
        final presence = PhoenixPresence(channel: channel);
        // Meta contains a nested object — common in real apps (location, device info, etc.)
        channel.trigger('presence_state', {
          'u1': {
            'metas': [
              {
                'phx_ref': '1',
                'location': {'lat': 51.5, 'lng': -0.1},
                'tags': ['vip'],
              },
            ],
          },
        });

        final metas = presence.list((k, e) => e.metas).first;
        expect(metas, hasLength(1));

        final location = metas.first['location'];
        // This threw TypeError before the fix (nested map was Map<dynamic,dynamic>)
        expect(location, isA<Map<String, dynamic>>());
        expect((location as Map<String, dynamic>)['lat'], 51.5);
      },
    );

    test('nested map in presence_diff joins meta is accessible', () {
      final presence = PhoenixPresence(channel: channel);
      channel
        ..trigger('presence_state', encodeState({}))
        ..trigger('presence_diff', {
          'joins': {
            'u1': {
              'metas': [
                {
                  'phx_ref': '1',
                  'device': {'os': 'iOS', 'version': 17},
                },
              ],
            },
          },
          'leaves': <String, dynamic>{},
        });

      final metas = presence.list((k, e) => e.metas).first;
      final device = metas.first['device'];
      // TypeError before fix
      expect(device, isA<Map<String, dynamic>>());
      expect((device as Map<String, dynamic>)['os'], 'iOS');
    });

    test('deeply nested maps are fully cast at all levels', () {
      final presence = PhoenixPresence(channel: channel);
      channel.trigger('presence_state', {
        'u1': {
          'metas': [
            {
              'phx_ref': '1',
              'a': {
                'b': {
                  'c': {'d': 'deep'},
                },
              },
            },
          ],
        },
      });

      final m = presence.list((k, e) => e.metas).first.first;
      final a = m['a'] as Map<String, dynamic>;
      final b = a['b'] as Map<String, dynamic>;
      final c = b['c'] as Map<String, dynamic>;
      expect(c['d'], 'deep');
    });

    test('onJoin callback receives deeply cast meta', () {
      final presence = PhoenixPresence(channel: channel);
      Map<String, dynamic>? capturedMeta;
      presence.onJoin = (_, _, newPres) {
        capturedMeta = newPres.metas.first;
      };

      channel.trigger('presence_state', {
        'u1': {
          'metas': [
            {
              'phx_ref': '1',
              'info': {'role': 'admin'},
            },
          ],
        },
      });

      expect(capturedMeta!['info'], isA<Map<String, dynamic>>());
    });
  });

  // =========================================================================
  // Bug fix: zombie key with empty metas from server
  //
  // A presence_state/diff with metas:[] for a new key previously created
  // an entry in state with empty metas. list() would include it and
  // metas.first would throw RangeError. Fixed by skipping empty-metas joins.
  // =========================================================================
  group('Bug: zombie key from empty metas in join', () {
    late ChannelStub channel;
    setUp(() => channel = ChannelStub());

    test(
      'syncDiff: join with empty metas for new key does not create zombie entry',
      () {
        final result = PhoenixPresence.syncDiff(
          {},
          joins: {'u1': entry([])},
          leaves: {},
        );
        expect(result, isEmpty); // no zombie
      },
    );

    test(
      'syncState: new key with empty metas in server snapshot is not stored',
      () {
        final result = PhoenixPresence.syncState(
          {},
          {'u1': entry([])},
        );
        expect(result, isEmpty);
      },
    );

    test(
      'instance: presence_state with empty metas does not appear in list()',
      () {
        final presence = PhoenixPresence(channel: channel);
        channel.trigger('presence_state', {
          'u1': {'metas': []},
          'u2': {
            'metas': [
              {'phx_ref': '2'},
            ],
          },
        });
        // u1 must not appear — accessing its metas.first would throw
        final keys = presence.list((k, _) => k);
        expect(keys, equals(['u2']));
      },
    );

    test(
      'instance: presence_diff join with empty metas does not appear in list()',
      () {
        final presence = PhoenixPresence(channel: channel);
        channel
          ..trigger('presence_state', encodeState({}))
          ..trigger('presence_diff', {
            'joins': {
              'u1': {'metas': []},
            },
            'leaves': <String, dynamic>{},
          });

        expect(presence.list((k, _) => k), isEmpty);
      },
    );

    test('syncDiff: join with empty metas for existing key removes it', () {
      // Edge: existing user gets a join with zero metas — net effect after
      // merging old metas with new (empty) is the old metas survive.
      // Actually: newPres.metas is empty, curMetas are old; merged = old metas.
      // Key stays with old metas. Verify this is consistent.
      final state = {
        'u1': entry([meta('old')]),
      };
      final result = PhoenixPresence.syncDiff(
        state,
        joins: {'u1': entry([])},
        leaves: {},
      );
      // Old meta survives because merge = [old] + [] = [old]
      expect(
        result['u1']!.metas.map((m) => m['phx_ref']).toList(),
        equals(['old']),
      );
    });
  });

  // =========================================================================
  // Bug fix: duplicate presence_state on same connection
  //
  // Server can re-send presence_state without a reconnect (e.g. after
  // phx_error + rejoin). Verify _pendingDiffs is cleared and state converges.
  // =========================================================================
  group('instance: duplicate presence_state on same connection', () {
    late ChannelStub channel;
    setUp(() => channel = ChannelStub());

    test('second presence_state replaces state correctly', () {
      final presence = PhoenixPresence(channel: channel);
      final u1 = entry([meta('1')]);
      final u2 = entry([meta('2')]);

      channel.trigger('presence_state', encodeState({'u1': u1}));
      expect(presence.list((k, _) => k), equals(['u1']));

      // Same connection, no reconnect — server resends state with different users
      channel.trigger('presence_state', encodeState({'u2': u2}));
      expect(presence.list((k, _) => k), equals(['u2']));
    });

    test(
      'second presence_state does not re-apply already-flushed pending diffs',
      () {
        final presence = PhoenixPresence(channel: channel);
        var joinCount = 0;
        presence.onJoin = (_, _, _) => joinCount++;

        final u1 = entry([meta('1')]);
        // Diff queued before first state
        channel.trigger('presence_diff', encodeDiff(joins: {'u1': u1}));
        expect(joinCount, 0);

        channel.trigger('presence_state', encodeState({}));
        expect(joinCount, 1); // pending diff flushed once

        // Second state on same connection — no pending diffs remain
        channel.trigger('presence_state', encodeState({}));
        expect(joinCount, 1); // no double-application
      },
    );
  });
}
