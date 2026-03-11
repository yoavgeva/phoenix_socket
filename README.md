# phoenix_socket

A lightweight [Phoenix Channel V2](https://hexdocs.pm/phoenix/channels.html) client for Dart.

- No rxdart dependency — pure Dart Streams
- Works in Flutter and plain Dart (no Flutter SDK required)
- Automatic reconnection with exponential backoff (1, 2, 4, 8, 16, 30 s)
- 30-second heartbeat with pending-detection (reconnects if server goes silent)
- Push buffering during join — pushes sent before join completes are held and flushed automatically
- Stale message filtering — replies for old join cycles are dropped

## Installation

```yaml
dependencies:
  phoenix_socket: ^0.1.0
```

## Quick start

```dart
import 'package:phoenix_socket/phoenix_socket.dart';

final socket = PhoenixSocket(
  'ws://localhost:4000/socket/websocket',
  params: {'token': 'my-user-token'},
);

await socket.connect();

final channel = socket.channel('room:lobby');
await channel.join();

channel.messages.listen((msg) {
  print('${msg.event}: ${msg.payload}');
});

await channel.push('new_msg', {'body': 'hello'});

await channel.leave();
await socket.disconnect();
```

---

## API reference

### PhoenixSocket

```dart
PhoenixSocket(
  String url, {
  Map<String, String> params = const {},
})
```

| Member | Description |
|---|---|
| `connect()` | Opens the WebSocket. Idempotent — safe to call if already connected. |
| `disconnect()` | Closes the WebSocket. Does **not** attempt to reconnect. |
| `channel(String topic)` | Returns (or creates) a `PhoenixChannel` for `topic`. Cached — same instance returned on repeated calls. |
| `state` | Current `PhoenixSocketState`. |
| `states` | `Stream<PhoenixSocketState>` — emits every state change. |

**`PhoenixSocketState` values:** `connecting`, `connected`, `disconnected`, `reconnecting`

The `vsn=2.0.0` query parameter is always appended to the URL automatically. Any extra `params` you pass are included alongside it.

#### Listening to connection state

```dart
socket.states.listen((state) {
  switch (state) {
    case PhoenixSocketState.connected:
      print('connected');
    case PhoenixSocketState.reconnecting:
      print('reconnecting…');
    case PhoenixSocketState.disconnected:
      print('disconnected');
    default:
      break;
  }
});
```

---

### PhoenixChannel

Obtain via `socket.channel(topic)` — do not construct directly.

| Member | Description |
|---|---|
| `join({Map payload})` | Sends `phx_join`. Returns the server's response payload. Throws `StateError` if called twice on the same instance. |
| `leave()` | Sends `phx_leave` and waits for the server reply (5 s timeout, best-effort). |
| `push(String event, Map payload)` | Sends an event. Returns the server's reply payload. Throws `PhoenixException` on a non-ok reply. Throws `TimeoutException` after 10 s with no reply. |
| `messages` | `Stream<PhoenixMessage>` — app events only (control frames are filtered). |
| `state` | Current `PhoenixChannelState`. |

**`PhoenixChannelState` values:** `closed`, `joining`, `joined`, `leaving`, `errored`

#### Handling errors from join / push

```dart
try {
  await channel.join();
} on PhoenixException catch (e) {
  // Server replied with status != "ok"
  print('join refused: ${e.message}, response: ${e.response}');
} on TimeoutException {
  print('join timed out');
}

try {
  final reply = await channel.push('new_msg', {'body': 'hi'});
  print('server replied: $reply');
} on PhoenixException catch (e) {
  print('push error: ${e.message}');
} on TimeoutException {
  print('push timed out');
} on StateError catch (e) {
  // join() was never called, or channel is closed / disconnected
  print('bad state: $e');
}
```

#### Receiving server broadcasts

`channel.messages` is a broadcast stream — you can have multiple listeners.
Control events (`phx_reply`, `phx_join`, `phx_leave`, `phx_close`, `phx_error`) are
filtered out automatically; only application events are delivered.

```dart
channel.messages.listen((PhoenixMessage msg) {
  print('topic=${msg.topic} event=${msg.event} payload=${msg.payload}');
});
```

---

### PhoenixMessage

```dart
class PhoenixMessage {
  final String? joinRef;   // null for server broadcasts
  final String? ref;       // null for server pushes without expecting a reply
  final String  topic;
  final String  event;
  final Map<String, dynamic> payload;
}
```

---

### PhoenixException

```dart
class PhoenixException implements Exception {
  final String message;
  final Map<String, dynamic>? response; // server's response body, if any
}
```

Thrown when the server replies with a status other than `"ok"` (e.g. `"error"` or `"forbidden"`).

---

## Error handling

### Exception types

| Exception | When thrown | `response` field |
|---|---|---|
| `PhoenixException` | Server replied `status != "ok"` to a join or push | Server's response body |
| `PhoenixException` | Socket dropped while a push was in-flight | `null` |
| `PhoenixException` | `leave()` called while join was still pending | `null` |
| `TimeoutException` | No join reply within 10 s | — |
| `TimeoutException` | No push reply within 10 s | — |
| `StateError` | `join()` called twice on the same instance | — |
| `StateError` | `push()` called before `join()` | — |
| `StateError` | `push()` on a `closed` or `leaving` channel | — |

### join()

```dart
try {
  final response = await channel.join({'token': token});
  // response is the payload from the server's ok reply
  print('joined: $response');
} on PhoenixException catch (e) {
  // Server refused — e.g. invalid token, room full, access denied
  // e.response contains the server's error body
  print('join refused: ${e.message}');
  print('server said: ${e.response}');
} on TimeoutException {
  // Server never replied within 10 s.
  // Channel state is now `errored`. The socket will auto-rejoin after reconnect.
  print('join timed out');
} on StateError catch (e) {
  // join() called twice — create a new channel instance instead
  print(e);
}
```

### push()

```dart
try {
  final reply = await channel.push('new_msg', {'body': 'hello'});
  print('server ack: $reply');
} on PhoenixException catch (e) {
  // Server replied with an error status.
  // e.response contains the server's error body.
  print('push rejected: ${e.message}');
  print('server said: ${e.response}');
} on TimeoutException {
  // No reply from server within 10 s.
  // The push ref is cleaned up — no stale callbacks remain.
  print('push timed out');
} on StateError catch (e) {
  // One of:
  //   - push() before join() was ever called
  //   - push() on a closed channel (after leave() or intentional disconnect)
  //   - push() on a leaving channel
  print(e);
}
```

> **Note:** A `PhoenixException` with `"Socket disconnected"` means the socket
> dropped while your push was waiting for a reply. The server may or may not
> have received the message. Treat it the same as a network error — retry if
> your operation is idempotent.

### Fire-and-forget pushes

If you don't care about the reply, suppress errors explicitly so they don't
become unhandled Future errors:

```dart
channel.push('typing', {}).ignore();
// or
channel.push('typing', {}).catchError((_) {});
```

### Handling socket drops while waiting for a reply

In-flight pushes are **not** retried automatically. If the socket drops, their
completers are error-completed with `PhoenixException('Socket disconnected')`.
You decide whether to retry after the channel rejoins:

```dart
Future<void> sendWithRetry(PhoenixChannel channel, String event, Map payload) async {
  while (true) {
    try {
      await channel.push(event, payload);
      return;
    } on PhoenixException catch (e) {
      if (e.message == 'Socket disconnected') {
        // Wait for channel to rejoin before retrying
        await channel.states // if you added a states stream; or just delay:
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }
      rethrow; // server error — don't retry
    } on TimeoutException {
      rethrow; // let the caller decide
    }
  }
}
```

### Push buffering vs. push failure

Understanding when a push is buffered vs. when it throws immediately:

| Channel state when `push()` is called | Behaviour |
|---|---|
| `joining` | Buffered. Sent after join succeeds. Errors if join fails. |
| `errored` | Buffered. Sent after auto-rejoin succeeds. Errors if rejoin fails. |
| `joined` | Sent immediately. |
| `closed` | Throws `StateError` immediately. |
| `leaving` | Throws `StateError` immediately. |
| Before `join()` called | Throws `StateError` immediately. |

`errored` state only occurs after an **unintentional** disconnect. After an
intentional `socket.disconnect()`, channels move to `closed`, so all pending
and buffered pushes fail with `PhoenixException` right away.

### leave() before join completes

If `leave()` is called while the channel is still joining, the pending join
future rejects with `PhoenixException('Channel left before join completed')`.
Handle it the same way as a join refusal:

```dart
final joinFuture = channel.join();
// ... later, user navigates away:
await channel.leave();
try {
  await joinFuture;
} on PhoenixException {
  // expected — leave() cancelled the join
}
```

---

## Behaviour guide

### Push buffering

Pushes sent while the channel is in `joining` state are buffered and sent automatically once the join succeeds:

```dart
final channel = socket.channel('room:lobby');
channel.join(); // fire-and-forget — don't await
channel.push('event', {'data': 1}); // buffered, sent after join ok
```

If the join fails (error reply, timeout, or socket drop), all buffered pushes are error-completed immediately.

### Automatic reconnection

When the connection drops unexpectedly, the socket reconnects with backoff delays of 1, 2, 4, 8, 16, then 30 seconds (capped). After reconnecting, all channels in `errored` or `joining` state are automatically rejoined.

Calling `disconnect()` explicitly prevents reconnection. To reconnect after an intentional disconnect, call `connect()` again.

### Channel lifecycle after disconnect

| Disconnect type | Channel state after drop | Auto-rejoin on reconnect? |
|---|---|---|
| Unintentional (network drop) | `errored` | Yes |
| Intentional (`socket.disconnect()`) | `closed` | No |
| Server sent `phx_close` | `closed` | No |

After an intentional disconnect, `channel.push()` throws `StateError` immediately. Call `socket.channel(topic)` to get a fresh instance, then `connect()` and `join()` again.

### One join per instance

Each `PhoenixChannel` instance can only be joined once. Calling `join()` a second time throws `StateError`. This mirrors the Phoenix JS client contract.

To rejoin after a `leave()`, get a new instance:

```dart
await channel.leave();
// channel is now closed and cannot be reused
final channel2 = socket.channel('room:lobby'); // new instance
await channel2.join();
```

### Heartbeat

A heartbeat is sent every 30 seconds. If no reply is received before the next tick, the socket treats the connection as dead and reconnects.

---

## Flutter example

A runnable Flutter chat app is in [`example/`](example/lib/main.dart).
The patterns below are what that example is built on.

### Recommended structure

```
lib/
  services/
    phoenix_socket_manager.dart   ← one singleton, lives in the Provider tree
  features/
    chat/
      chat_room_notifier.dart     ← one ChangeNotifier per channel
      chat_screen.dart
```

### 1. PhoenixSocketManager — one socket for the whole app

Wrap it in a `ChangeNotifier` and expose connection state to the UI:

```dart
class PhoenixSocketManager extends ChangeNotifier {
  PhoenixSocket? _socket;
  StreamSubscription<PhoenixSocketState>? _stateSub;
  PhoenixSocketState _socketState = PhoenixSocketState.disconnected;

  bool get isConnected => _socketState == PhoenixSocketState.connected;
  PhoenixSocketState get socketState => _socketState;

  Future<void> connect({required String url, String? token}) async {
    if (_socket != null) return;
    _socket = PhoenixSocket(url, params: token != null ? {'token': token} : {});
    _stateSub = _socket!.states.listen((s) {
      _socketState = s;
      notifyListeners();
    });
    await _socket!.connect();
  }

  Future<void> disconnect() async {
    await _stateSub?.cancel();
    _stateSub = null;
    await _socket?.disconnect();
    _socket = null;
    _socketState = PhoenixSocketState.disconnected;
    notifyListeners();
  }

  PhoenixChannel channel(String topic) => _socket!.channel(topic);
}
```

Register it above `MaterialApp`:

```dart
ChangeNotifierProvider(
  create: (_) => PhoenixSocketManager(),
  child: const MyApp(),
)
```

Connect after login, disconnect after logout:

```dart
// login
await context.read<PhoenixSocketManager>().connect(
  url: 'ws://example.com/socket/websocket',
  token: accessToken,
);

// logout
await context.read<PhoenixSocketManager>().disconnect();
```

### 2. Per-screen ChangeNotifier — one per channel

Each screen that uses a channel gets its own `ChangeNotifier`. It joins on
construction and leaves on `dispose()`.

```dart
class ChatRoomNotifier extends ChangeNotifier {
  final PhoenixSocketManager manager;
  final String topic;

  late final PhoenixChannel _channel;
  StreamSubscription<PhoenixMessage>? _msgSub;

  final List<String> messages = [];
  String? error;
  bool joined = false;

  ChatRoomNotifier({required this.manager, required this.topic}) {
    _join();
  }

  Future<void> _join() async {
    _channel = manager.channel(topic);

    // Subscribe BEFORE join so no messages are missed.
    _msgSub = _channel.messages.listen((msg) {
      if (msg.event == 'new_msg') {
        messages.add(msg.payload['body'] as String);
        notifyListeners();
      }
    });

    try {
      await _channel.join();
      joined = true;
    } on PhoenixException catch (e) {
      error = 'Join refused: ${e.message}';
    } on TimeoutException {
      error = 'Join timed out — will retry on reconnect';
    }
    notifyListeners();
  }

  Future<bool> send(String body) async {
    try {
      await _channel.push('new_msg', {'body': body});
      return true;
    } on PhoenixException catch (e) {
      error = 'Rejected: ${e.message}';
      notifyListeners();
      return false;
    } on TimeoutException {
      error = 'Timed out';
      notifyListeners();
      return false;
    } on StateError catch (e) {
      error = e.message;
      notifyListeners();
      return false;
    }
  }

  // Fire-and-forget — typing indicator, read receipts, etc.
  void sendTyping() => _channel.push('typing', {}).ignore();

  @override
  void dispose() {
    _msgSub?.cancel();
    _channel.leave().ignore(); // best-effort; never await in dispose
    super.dispose();
  }
}
```

Provide it scoped to the route so it's disposed when the user navigates away:

```dart
Navigator.of(context).push(MaterialPageRoute(
  builder: (_) => ChangeNotifierProvider(
    create: (_) => ChatRoomNotifier(manager: manager, topic: 'room:lobby'),
    child: const ChatScreen(),
  ),
));
```

### 3. Show connection state in the UI

```dart
// In a widget build() method:
final socket = context.watch<PhoenixSocketManager>();

Widget badge = switch (socket.socketState) {
  PhoenixSocketState.connected    => const Icon(Icons.wifi,        color: Colors.green),
  PhoenixSocketState.reconnecting => const Icon(Icons.wifi_off,    color: Colors.orange),
  PhoenixSocketState.connecting   => const CircularProgressIndicator(),
  PhoenixSocketState.disconnected => const Icon(Icons.signal_wifi_bad, color: Colors.red),
};
```

### 4. Multiple providers sharing one socket

Different parts of the app join different channels, all through the same socket.
Each provider owns exactly one channel and disposes it when the screen pops.

```dart
// Root — lives for the whole session
MultiProvider(
  providers: [
    ChangeNotifierProvider(create: (_) => PhoenixSocketManager()),

    // Notifications: joins "notifications:{uid}", stays alive globally
    ChangeNotifierProxyProvider<PhoenixSocketManager, NotificationsProvider>(
      create: (ctx) => NotificationsProvider(
        ctx.read<PhoenixSocketManager>(), currentUserId),
      update: (_, __, prev) => prev!,
    ),
  ],
  child: const MyApp(),
)

// Room screen — scoped, disposed when user pops the route
MultiProvider(
  providers: [
    // Both join "room:{id}" — socket.channel() returns the same cached
    // PhoenixChannel instance, so only ONE join is sent to the server.
    ChangeNotifierProxyProvider<PhoenixSocketManager, PresenceProvider>(
      create: (ctx) => PresenceProvider(ctx.read<PhoenixSocketManager>(), roomId),
      update: (_, __, prev) => prev!,
    ),
    ChangeNotifierProxyProvider<PhoenixSocketManager, ChatProvider>(
      create: (ctx) => ChatProvider(ctx.read<PhoenixSocketManager>(), roomId),
      update: (_, __, prev) => prev!,
    ),
  ],
  child: const ChatScreen(),
)
```

**Channels that are shared between providers** (like `room:{id}` above): only
one provider should call `leave()` in its `dispose()`. The others should just
cancel their stream subscription. A simple rule: the provider that joined first
is responsible for leaving.

Typical channel-to-provider mapping in a real app:

| Channel topic | Provider | Scope |
|---|---|---|
| `notifications:{uid}` | `NotificationsProvider` | App root |
| `feed:{uid}` | `FeedProvider` | Feed screen |
| `room:{id}` | `PresenceProvider` + `ChatProvider` | Room screen |
| `user:{uid}` | `UserStatusProvider` | App root |

See [`example/lib/multi_provider_example.dart`](example/lib/multi_provider_example.dart)
for full implementations of `NotificationsProvider`, `PresenceProvider`,
`ChatProvider`, and `FeedProvider`.

### 5. Key rules

- **Subscribe to `channel.messages` before `join()`** — the server may send a
  push in the same moment the join reply arrives.
- **Never `await` in `dispose()`** — call `leave().ignore()` and
  `subscription.cancel()` without awaiting.
- **One socket, many channels** — `socket.channel(topic)` returns the same
  instance for the same topic. Keep the socket alive in the Provider tree; only
  the per-screen notifiers come and go.
- **`push().ignore()` for fire-and-forget** — typing indicators, analytics,
  read receipts. Swallows errors silently.
- **`push()` buffers while `joining`** — you can call `push()` immediately
  after `join()` without awaiting the join. Pushes are held and sent once the
  server acks the join.

---

## Testing

The socket accepts a `channelFactory` parameter for injecting a fake WebSocket in tests:

```dart
final socket = PhoenixSocket(
  'ws://localhost:4000/socket/websocket',
  channelFactory: (uri) => FakeWebSocketChannel(),
);
```

See the `test/` directory for examples using `fake_async` and `stream_channel`.
