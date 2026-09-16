import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'chrome_controller.dart';
import 'html_reporter.dart';
import 'performance_report.dart';
import 'profile_symbolicator.dart';
import 'report_directory.dart';
import 'server.dart';
import 'trace_analyzer.dart';
import 'utils.dart';
import 'wasm_parser.dart';

enum CompileTarget { js, wasm }

Future<void> runApp({
  required CompileTarget target,
  required String appDir,
  required String outDir,
  required bool analyzeOnly,
  int? analyzeHotspotRank,
  int? samplingIntervalUs,
  String? queryParameters,
  int durationSeconds = 5,
}) async {
  final runner = _AppRunner(
    target: target,
    appDir: appDir,
    outDir: outDir,
    analyzeOnly: analyzeOnly,
    analyzeHotspotRank: analyzeHotspotRank,
    samplingIntervalUs: samplingIntervalUs,
    queryParameters: queryParameters,
    durationSeconds: durationSeconds,
  );
  await runner._run();
}

class _AppRunner {
  final CompileTarget _target;
  final String _appDir;
  final bool _analyzeOnly;
  final int? _analyzeHotspotRank;
  final int? _samplingIntervalUs;
  final String? _queryParameters;
  final int _durationSeconds;
  final String _buildPath;
  final PerformanceReportDirectory _reportDir;

  final _server = DevServer();
  final _controller = ChromeController();

  _AppRunner({
    required String outDir,
    required this._target,
    required this._appDir,
    required this._analyzeOnly,
    this._analyzeHotspotRank,
    this._samplingIntervalUs,
    this._queryParameters,
    this._durationSeconds = 5,
  }) : _buildPath = '$_appDir/build/web',
       _reportDir = PerformanceReportDirectory(outDir);

  Future<void> _run() async {
    print('Hello from flutter_web_perf tool!');
    print('Target: ${_target.name}');
    print('App Directory: $_appDir');
    if (_analyzeOnly) {
      print('Mode: Analyze-Only (Skipping build & profile runs)');
      if (!_reportDir.traceFile.existsSync() ||
          !_reportDir.profileFile.existsSync()) {
        print(
          'Error: Cannot run in --analyze-only mode because trace or profile '
          'files are missing in ${_reportDir.path} directory.',
        );
        print('Please run a full profiling session first.');
        exitCode = 1;
        return;
      }
    }

    try {
      if (!_analyzeOnly) {
        await _runTracePhase();
        await _runProfilePhase();
      }
      await _runAnalysisPhase();
    } catch (e) {
      print('Error: $e');
    } finally {
      await _controller.stop();
      await _server.stop();
      print('Stopped server and Chrome.');
    }
  }

  String _buildTargetUrl(int port) {
    final defaultQuery = _target == CompileTarget.js
        ? 'mode=canvaskit'
        : 'mode=skwasm';
    final query = (_queryParameters != null && _queryParameters.isNotEmpty)
        ? _queryParameters
        : defaultQuery;
    return 'http://127.0.0.1:$port/?$query';
  }

  Future<void> _runFlutterBuild(List<String> args) async {
    final flutterBin = File('${_resolveLocalFlutterRepo()}/bin/flutter');
    final executable = flutterBin.existsSync() ? flutterBin.path : 'flutter';
    final buildResult = await Process.run(
      executable,
      args,
      workingDirectory: _appDir,
    );
    if (buildResult.exitCode != 0) {
      throw Exception('Build failed!\n${buildResult.stderr}');
    }
    print('Build successful.');
  }

  Future<void> _runTracePhase() async {
    print('\n=== Phase 1: Trace Run (--profile) ===');
    print('Building app in $_appDir...');
    final traceBuildArgs = [
      'build',
      'web',
      '--profile',
      '--source-maps',
      '--no-web-resources-cdn',
      if (_target == CompileTarget.wasm) ...['--wasm', '--no-strip-wasm'],
    ];
    await _runFlutterBuild(traceBuildArgs);

    final port = await _server.start(_buildPath);
    final url = _buildTargetUrl(port);
    await _controller.start(url);
    print('Chrome started and navigated to $url');

    await _controller.startTracing();
    await Future<void>.delayed(Duration(seconds: _durationSeconds));
    final events = await _controller.stopTracing();

    print('Collected ${events.length} trace events.');
    await _reportDir.traceFile.writeAsString(json.encode(events));
    print('Saved trace data to ${_reportDir.traceFile.absolute.path}');

    await _controller.stop();
    await _server.stop();
  }

