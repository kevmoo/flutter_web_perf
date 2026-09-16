import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'performance_report.dart';
import 'profile_model.dart';
import 'profile_symbolicator.dart';

class TraceAnalyzer {
  final String tracePath;
  final String? sourceMapPath;
  final bool expandCanvaskitFrames;

  TraceAnalyzer(
    this.tracePath, {
    this.sourceMapPath,
    this.expandCanvaskitFrames = false,
  });

  static String get defaultTraceProcessorPath => _resolveTraceProcessorPath();

  static String _resolveTraceProcessorPath() {
    final envOverride = Platform.environment['TRACE_PROCESSOR_SHELL'];
    if (envOverride != null && File(envOverride).existsSync()) {
      return envOverride;
    }

    final fromPath = _findExecutableOnPath('trace_processor_shell');
    if (fromPath != null) return fromPath;

    final home =
        Platform.environment['HOME'] ?? '/usr/local/google/home/kevmoo';
    final candidates = [
      p.join(home, 'github/perfetto/out/default/trace_processor_shell'),
      '/Users/kevmoo/github/perfetto/out/default/trace_processor_shell',
      ?_findPerfettoPrebuilt(home),
    ];
    return candidates.firstWhere(
      (path) => File(path).existsSync(),
      orElse: () => candidates.first,
    );
  }

  static String? _findExecutableOnPath(String binary) {
    try {
      final res = Process.runSync('which', [binary]);
      final found = res.stdout.toString().trim();
      if (res.exitCode == 0 && found.isNotEmpty && File(found).existsSync()) {
        return found;
      }
    } catch (_) {}
    return null;
  }

  static String? _findPerfettoPrebuilt(String home) {
    final dir = Directory(p.join(home, '.local/share/perfetto/prebuilts'));
    if (!dir.existsSync()) return null;
    for (final entity in dir.listSync().whereType<File>()) {
      if (p.basename(entity.path).startsWith('trace_processor_shell')) {
        return entity.path;
      }
    }
    return null;
  }

  Future<PerformanceReport> generateReport({
    String? traceProcessorPath,
    required String profilePath,
  }) async {
    final tpPath = traceProcessorPath ?? defaultTraceProcessorPath;
    if (!await File(tpPath).exists()) {
      throw Exception('Trace Processor not found at: $tpPath');
    }

    print('Analyzing trace using Trace Processor...');

    final tempDir = await Directory.systemTemp.createTemp('query_');
    final qFile = File(p.join(tempDir.path, 'query.sql'));

    FrameHealth? frameHealth;
    Map<PerformanceCategory, double> breakdown;

    try {
      frameHealth = await _queryFrameHealth(tpPath, qFile);
      breakdown = await _queryTimeBreakdown(tpPath, qFile);
    } finally {
      await tempDir.delete(recursive: true);
    }

    if (frameHealth == null) {
      throw Exception('Failed to parse frame health data from Trace Processor');
    }

    final profileFile = File(profilePath);
    if (!await profileFile.exists()) {
      throw Exception('Profile file not found: $profilePath');
    }

    final content = await profileFile.readAsString();
    final profile = CpuProfile.fromJson(
      json.decode(content) as Map<String, dynamic>,
    );

    return PerformanceReport(
      frameHealth: frameHealth,
      timeBreakdown: breakdown,
      slowTasks: [],
      hotFunctions: processProfile(profile),
    );
  }

  Future<String> _executeSqlQuery(String tpPath, File qFile, String sql) async {
    await qFile.writeAsString(sql);
    final result = await Process.run(tpPath, [tracePath, '-q', qFile.path]);
    if (result.exitCode != 0) {
      throw Exception('Failed to run Trace Processor: ${result.stderr}');
    }
    return result.stdout.toString();
  }

