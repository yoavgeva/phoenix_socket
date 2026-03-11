## 0.1.0

- Initial release
- Phoenix Channel V2 protocol support
- Automatic reconnection with exponential backoff [1, 2, 4, 8, 16, 30]s
- Heartbeat with pending detection and reconnect on missed reply
- Push buffering during join phase
- Stale joinRef message filtering
- Injectable WebSocket factory for testing
