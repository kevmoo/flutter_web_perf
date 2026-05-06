import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_static/shelf_static.dart';

class DevServer {
  HttpServer? _server;

  Future<int> start(String path) async {
    final staticHandler = createStaticHandler(
      path,
      defaultDocument: 'index.html',
    );

    // Inject COOP and COEP headers to enable SharedArrayBuffer for Wasm
    // multi-threaded rendering
    final handler = const Pipeline()
        .addMiddleware(
          (innerHandler) => (request) async {
            final response = await innerHandler(request);
            return response.change(
              headers: {
                ...response.headers,
                'Cross-Origin-Opener-Policy': 'same-origin',
                'Cross-Origin-Embedder-Policy': 'require-corp',
              },
            );
          },
        )
        .addHandler(staticHandler);

    // Use port 0 to find an available port
    _server = await io.serve(handler, 'localhost', 0);
    print('Serving $path on http://${_server!.address.host}:${_server!.port}');

    return _server!.port;
  }

  Future<void> stop() async {
    await _server?.close();
  }
}