  Future<FrameHealth?> _queryFrameHealth(String tpPath, File qFile) async {
    const frameHealthQuery = '''
      WITH frame_times AS (
        SELECT ts,
               LEAD(ts) OVER (ORDER BY ts) - ts AS frame_dur
        FROM slice
        WHERE name = 'Scheduler::BeginFrame'
      )
      SELECT
        (SELECT AVG(frame_dur) / 1000000.0 FROM frame_times WHERE frame_dur IS NOT NULL) AS avg_interval_ms,
        (SELECT AVG(dur) / 1000000.0 FROM slice WHERE name = 'AnimationFrame') AS avg_work_ms,
        (SELECT COUNT(*) FROM slice WHERE name = 'Scheduler::BeginFrame') AS requested_count,
        (SELECT COUNT(*) FROM slice WHERE name = 'AnimationFrame') AS processed_count;
    ''';

    final output = await _executeSqlQuery(tpPath, qFile, frameHealthQuery);
    final lines = output.split('\n');
    for (var i = 0; i < lines.length - 1; i++) {
      if (lines[i].startsWith('"avg_interval_ms"')) {
        final data = lines[i + 1].split(',');
        return FrameHealth(
          avgIntervalMs: double.tryParse(data[0]),
          avgWorkMs: double.tryParse(data[1]),
          requestedCount: int.tryParse(data[2]) ?? 0,
          processedCount: int.tryParse(data[3]) ?? 0,
        );
      }
    }
    return null;
  }

  Future<Map<PerformanceCategory, double>> _queryTimeBreakdown(
    String tpPath,
    File qFile,
  ) async {
    final output = await _executeSqlQuery(tpPath, qFile, _buildBreakdownSql());
    return _parseBreakdownOutput(output);
  }

  String _buildBreakdownSql() {
    String patternToSql(String pattern) => pattern.contains('%')
        ? "s.name LIKE '$pattern'"
        : "s.name = '$pattern'";

    final sqlCases = PerformanceCategory.values
        .where((c) => c.sqlPatterns.isNotEmpty)
        .map((c) {
          final cond = c.sqlPatterns.map(patternToSql).join(' OR ');
          return "          WHEN $cond THEN '${c.label}'";
        })
        .join('\n');

    final sqlWhere = PerformanceCategory.values
        .where((c) => c.sqlPatterns.isNotEmpty)
        .expand((c) => c.sqlPatterns)
        .map(patternToSql)
        .join(' OR ');

    return '''
      SELECT
        CASE
$sqlCases
          ELSE 'Other'
        END AS category,
        SUM(s.dur) / 1000000.0 AS total_dur_ms
      FROM slice s
      LEFT JOIN thread_track tt ON s.track_id = tt.id
      LEFT JOIN thread t ON tt.utid = t.utid
      WHERE (t.name = 'CrRendererMain' OR t.name IS NULL)
        AND ($sqlWhere)
      GROUP BY 1;
    ''';
  }

  Map<PerformanceCategory, double> _parseBreakdownOutput(String output) {
    final breakdown = <PerformanceCategory, double>{};
    final lines = output.split('\n');
    final headerIdx = lines.indexWhere((l) => l.startsWith('"category"'));
    if (headerIdx < 0) return breakdown;

    for (var j = headerIdx + 1; j < lines.length; j++) {
      final data = lines[j].split(',');
      if (data.length != 2) continue;
      final rawCat = data[0].replaceAll('"', '');
      final cat = PerformanceCategory.fromLabel(rawCat);
      final dur = double.tryParse(data[1]) ?? 0.0;
      breakdown[cat] = (breakdown[cat] ?? 0.0) + dur;
    }
    return breakdown;
  }

  List<HotFunction> processProfile(CpuProfile profile) {
    final nodeMap = <int, CpuProfileNode>{};
    final parentMap = <int, int>{};

    for (final node in profile.nodes) {
      nodeMap[node.id] = node;
      for (final childId in node.children) {
        parentMap[childId] = node.id;
      }
    }

    final aggregator = _ProfileSampleAggregator(
      nodeMap: nodeMap,
      parentMap: parentMap,
      expandCanvaskitFrames: expandCanvaskitFrames,
    );

    for (final leafNodeId in profile.samples) {
      aggregator.recordSample(leafNodeId);
    }

    return aggregator.buildTopHotFunctions(profile.samples.length);
  }
}

