import 'dart:convert';

import 'package:phoenix_socket/src/channel.dart';
import 'package:phoenix_socket/src/message.dart';

/// A single presence entry for one key (user/device).
///
/// `metas` is the list of metadata maps, one per connected device/session.
/// Each meta map must contain a `"phx_ref"` string field used to track
/// individual connections.
typedef PresenceEntry = ({List<Map<String, dynamic>> metas});

/// The full presence state: a map from key (e.g. user ID) to [PresenceEntry].
typedef PresenceState = Map<String, PresenceEntry>;

/// Callback fired when a key joins or gets new metas.
///
/// [key] — the presence key (e.g. user ID).
/// [current] — the existing entry before the change, or `null` if brand new.
/// [newPres] — the entry containing only the newly joined metas.
typedef OnJoin = void Function(
  String key,
  PresenceEntry? current,
  PresenceEntry newPres,
);

/// Callback fired when a key loses metas or leaves entirely.
///
/// [key] — the presence key.
/// [current] — the entry *after* removal (may have 0 metas if fully gone).
/// [leftPres] — the entry containing only the metas that left.
typedef OnLeave = void Function(
  String key,
  PresenceEntry current,
  PresenceEntry leftPres,
);

/// Manages Phoenix Presence state for a channel.
///
/// Tracks who is online by processing `presence_state` (full snapshot) and
/// `presence_diff` (incremental join/leave) events from the server.
///
/// ## Usage
///
/// ```dart
/// final presence = PhoenixPresence(channel: channel);
/// presence.onJoin = (key, current, newPres) { ... };
/// presence.onLeave = (key, current, leftPres) { ... };
/// presence.onSync = () { setState(() {}); };
///
/// // List everyone online
/// final users = presence.list();
///
/// // List with a custom mapper
/// final names = presence.list(
///   (key, entry) => entry.metas.first['name'] as String,
/// );
/// ```
///
/// ## Algorithm
///
/// Mirrors the Phoenix.js Presence client
/// exactly:
/// - `syncState` computes a full diff against the current state and delegates
///   to `syncDiff`.
/// - `syncDiff` merges new metas (prepends surviving old metas) and removes
///   left metas by `phx_ref`.
/// - Diffs that arrive before the first `presence_state` snapshot are queued
///   and applied in order after the snapshot arrives.
/// - On reconnect the queue is reset (join ref changes) so stale diffs from
///   the previous connection are discarded.
class PhoenixPresence {
  /// Creates a [PhoenixPresence] that tracks presence events on [channel].
  PhoenixPresence({required PhoenixChannel channel}) : _channel = channel {
    _channel.messages.listen(_onMessage);
  }

  PresenceState _state = {};
  final List<Map<String, dynamic>> _pendingDiffs = [];

  final PhoenixChannel _channel;
  String? _joinRef;

  /// Called when a key joins or gets a new meta.
  OnJoin? onJoin;

  /// Called when a key loses a meta or leaves entirely.
  OnLeave? onLeave;

  /// Called after every state or diff sync completes.
  void Function()? onSync;

  // ---------------------------------------------------------------------------
  // Public instance API
  // ---------------------------------------------------------------------------

  /// Returns true if the initial `presence_state` snapshot has not yet arrived
  /// for the current connection (or after a reconnect before the new snapshot).
  bool get inPendingSyncState =>
      _joinRef == null || _joinRef != _channel.joinRef;

  /// Returns a list of presence values, optionally mapped through [chooser].
  ///
  /// Default: returns the raw [PresenceEntry] for each key.
  ///
  /// ```dart
  /// // get first meta for each user
  /// final firstMetas = presence.list(
  ///   (key, entry) => entry.metas.first,
  /// );
  /// ```
  List<T> list<T>([T Function(String key, PresenceEntry entry)? chooser]) {
    chooser ??= (key, entry) => entry as T;
    return PhoenixPresence.listPresences(_state, chooser);
  }

