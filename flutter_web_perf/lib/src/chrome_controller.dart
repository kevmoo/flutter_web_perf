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
  final Set<String> _workerSessionIds = <String>{};
  final Map<int, Completer<Map<String, dynamic>>> _workerPendingCommands = {};
  int _nextWorkerMsgId = 10000;
  bool _isProfiling = false;
  int? _profilingIntervalUs;

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

    _setupWorkerAutoAttach();

    if (enableDebugger) {
      await _enableDebuggerLogging();
    }

    await _enableConsoleLogging();
    await _sendCommandWithTimeout('Page.enable');
    print('Sending Page.navigate to $url...');
    await _connection?.sendCommand('Page.navigate', {'url': url});
    print('Navigated to $url');
  }

  void _setupWorkerAutoAttach() {
    _connection?.onNotification.listen((notification) {
      if (notification.method == 'Target.attachedToTarget') {
        final params = notification.params ?? const <String, dynamic>{};
        final sessionId = params['sessionId'] as String?;
        final targetInfo = params['targetInfo'] as Map<String, dynamic>?;
        if (sessionId != null && targetInfo?['type'] == 'worker') {
          _workerSessionIds.add(sessionId);
          if (_isProfiling) {
            unawaited(_startWorkerProfiler(sessionId));
          }
        }
      } else if (notification.method == 'Target.detachedFromTarget') {
        final sessionId = notification.params?['sessionId'] as String?;
        if (sessionId != null) {
          _workerSessionIds.remove(sessionId);
        }
      } else if (notification.method == 'Target.receivedMessageFromTarget') {
        final messageStr = notification.params?['message'] as String?;
        if (messageStr != null) {
          try {
            final msg = json.decode(messageStr) as Map<String, dynamic>;
            final id = msg['id'] as int?;
            if (id != null && _workerPendingCommands.containsKey(id)) {
              _workerPendingCommands
                  .remove(id)!
                  .complete(
                    (msg['result'] as Map<String, dynamic>?) ??
                        const <String, dynamic>{},
                  );
            }
          } catch (_) {}
        }
      }
    });
    unawaited(
      _connection?.sendCommand('Target.setAutoAttach', {
        'autoAttach': true,
        'waitForDebuggerOnStart': false,
        'flatten': false,
      }),
    );
  }

  Future<Map<String, dynamic>> _sendWorkerCommand(
    String sessionId,
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final id = _nextWorkerMsgId++;
    final completer = Completer<Map<String, dynamic>>();
    _workerPendingCommands[id] = completer;
    final payload = json.encode({
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    });
    await _connection?.sendCommand('Target.sendMessageToTarget', {
      'sessionId': sessionId,
      'message': payload,
    });
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _workerPendingCommands.remove(id);
        return const <String, dynamic>{};
      },
    );
  }

  Future<void> _startWorkerProfiler(String sessionId) async {
    try {
      await _sendWorkerCommand(sessionId, 'Profiler.enable');
      if (_profilingIntervalUs != null) {
        await _sendWorkerCommand(sessionId, 'Profiler.setSamplingInterval', {
          'interval': _profilingIntervalUs,
        });
      }
      await _sendWorkerCommand(sessionId, 'Profiler.start');
    } catch (_) {}
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
    StreamSubscription<WipEvent>? completeSub;
    completeSub = _connection?.onNotification.listen((notification) {
      if (notification.method == 'Tracing.tracingComplete') {
        subscription?.cancel();
        completeSub?.cancel();
        completer.complete(data);
      }
    });

    return completer.future;
  }

  Future<void> startProfiling({int? intervalUs}) async {
    _isProfiling = true;
    _profilingIntervalUs = intervalUs;
    await _connection?.sendCommand('Profiler.enable');
    if (intervalUs != null) {
      await _connection?.sendCommand('Profiler.setSamplingInterval', {
        'interval': intervalUs,
      });
      print('Profiler sampling interval set to $intervalUs microseconds.');
    }
    await _connection?.sendCommand('Profiler.start');
    for (final sessionId in _workerSessionIds.toList()) {
      await _startWorkerProfiler(sessionId);
    }
    print(
      'Profiler started (with ${_workerSessionIds.length} worker session(s)).',
    );
  }

  Future<Map<String, dynamic>> stopProfiling() async {
    _isProfiling = false;
    final response = await _connection?.sendCommand('Profiler.stop');
    final mainProfile = Map<String, dynamic>.from(
      response!.result!['profile'] as Map<String, dynamic>,
    );

    for (final sessionId in _workerSessionIds.toList()) {
      try {
        final workerRes = await _sendWorkerCommand(sessionId, 'Profiler.stop');
        final workerProfile = workerRes['profile'] as Map<String, dynamic>?;
        if (workerProfile != null) {
          mergeWorkerCpuProfile(mainProfile, workerProfile);
        }
      } catch (_) {}
    }

    print('Profiler stopped.');
    return mainProfile;
  }

  static void mergeWorkerCpuProfile(
    Map<String, dynamic> targetProfile,
    Map<String, dynamic> workerProfile,
  ) {
    final targetNodes = (targetProfile['nodes'] as List)
        .cast<Map<String, dynamic>>()
        .toList();
    final targetSamples =
        (targetProfile['samples'] as List?)?.cast<int>().toList() ?? <int>[];

    final workerNodes = (workerProfile['nodes'] as List?)
        ?.cast<Map<String, dynamic>>();
    final workerSamples = (workerProfile['samples'] as List?)?.cast<int>();
    if (workerNodes == null ||
        workerNodes.isEmpty ||
        workerSamples == null ||
        workerSamples.isEmpty) {
      return;
    }

    var maxNodeId = 0;
    for (final n in targetNodes) {
      final id = n['id'] as int? ?? 0;
      if (id > maxNodeId) maxNodeId = id;
    }
    final idOffset = maxNodeId + 1000;

    int? workerRootOffsetId;
    for (final wNode in workerNodes) {
      final origId = wNode['id'] as int;
      final newId = origId + idOffset;
      workerRootOffsetId ??= newId;
      final children = (wNode['children'] as List?)
          ?.map((c) => (c as int) + idOffset)
          .toList();
      targetNodes.add({
        ...wNode,
        'id': newId,
        if (children != null) 'children': children,
      });
    }

    if (targetNodes.isNotEmpty && workerRootOffsetId != null) {
      final rootNode = Map<String, dynamic>.from(targetNodes.first);
      final rootChildren = [
        ...((rootNode['children'] as List?)?.cast<int>() ?? const <int>[]),
        workerRootOffsetId,
      ];
      rootNode['children'] = rootChildren;
      targetNodes[0] = rootNode;
    }

    targetSamples.addAll(workerSamples.map((s) => s + idOffset));
    targetProfile['nodes'] = targetNodes;
    targetProfile['samples'] = targetSamples;
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
    _workerSessionIds.clear();
    _workerPendingCommands.clear();
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