class _ProfileSampleAggregator {
  final Map<int, CpuProfileNode> nodeMap;
  final Map<int, int> parentMap;
  final bool expandCanvaskitFrames;

  final exclusiveFunctionCounts = <String, int>{};
  final functionNames = <String, String>{};
  final functionUrls = <String, String>{};
  final functionLineCounts = <String, Map<int, int>>{};
  final functionWasmIndices = <String, int?>{};
  final functionPhaseCounts = <String, Map<PerformanceCategory, int>>{};

  _ProfileSampleAggregator({
    required this.nodeMap,
    required this.parentMap,
    required this.expandCanvaskitFrames,
  });

  void recordSample(int leafNodeId) {
    final walked = _walkCallStack(leafNodeId);
    final meaningfulNode = walked.meaningfulNode;
    if (meaningfulNode == null) return;

    final frame = meaningfulNode.callFrame;
    final bucketKey = _bucketKeyFor(walked, frame);
    exclusiveFunctionCounts[bucketKey] =
        (exclusiveFunctionCounts[bucketKey] ?? 0) + 1;
    functionNames[bucketKey] = walked.meaningfulKey;
    functionUrls[bucketKey] = walked.meaningfulUrl;

    final lineNumber = frame.lineNumber;
    if (lineNumber != null && lineNumber >= 0) {
      final lineMap = functionLineCounts.putIfAbsent(
        bucketKey,
        () => <int, int>{},
      );
      lineMap[lineNumber] = (lineMap[lineNumber] ?? 0) + 1;
    }

    if (frame.wasmFunctionIndex != null) {
      functionWasmIndices[bucketKey] = frame.wasmFunctionIndex;
    }

    final phase = _classifyStackPhase(walked.stackNames, walked.targetUrl);
    final phaseMap = functionPhaseCounts.putIfAbsent(
      bucketKey,
      () => <PerformanceCategory, int>{},
    );
    phaseMap[phase] = (phaseMap[phase] ?? 0) + 1;
  }

  String _bucketKeyFor(_StackWalkResult walked, CallFrame frame) {
    if (walked.meaningfulKey == 'CanvasKit Wasm (collapsed)') {
      return walked.meaningfulKey;
    }
    if (frame.wasmFunctionIndex != null) {
      return 'wasm:${frame.wasmFunctionIndex}';
    }
    return '${walked.meaningfulUrl}#${walked.meaningfulKey}';
  }

  _StackWalkResult _walkCallStack(int leafNodeId) {
    int? currentNodeId = leafNodeId;
    CpuProfileNode? meaningfulNode;
    var meaningfulKey = '';
    var meaningfulUrl = '';
    final stackNames = <String>[];
    String? targetUrl;

    while (currentNodeId != null) {
      final node = nodeMap[currentNodeId];
      if (node == null) break;

      final frame = node.callFrame;
      final key = frame.functionName;
      final url = normalizeLocation(frame.url);

      stackNames.add(key);
      targetUrl ??= url;

      if (!expandCanvaskitFrames && _isEngineWasmUrl(url)) {
        meaningfulNode = node;
        meaningfulKey = 'CanvasKit Wasm (collapsed)';
        meaningfulUrl = url;
      } else if (meaningfulNode == null &&
          !_isInternalOrInterop(node) &&
          key.isNotEmpty) {
        meaningfulNode = node;
        meaningfulKey = key;
        meaningfulUrl = url;
      }

      currentNodeId = parentMap[currentNodeId];
    }

    return _StackWalkResult(
      meaningfulNode: meaningfulNode,
      meaningfulKey: meaningfulKey,
      meaningfulUrl: meaningfulUrl,
      stackNames: stackNames,
      targetUrl: targetUrl,
    );
  }

