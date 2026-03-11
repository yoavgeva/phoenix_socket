/// Exception thrown by PhoenixSocket operations.
class PhoenixException implements Exception {
  /// Creates a [PhoenixException] with the given [message] and optional
  /// server [response] payload.
  const PhoenixException(this.message, {this.response});

  /// Human-readable error message.
  final String message;

  /// The raw response payload from the server, if any.
  final Map<String, dynamic>? response;

  @override
  String toString() => 'PhoenixException: $message';
}
