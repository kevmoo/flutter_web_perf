import 'dart:io';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_static/shelf_static.dart';

class DevServer {
  HttpServer? _server;

  Future<int> start(String path) async {
    final handler = createStaticHandler(path, defaultDocument: 'index.html');

    // Use port 0 to find an available port
    _server = await io.serve(handler, 'localhost', 0);
    print('Serving $path on http://${_server!.address.host}:${_server!.port}');

    return _server!.port;
  }

  Future<void> stop() async {
    await _server?.close();
  }
}
