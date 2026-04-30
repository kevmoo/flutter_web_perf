import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

class ChromeController {
  Process? _chromeProcess;
  WipConnection? _connection;
  Directory? _tempDir;

  Future<void> start(String url) async {
    // TODO: Find Chrome executable path portably
    final chromePath =
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'; // Hardcoded for Mac for now

    _tempDir = await Directory.systemTemp.createTemp('chrome_profile_');

    _chromeProcess = await Process.start(chromePath, [
      '--remote-debugging-port=0', // Use dynamic port
      '--headless', // Remove if we want to see it
      '--disable-gpu',
      '--user-data-dir=${_tempDir!.path}',
      'about:blank', // Start with blank page
    ]);

    final activePortFile = File(p.join(_tempDir!.path, 'DevToolsActivePort'));

    // Wait for file to exist
    var attempts = 0;
    while (!await activePortFile.exists() && attempts < 20) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      attempts++;
    }

    if (!await activePortFile.exists()) {
      throw Exception('Failed to find DevToolsActivePort file.');
    }

    final lines = await activePortFile.readAsLines();
    if (lines.isEmpty) {
      throw Exception('DevToolsActivePort file is empty.');
    }

    final port = int.parse(lines[0]);
    print('Chrome listening on dynamic port: $port');

    // Wait for Chrome to be ready on the new port with retries
    http.Response? response;
    for (var i = 0; i < 10; i++) {
      try {
        response = await http.get(Uri.parse('http://localhost:$port/json'));
        if (response.statusCode == 200) break;
      } catch (_) {
        // Ignore and retry
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    if (response == null || response.statusCode != 200) {
      throw Exception('Failed to connect to Chrome DevTools after retries.');
    }

    final tabs = (json.decode(response.body) as List)
        .cast<Map<String, dynamic>>();
    final targetTab = tabs.firstWhere((tab) => tab['type'] == 'page');
    final wsUrl = targetTab['webSocketDebuggerUrl'] as String;

    _connection = await WipConnection.connect(wsUrl);
    print('Connected to Chrome!');

    // Enable Debugger domain to see script events
    await _connection?.sendCommand('Debugger.enable');

    _connection?.onNotification.listen((notification) {
      if (notification.method == 'Debugger.scriptParsed') {
        final params = notification.params as Map<String, dynamic>;
        final url = params['url'] as String;
        final sourceMapURL = params['sourceMapURL'] as String?;
        if (url.contains('main.dart.js')) {
          print('Found main.dart.js! SourceMap URL: $sourceMapURL');
        }
      }
    });

    // Enable Page domain
    await _connection?.sendCommand('Page.enable');

    // Navigate to the target URL after setting up listeners
    await _connection?.sendCommand('Page.navigate', {'url': url});
    print('Navigated to $url');
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

  Future<void> startProfiling() async {
    await _connection?.sendCommand('Profiler.enable');
    await _connection?.sendCommand('Profiler.start');
    print('Profiler started.');
  }

  Future<Map<String, dynamic>> stopProfiling() async {
    final response = await _connection?.sendCommand('Profiler.stop');
    print('Profiler stopped.');
    return response!.result!['profile'] as Map<String, dynamic>;
  }

  Future<void> stop() async {
    await _connection?.close();
    _chromeProcess?.kill();
    // Wait for process to exit to release file locks
    await _chromeProcess?.exitCode;
    await _tempDir?.delete(recursive: true);
  }
}