  Future<void> _runProfilePhase() async {
    print('\n=== Phase 2: Profile Run (--release) ===');

    if (_target == CompileTarget.wasm) {
      await _buildAndExtractUnoptimizedWasm();
    }

    print('Building fully optimized app in $_appDir (--release)...');
    final profileBuildArgs = [
      'build',
      'web',
      '--release',
      '--source-maps',
      '--no-web-resources-cdn',
      if (_target == CompileTarget.wasm) ...['--wasm', '--no-strip-wasm'],
    ];
    await _runFlutterBuild(profileBuildArgs);

    final port = await _server.start(_buildPath);
    final url = _buildTargetUrl(port);
    await _controller.start(url, enableDebugger: false);
    print('Chrome started and navigated to $url');

    await _controller.startProfiling(intervalUs: _samplingIntervalUs);
    await _controller.startHeapAllocationProfiling();
    await Future<void>.delayed(Duration(seconds: _durationSeconds));
    final profile = await _controller.stopProfiling();
    final allocations = await _controller.stopHeapAllocationProfiling();

    await _reportDir.profileFile.writeAsString(json.encode(profile));
    print('Saved profile data to ${_reportDir.profileFile.absolute.path}');
    await _reportDir.allocationsFile.writeAsString(json.encode(allocations));
    print(
      'Saved heap allocation data to '
      '${_reportDir.allocationsFile.absolute.path}',
    );

    await _controller.stop();
    await _server.stop();
  }

  Future<void> _buildAndExtractUnoptimizedWasm() async {
    print('Building unoptimized app in $_appDir for comparison (-O 0)...');
    await _runFlutterBuild([
      'build',
      'web',
      '--release',
      '--source-maps',
      '--no-web-resources-cdn',
      '-O',
      '0',
      '--wasm',
      '--no-strip-wasm',
    ]);

    print('Extracting unoptimized Wasm disassembly...');
    await _dumpWasmToWat(
      '$_buildPath/main.dart.wasm',
      _reportDir.unoptimizedWatFile.path,
    );
  }

  Future<bool> _dumpWasmToWat(String wasmPath, String outputWatPath) async {
    final wasmToolsBin = _resolveWasmToolsBinary();
    try {
      final dumpResult = await Process.run(wasmToolsBin, [
        'print',
        wasmPath,
        '-o',
        outputWatPath,
      ]);
      if (dumpResult.exitCode == 0) return true;
      print('Failed to dump WAT: ${dumpResult.stderr}');
    } catch (e) {
      print('Warning: wasm-tools execution failed ($e); skipping WAT dump.');
    }
    return File(outputWatPath).existsSync();
  }