  // ---------------------------------------------------------------------------
  // Static core algorithms (mirrors Phoenix.js static methods)
  // ---------------------------------------------------------------------------

  /// Syncs [currentState] against a full [newState] snapshot from the server.
  ///
  /// Computes the minimal join/leave diff and delegates to [syncDiff].
  /// Does NOT mutate [currentState] — returns a new map.
  static PresenceState syncState(
    PresenceState currentState,
    PresenceState newState, {
    OnJoin? onJoin,
    OnLeave? onLeave,
  }) {
    final state = _clone(currentState);
    final joins = <String, PresenceEntry>{};
    final leaves = <String, PresenceEntry>{};

    // Keys present in current but absent in new → full leave
    for (final key in state.keys) {
      if (!newState.containsKey(key)) {
        leaves[key] = state[key]!;
      }
    }

    // Keys in new state → compare metas by phx_ref
    for (final entry in newState.entries) {
      final key = entry.key;
      final newPres = entry.value;
      final currentPres = state[key];

      if (currentPres != null) {
        final newRefs =
            newPres.metas.map((m) => m['phx_ref'] as String).toSet();
        final curRefs =
            currentPres.metas.map((m) => m['phx_ref'] as String).toSet();

        final joinedMetas = newPres.metas
            .where((m) => !curRefs.contains(m['phx_ref']))
            .toList();
        final leftMetas = currentPres.metas
            .where((m) => !newRefs.contains(m['phx_ref']))
            .toList();

        if (joinedMetas.isNotEmpty) {
          joins[key] = (metas: joinedMetas);
        }
        if (leftMetas.isNotEmpty) {
          leaves[key] = (metas: leftMetas);
        }
      } else {
        joins[key] = newPres;
      }
    }

    return syncDiff(
      state,
      joins: joins,
      leaves: leaves,
      onJoin: onJoin,
      onLeave: onLeave,
    );
  }

  /// Applies an incremental diff (joins + leaves) to [state].
  ///
  /// Does NOT mutate [state] — returns a new map.
  static PresenceState syncDiff(
    PresenceState state, {
    required Map<String, PresenceEntry> joins,
    required Map<String, PresenceEntry> leaves,
    OnJoin? onJoin,
    OnLeave? onLeave,
  }) {
    final result = _clone(state);
    final clonedJoins = _cloneEntryMap(joins);
    final clonedLeaves = _cloneEntryMap(leaves);

    // Process joins
    for (final entry in clonedJoins.entries) {
      final key = entry.key;
      final newPres = entry.value;
      final currentPres = result[key];

      // Bug fix: a server-sent entry with no metas would create a zombie key
      // (present in state with empty metas). Skip it so it never appears in
      // list() and never causes metas.first to throw.
      if (newPres.metas.isEmpty && currentPres == null) continue;

      result[key] = newPres;

      if (currentPres != null) {
        // Mirror JS: state[key].metas.unshift(...curMetas)
        // Old surviving metas come FIRST, new joined metas appended after.
        final joinedRefs =
            result[key]!.metas.map((m) => m['phx_ref'] as String).toSet();
        final curMetas = currentPres.metas
            .where((m) => !joinedRefs.contains(m['phx_ref']))
            .toList();
        final merged = [...curMetas, ...result[key]!.metas];
        if (merged.isEmpty) {
          result.remove(key);
          onJoin?.call(key, currentPres, newPres);
          continue;
        }
        result[key] = (metas: merged);
      }
      onJoin?.call(key, currentPres, newPres);
    }

    // Process leaves
    for (final entry in clonedLeaves.entries) {
      final key = entry.key;
      final leftPres = entry.value;
      final currentPres = result[key];
      if (currentPres == null) continue;

      final refsToRemove =
          leftPres.metas.map((m) => m['phx_ref'] as String).toSet();
      final remaining = currentPres.metas
          .where((m) => !refsToRemove.contains(m['phx_ref']))
          .toList();

      result[key] = (metas: remaining);
      onLeave?.call(key, result[key]!, leftPres);

      if (remaining.isEmpty) {
        result.remove(key);
      }
    }

    return result;
  }

