import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

class ChromeController {
  Process? _chromeProcess;
  WipConnection? _connection;

  Future<void> start(String url) async {
    // TODO: Find Chrome executable path portably
    final chromePath =
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'; // Hardcoded for Mac for now

    _chromeProcess = await Process.start(chromePath, [
      '--remote-debugging-port=9222',
      '--headless', // Remove if we want to see it
      '--disable-gpu',
      url,
    ]);

    // Wait for Chrome to start and open the port with retries
    http.Response? response;
    for (var i = 0; i < 10; i++) {
      try {
        response = await http.get(Uri.parse('http://localhost:9222/json'));
        if (response.statusCode == 200) break;
      } catch (_) {
        // Ignore and retry
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }

    if (response == null || response.statusCode != 200) {
      throw Exception('Failed to connect to Chrome DevTools after retries.');
    }

    final tabs = json.decode(response.body) as List;
    final targetTab = tabs.firstWhere((tab) => tab['type'] == 'page');
    final wsUrl = targetTab['webSocketDebuggerUrl'] as String;

    _connection = await WipConnection.connect(wsUrl);
    print('Connected to Chrome!');
  }

  Future<void> startTracing() async {
    await _connection?.sendCommand('Tracing.start', {
      'categories': 'devtools.timeline,benchmark',
    });
    print('Tracing started.');
  }

  Future<List<Map<String, dynamic>>> stopTracing() async {
    final data = <Map<String, dynamic>>[];

    final subscription = _connection?.onNotification.listen((notification) {
      if (notification.method == 'Tracing.dataCollected') {
        final params = notification.params as Map<String, dynamic>;
        final value = params['value'] as List;
        data.addAll(value.cast<Map<String, dynamic>>());
      }
    });

    await _connection?.sendCommand('Tracing.end');
    print('Tracing stopped, waiting for data...');

    // Wait for tracingComplete event
    final completer = Completer<List<Map<String, dynamic>>>();
    _connection?.onNotification.listen((notification) {
      if (notification.method == 'Tracing.tracingComplete') {
        subscription?.cancel();
        completer.complete(data);
      }
    });

    return completer.future;
  }

  Future<void> stop() async {
    await _connection?.close();
    _chromeProcess?.kill();
  }
}
