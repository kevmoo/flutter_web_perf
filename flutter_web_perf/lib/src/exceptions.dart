final class FlutterWebPerfException implements Exception {
  final String message;

  FlutterWebPerfException(this.message);

  @override
  String toString() => message;
}