  /// Returns a list by mapping each presence entry through [chooser].
  static List<T> listPresences<T>(
    PresenceState presences,
    T Function(String key, PresenceEntry entry) chooser,
  ) {
    return presences.entries.map((e) => chooser(e.key, e.value)).toList();
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _onMessage(PhoenixMessage msg) {
    switch (msg.event) {
      case 'presence_state':
        _joinRef = _channel.joinRef;
        _state = syncState(
          _state,
          _decodeState(msg.payload),
          onJoin: onJoin,
          onLeave: onLeave,
        );
        // Flush diffs that arrived before the snapshot
        for (final diff in _pendingDiffs) {
          _state = syncDiff(
            _state,
            joins: _decodeEntryMap(diff['joins'] as Map? ?? {}),
            leaves: _decodeEntryMap(diff['leaves'] as Map? ?? {}),
            onJoin: onJoin,
            onLeave: onLeave,
          );
        }
        _pendingDiffs.clear();
        onSync?.call();

      case 'presence_diff':
        if (inPendingSyncState) {
          _pendingDiffs.add(Map<String, dynamic>.from(msg.payload));
        } else {
          _state = syncDiff(
            _state,
            joins: _decodeEntryMap(msg.payload['joins'] as Map? ?? {}),
            leaves: _decodeEntryMap(msg.payload['leaves'] as Map? ?? {}),
            onJoin: onJoin,
            onLeave: onLeave,
          );
          onSync?.call();
        }
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static PresenceState _clone(PresenceState state) {
    // Deep-clone via JSON round-trip (same as Phoenix.js)
    final encoded = jsonEncode(
      state.map((k, v) => MapEntry(k, {'metas': v.metas})),
    );
    final decoded = jsonDecode(encoded) as Map<String, dynamic>;
    return decoded.map((k, v) {
      final entry = v as Map<String, dynamic>;
      final metas = (entry['metas'] as List<dynamic>)
          .map((m) => (m as Map<dynamic, dynamic>).cast<String, dynamic>())
          .toList();
      return MapEntry(k, (metas: metas));
    });
  }

  static Map<String, PresenceEntry> _cloneEntryMap(
      Map<String, PresenceEntry> map) {
    return map.map((k, v) {
      final cloned = jsonDecode(jsonEncode(v.metas)) as List;
      return MapEntry(
        k,
        (metas: cloned.map((m) => (m as Map).cast<String, dynamic>()).toList()),
      );
    });
  }

  static PresenceState _decodeState(Map<String, dynamic> raw) {
    return raw.map((key, value) {
      final metas = ((value as Map)['metas'] as List)
          .map((m) => _deepCastMap(m as Map))
          .toList();
      return MapEntry(key, (metas: metas));
    });
  }

  static Map<String, PresenceEntry> _decodeEntryMap(Map<dynamic, dynamic> raw) {
    return raw.map((key, value) {
      final metas = ((value as Map)['metas'] as List)
          .map((m) => _deepCastMap(m as Map))
          .toList();
      return MapEntry(key as String, (metas: metas));
    });
  }

  /// Recursively converts a [Map] of any key/value types to
  /// `Map<String, dynamic>`, ensuring nested maps are also fully typed.
  ///
  /// `Map.cast<String, dynamic>()` is shallow — nested maps remain
  /// `Map<dynamic, dynamic>` and cause `TypeError` when accessed as
  /// `Map<String, dynamic>`. This helper fixes that by recursing into
  /// every value that is itself a `Map`.
  static Map<String, dynamic> _deepCastMap(Map<dynamic, dynamic> raw) {
    return raw.map((k, v) {
      final value = v is Map ? _deepCastMap(v) : v;
      return MapEntry(k as String, value);
    });
  }
}