  String _resolveWasmToolsBinary() {
    final home = Platform.environment['HOME'];
    if (home != null) {
      for (final candidate in [
        '$home/.local/share/mise/shims/wasm-tools',
        '$home/.cargo/bin/wasm-tools',
      ]) {
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return 'wasm-tools';
  }

  Future<void> _runAnalysisPhase() async {
    print('\n=== Phase 3: Analysis ===');
    final mapPath = _target == CompileTarget.wasm
        ? '$_buildPath/main.dart.wasm.map'
        : '$_buildPath/main.dart.js.map';

    final analyzer = TraceAnalyzer(
      _reportDir.traceFile.path,
      sourceMapPath: mapPath,
    );

    final symbolicatedProfile = await symbolicateProfile(
      profilePath: _reportDir.profileFile.path,
      sourceMapPath: mapPath,
    );

    final symbolicatedFile = _reportDir.symbolicatedProfileFile;
    await symbolicatedFile.writeAsString(json.encode(symbolicatedProfile));
    print('Saved symbolicated profile to ${symbolicatedFile.absolute.path}');

    final report = await analyzer.generateReport(
      profilePath: symbolicatedFile.path,
    );

    if (_reportDir.allocationsFile.existsSync()) {
      _attributeAllocations(report);
    }

    final localFlutterRepo = _resolveLocalFlutterRepo();
    final flutterSha = await _resolveFlutterSha(localFlutterRepo);

    _printReportSummary(report);
    await _printHotspotsAndSources(report, flutterSha, localFlutterRepo);

    if (_target == CompileTarget.wasm) {
      await _runWasmDeepDive(report, localFlutterRepo);
    }

    final htmlReporter = HtmlReporter();
    await htmlReporter.saveReport(report, _reportDir.reportHtmlFile.path);
  }

  String _resolveLocalFlutterRepo() {
    final envRoot = Platform.environment['FLUTTER_ROOT'];
    if (envRoot != null && Directory(envRoot).existsSync()) return envRoot;

    try {
      final whichRes = Process.runSync('which', ['flutter']);
      if (whichRes.exitCode == 0) {
        final binPath = File(whichRes.stdout.toString().trim())
            .resolveSymbolicLinksSync();
        return File(binPath).parent.parent.path;
      }
    } catch (_) {}

    final home =
        Platform.environment['HOME'] ?? '/usr/local/google/home/kevmoo';
    return p.join(home, 'github/flutter');
  }

  Future<String?> _resolveFlutterSha(String localFlutterRepo) async {
    try {
      final shaResult = await Process.run('git', [
        'rev-parse',
        'HEAD',
      ], workingDirectory: localFlutterRepo);
      if (shaResult.exitCode == 0) {
        return shaResult.stdout.toString().trim();
      }
    } catch (_) {}
    return null;
  }

  void _printReportSummary(PerformanceReport report) {
    print('\n=== Performance Report Summary ===');
    print(
      'Average Frame Interval: '
      '${report.frameHealth.avgIntervalMs?.toStringAsFixed(2)} ms',
    );
    print(
      'Average Frame Work Duration: '
      '${report.frameHealth.avgWorkMs?.toStringAsFixed(2)} ms',
    );
    print('Drop Rate: ${report.frameHealth.dropRate.toStringAsFixed(2)}%');
    print('Requested Frames: ${report.frameHealth.requestedCount}');
    print('Processed Frames: ${report.frameHealth.processedCount}');

    print('\n=== Time Breakdown ===');
    report.timeBreakdown.forEach((cat, dur) {
      print('${cat.label}: ${dur.toStringAsFixed(2)} ms');
    });
  }

  void _attributeAllocations(PerformanceReport report) {
    try {
      final heapContent = _reportDir.allocationsFile.readAsStringSync();
      final heapData = json.decode(heapContent) as Map<String, dynamic>;
      final head = heapData['head'] as Map<String, dynamic>?;
      if (head == null) return;

      final collector = _AllocationCollector()..accumulate(head);
      report.frameHealth.totalAllocatedBytes = collector.totalAllocatedBytes;

      for (final f in report.hotFunctions) {
        final allocatedBytes =
            (f.wasmFunctionIndex != null
                ? collector.allocationsByWasmIndex[f.wasmFunctionIndex!]
                : null) ??
            collector.allocationsByFunction[f.name];
        if (allocatedBytes != null) {
          f.allocationsBytes = allocatedBytes.toInt();
        }
      }
    } catch (e) {
      print('Warning: Failed to parse allocations profile: $e');
    }
  }

  Future<void> _printHotspotsAndSources(
    PerformanceReport report,
    String? flutterSha,
    String localFlutterRepo,
  ) async {
    print('\n=== Top 10 Hot Functions ===');
    for (var i = 0; i < report.hotFunctions.length; i++) {
      final f = report.hotFunctions[i];
      final resolved = await _resolveHotspotSourceContext(
        f,
        flutterSha: flutterSha,
        localFlutterRepo: localFlutterRepo,
      );
      final wasmLabel = f.wasmFunctionIndex != null
          ? ' (Wasm Index: ${f.wasmFunctionIndex})'
          : '';
      print('${i + 1}. ${f.name}$wasmLabel: ${f.samples} samples');

      if (resolved != null) {
        _printSourceSnippet(
          resolved.filePath,
          resolved.lines,
          resolved.displayLineNumber,
        );
      }
    }
  }

  Future<_ResolvedSourceContext?> _resolveHotspotSourceContext(
    HotFunction f, {
    required String? flutterSha,
    required String localFlutterRepo,
  }) async {
    if (f.lineNumber == null) return null;
    try {
      final localFilePath = resolveLocalFilePath(
        f.url,
        localFlutterRepo: localFlutterRepo,
        appDir: _appDir,
      );
      if (localFilePath == null) return null;

      final sourceFile = File(localFilePath);
      if (!await sourceFile.exists()) return null;

      final rawMethodName =
          (f.name.contains('.') ? f.name.split('.').last : f.name).replaceFirst(
            RegExp(r'\s*\(.*\)$'),
            '',
          );
      final className = resolveClassForMethod(
        localFilePath,
        f.lineNumber!,
        rawMethodName,
      );
      if (className != null && !f.name.contains('.')) {
        f.name = '$className.${f.name}';
      }

      final displayLineNumber = className != null
          ? (findMethodDeclarationLine(
                  localFilePath,
                  className,
                  rawMethodName,
                ) ??
                f.lineNumber!)
          : f.lineNumber!;

      _maybeAssignGithubUrl(
        f,
        localFilePath: localFilePath,
        flutterSha: flutterSha,
        lineNumber: displayLineNumber,
      );

      return _ResolvedSourceContext(
        filePath: sourceFile.path,
        lines: await sourceFile.readAsLines(),
        displayLineNumber: displayLineNumber,
      );
    } catch (_) {
      return null;
    }
  }

  void _maybeAssignGithubUrl(
    HotFunction f, {
    required String localFilePath,
    required String? flutterSha,
    required int lineNumber,
  }) {
    if (flutterSha == null ||
        !localFilePath.contains('/packages/flutter/lib/')) {
      return;
    }
    final suffix = localFilePath.split('/packages/flutter/lib/').last;
    f.githubUrl =
        'https://github.com/flutter/flutter/blob/$flutterSha/'
        'packages/flutter/lib/$suffix#L$lineNumber';
  }

  void _printSourceSnippet(
    String filePath,
    List<String> lines,
    int displayLineNumber,
  ) {
    if (lines.isEmpty) return;
    final centerIdx = (displayLineNumber - 1).clamp(0, lines.length - 1);
    final startIdx = (centerIdx - 2).clamp(0, lines.length - 1);
    final endIdx = (centerIdx + 3).clamp(0, lines.length);

    print('    📍 $filePath:$displayLineNumber');
    print('    ╭────────────────────────────────────────');
    for (var idx = startIdx; idx < endIdx; idx++) {
      final prefix = idx == centerIdx ? '    │ > ' : '    │   ';
      print('$prefix${lines[idx]}');
    }
    print('    ╰────────────────────────────────────────');
  }

  Future<void> _runWasmDeepDive(
    PerformanceReport report,
    String localFlutterRepo,
  ) async {
    print('\n=== Deep Dive Analysis: Extracting Wasm Disassembly ===');
    final watFile = _reportDir.mainWatFile;
    final dumped = await _dumpWasmToWat(
      '$_buildPath/main.dart.wasm',
      watFile.path,
    );
    if (!dumped) return;

    final identifiers = report.hotFunctions
        .map((f) => f.wasmFunctionIndex?.toString() ?? f.name)
        .where((id) => id.isNotEmpty)
        .toList();

    final instructionsMap = extractWasmFunctions(watFile.path, identifiers);
    _populateOptimizedWasm(report, instructionsMap);
    _populateUnoptimizedWasmIfPresent(report, localFlutterRepo);

    print(
      'Successfully extracted disassembly for '
      '${instructionsMap.length} hot functions (optimized & unoptimized).',
    );
    _printRequestedHotspotRank(report);
  }

  void _populateOptimizedWasm(
    PerformanceReport report,
    Map<String, String> instructionsMap,
  ) {
    for (final f in report.hotFunctions) {
      final id = f.wasmFunctionIndex?.toString() ?? f.name;
      f.wasmInstructions = instructionsMap[id];
      f.wasmAnalysis = analyzeWasmInstructions(f.wasmInstructions);
    }
  }

  void _populateUnoptimizedWasmIfPresent(
    PerformanceReport report,
    String localFlutterRepo,
  ) {
    final unoptWatFile = _reportDir.unoptimizedWatFile;
    if (!unoptWatFile.existsSync()) return;

    final functionToUnoptId = <HotFunction, String>{
      for (final f in report.hotFunctions)
        f: _resolveUnoptimizedIdentifier(f, localFlutterRepo),
    };

    final extracted = extractWasmFunctions(
      unoptWatFile.path,
      functionToUnoptId.values.toList(),
    );

    for (final f in report.hotFunctions) {
      final unoptId = functionToUnoptId[f]!;
      f.wasmInstructionsUnoptimized = extracted[unoptId];
      f.wasmAnalysisUnoptimized = analyzeWasmInstructions(
        f.wasmInstructionsUnoptimized,
      );
    }
  }

  String _resolveUnoptimizedIdentifier(HotFunction f, String localFlutterRepo) {
    if (f.name.contains('.')) return f.name;
    if (f.lineNumber == null) return f.name;
    final localFilePath = resolveLocalFilePath(
      f.url,
      localFlutterRepo: localFlutterRepo,
      appDir: _appDir,
    );
    if (localFilePath == null) return f.name;
    try {
      final className = resolveClassForMethod(
        localFilePath,
        f.lineNumber!,
        f.name,
      );
      if (className != null) return '$className.${f.name}';
    } catch (_) {}
    return f.name;
  }

  void _printRequestedHotspotRank(PerformanceReport report) {
    final rank = _analyzeHotspotRank;
    if (rank == null) return;
    if (rank < 1 || rank > report.hotFunctions.length) {
      print('\nError: --analyze-hotspot rank $rank is out of bounds.');
      return;
    }
    final targetFunc = report.hotFunctions[rank - 1];
    if (targetFunc.wasmInstructions != null) {
      print('\nDeep Dive Analysis for #$rank: ${targetFunc.name}\n');
      print(targetFunc.wasmInstructions);
    } else {
      print('\nError: Could not find instructions for "${targetFunc.name}".');
    }
  }
}

class _ResolvedSourceContext {
  final String filePath;
  final List<String> lines;
  final int displayLineNumber;

  _ResolvedSourceContext({
    required this.filePath,
    required this.lines,
    required this.displayLineNumber,
  });
}

class _AllocationCollector {
  final allocationsByFunction = <String, num>{};
  final allocationsByWasmIndex = <int, num>{};
  int totalAllocatedBytes = 0;

  static final _wasmFuncRegExp = RegExp(r'wasm-function\[(\d+)\]');

  void accumulate(Map<String, dynamic> node) {
    final selfSize = node['selfSize'] as num? ?? 0;
    if (selfSize > 0) {
      _recordSelfAllocation(node, selfSize);
    }

    final children = node['children'] as List?;
    if (children == null) return;
    for (final child in children.whereType<Map<String, dynamic>>()) {
      accumulate(child);
    }
  }

  void _recordSelfAllocation(Map<String, dynamic> node, num selfSize) {
    totalAllocatedBytes += selfSize.toInt();
    final callFrame = node['callFrame'] as Map<String, dynamic>?;
    final functionName = callFrame?['functionName'] as String? ?? '';
    final wasmMatch = _wasmFuncRegExp.firstMatch(functionName);
    if (wasmMatch != null) {
      final index = int.parse(wasmMatch.group(1)!);
      allocationsByWasmIndex[index] =
          (allocationsByWasmIndex[index] ?? 0) + selfSize;
    } else {
      allocationsByFunction[functionName] =
          (allocationsByFunction[functionName] ?? 0) + selfSize;
    }
  }
}