  bool _isInternalOrInterop(CpuProfileNode node) {
    final frame = node.callFrame;
    final url = frame.url;
    if (url.isEmpty || url.endsWith('.mjs') || url.endsWith('.js')) {
      return true;
    }
    if (url.startsWith('dart:developer') || url.startsWith('dart:_')) {
      return true;
    }
    return frame.functionName.startsWith('wasm-function[') &&
        frame.wasmFunctionIndex == null;
  }

  bool _isEngineWasmUrl(String url) =>
      url.contains('canvaskit.wasm') || url.contains('skwasm.wasm');

  PerformanceCategory _classifyStackPhase(
    List<String> stackNames,
    String? targetUrl,
  ) {
    for (final name in stackNames) {
      final matched = _phaseForFrameName(name);
      if (matched != null) return matched;
    }
    if (targetUrl != null && _isEngineWasmUrl(targetUrl)) {
      return PerformanceCategory.engineRaster;
    }
    return PerformanceCategory.other;
  }

  PerformanceCategory? _phaseForFrameName(String name) {
    if (name.contains('buildScope') ||
        name.contains('rebuild') ||
        name.contains('performRebuild')) {
      return PerformanceCategory.flutterBuild;
    }
    if (name.contains('performLayout') ||
        name.contains('flushLayout') ||
        name.contains('.layout')) {
      return PerformanceCategory.flutterLayout;
    }
    if (name.contains('paintChild') ||
        name.contains('flushPaint') ||
        name.contains('.paint')) {
      return PerformanceCategory.flutterPaint;
    }
    if (name.contains('addToScene') || name.contains('flushCompositing')) {
      return PerformanceCategory.flutterCompositing;
    }
    return null;
  }

  List<HotFunction> buildTopHotFunctions(int totalSamples) {
    final sortedFunctions = exclusiveFunctionCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return [
      for (var i = 0; i < 10 && i < sortedFunctions.length; i++)
        _buildHotFunction(sortedFunctions[i], totalSamples),
    ];
  }

  HotFunction _buildHotFunction(MapEntry<String, int> entry, int totalSamples) {
    final bucketKey = entry.key;
    final name = functionNames[bucketKey] ?? bucketKey;
    final samplesCount = entry.value;
    final lineMap = functionLineCounts[bucketKey];
    final hottestLine = (lineMap != null && lineMap.isNotEmpty)
        ? lineMap.entries.reduce((a, b) => a.value > b.value ? a : b).key
        : null;

    final phaseMap = functionPhaseCounts[bucketKey];
    var dominantPhase = (phaseMap != null && phaseMap.isNotEmpty)
        ? phaseMap.entries.reduce((a, b) => a.value > b.value ? a : b).key
        : PerformanceCategory.other;

    if (dominantPhase == PerformanceCategory.other) {
      dominantPhase = name.contains('CanvasKit Wasm')
          ? PerformanceCategory.engineRaster
          : PerformanceCategory.jsScripting;
    }

    return HotFunction(
      name: name,
      url: functionUrls[bucketKey] ?? '',
      samples: samplesCount,
      percent: totalSamples > 0 ? (samplesCount / totalSamples) * 100 : 0.0,
      category: dominantPhase,
      lineNumber: hottestLine,
      columnNumber: null,
      wasmFunctionIndex: functionWasmIndices[bucketKey],
    );
  }
}

class _StackWalkResult {
  final CpuProfileNode? meaningfulNode;
  final String meaningfulKey;
  final String meaningfulUrl;
  final List<String> stackNames;
  final String? targetUrl;

  _StackWalkResult({
    required this.meaningfulNode,
    required this.meaningfulKey,
    required this.meaningfulUrl,
    required this.stackNames,
    required this.targetUrl,
  });
}
