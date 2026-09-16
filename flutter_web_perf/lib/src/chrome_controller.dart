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

  Future<void> start(String url, {bool enableDebugger = true}) async {
    final chromePath = Platform.isLinux
        ? '/usr/bin/google-chrome'
        : '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

    _tempDir = await Directory.systemTemp.createTemp('chrome_profile_');
    await _launchChromeProcess(chromePath, _tempDir!.path);

    final port = await _waitForDevToolsPort(_tempDir!.path);
    print('Chrome listening on dynamic port: $port');

    final wsUrl = await _findPageDebuggerUrl(port);
    _connection = await WipConnection.connect(wsUrl);
    print('Connected to Chrome via $wsUrl!');

    if (enableDebugger) {
      await _enableDebuggerLogging();
    }

    await _enableConsoleLogging();
    await _sendCommandWithTimeout('Page.enable');
    print('Sending Page.navigate to $url...');
    await _connection?.sendCommand('Page.navigate', {'url': url});
    print('Navigated to $url');
  }

  Future<void> _launchChromeProcess(
    String chromePath,
    String userDataDir,
  ) async {
    _chromeProcess = await Process.start(chromePath, [
      '--remote-debugging-port=0',
      '--remote-allow-origins=*',
      '--headless=new',
      '--no-sandbox',
      '--disable-dev-shm-usage',
      '--disable-extensions',
      '--disable-background-networking',
      '--disable-sync',
      '--no-first-run',
      '--no-proxy-server',
      '--password-store=basic',
      '--use-mock-keychain',
      '--user-data-dir=$userDataDir',
      'about:blank',
    ]);
    _chromeProcess?.stdout
        .transform(utf8.decoder)
        .listen((data) => print('Chrome STDOUT: $data'));
    _chromeProcess?.stderr
        .transform(utf8.decoder)
        .listen((data) => print('Chrome STDERR: $data'));
  }

  Future<int> _waitForDevToolsPort(String userDataDir) async {
    final activePortFile = File(p.join(userDataDir, 'DevToolsActivePort'));
    var attempts = 0;
    while (!await activePortFile.exists() && attempts < 150) {
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
    return int.parse(lines[0]);
  }

  Future<String> _findPageDebuggerUrl(int port) async {
    http.Response? response;
    for (var i = 0; i < 10; i++) {
      try {
        response = await http.get(Uri.parse('http://127.0.0.1:$port/json'));
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
    return targetTab['webSocketDebuggerUrl'] as String;
  }

  Future<void> _sendCommandWithTimeout(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    print('Sending $method...');
    await _connection
        ?.sendCommand(method, params)
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            print('$method timed out!');
            throw Exception('Timeout waiting for $method');
          },
        );
    print('$method completed.');
  }

  Future<void> _enableDomainAndListen(
    String enableCommand,
    String eventMethod,
    void Function(Map<String, dynamic> params) handler,
  ) async {
    await _sendCommandWithTimeout(enableCommand);
    _connection?.onNotification.listen((notification) {
      if (notification.method != eventMethod) return;
      handler(notification.params as Map<String, dynamic>);
    });
  }

  Future<void> _enableDebuggerLogging() => _enableDomainAndListen(
    'Debugger.enable',
    'Debugger.scriptParsed',
    (params) {
      final url = params['url'] as String;
      if (url.contains('main.dart.js')) {
        print('Found main.dart.js! SourceMap URL: ${params['sourceMapURL']}');
      }
    },
  );

  Future<void> _enableConsoleLogging() => _enableDomainAndListen(
    'Runtime.enable',
    'Runtime.consoleAPICalled',
    (params) {
      final type = params['type'] as String;
      final args = params['args'] as List;
      final firstArg = args.isNotEmpty ? args.first : null;
      final message = firstArg is Map<String, dynamic>
          ? (firstArg['value'] as String? ?? '')
          : '';
      if (message.isNotEmpty) {
        print('Chrome Console [$type]: $message');
      }
    },
  );

  Future<void> startTracing() async {
    await _connection?.sendCommand('Tracing.start', {
      'categories': 'devtools.timeline,benchmark,blink.user_timing',
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

    final completer = Completer<List<Map<String, dynamic>>>();
    _connection?.onNotification.listen((notification) {
      if (notification.method == 'Tracing.tracingComplete') {
        subscription?.cancel();
        completer.complete(data);
      }
    });

    return completer.future;
  }

  Future<void> startProfiling({int? intervalUs}) async {
    await _connection?.sendCommand('Profiler.enable');
    if (intervalUs != null) {
      await _connection?.sendCommand('Profiler.setSamplingInterval', {
        'interval': intervalUs,
      });
      print('Profiler sampling interval set to $intervalUs microseconds.');
    }
    await _connection?.sendCommand('Profiler.start');
    print('Profiler started.');
  }

  Future<Map<String, dynamic>> stopProfiling() async {
    final response = await _connection?.sendCommand('Profiler.stop');
    print('Profiler stopped.');
    return response!.result!['profile'] as Map<String, dynamic>;
  }

  Future<void> startHeapAllocationProfiling() async {
    await _connection?.sendCommand('HeapProfiler.enable');
    await _connection?.sendCommand('HeapProfiler.startSampling', {
      'samplingInterval': 32768,
    });
    print('Heap allocation profiler started.');
  }

  Future<Map<String, dynamic>> stopHeapAllocationProfiling() async {
    final response = await _connection?.sendCommand(
      'HeapProfiler.stopSampling',
    );
    print('Heap allocation profiler stopped.');
    return response!.result!['profile'] as Map<String, dynamic>;
  }

  Future<void> stop() async {
    await _connection?.close();
    _connection = null;

    _chromeProcess?.kill();
    await _chromeProcess?.exitCode;
    _chromeProcess = null;

    if (_tempDir != null && await _tempDir!.exists()) {
      try {
        await _tempDir!.delete(recursive: true);
      } catch (_) {
        // Ignore file deletion errors.
      }
    }
    _tempDir = null;
  }
}
