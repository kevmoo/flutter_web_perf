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

  static const String defaultTraceProcessorPath =
      '/Users/kevmoo/github/perfetto/out/default/trace_processor_shell';

  Future<PerformanceReport> generateReport({
    String? traceProcessorPath,
    required String profilePath,
  }) async {
    final tpPath = traceProcessorPath ?? defaultTraceProcessorPath;
    final tpFile = File(tpPath);
    if (!await tpFile.exists()) {
      throw Exception('Trace Processor not found at: $tpPath');
    }

    print('Analyzing trace using Trace Processor...');

    final frameHealthQuery = '''
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

    final breakdownQuery = '''
      SELECT
        CASE
          WHEN name = 'BUILD' OR name = 'Build' OR name LIKE 'BuildOwner%' THEN 'Flutter Build'
          WHEN name = 'LAYOUT' OR name = 'Layout' OR name LIKE 'LAYOUT%' OR name LIKE 'RenderObject.performLayout%' THEN 'Flutter Layout'
          WHEN name = 'PAINT' OR name = 'Paint' OR name LIKE 'PAINT%' OR name LIKE 'RenderObject.paint%' THEN 'Flutter Paint'
          WHEN name = 'COMPOSITING' THEN 'Flutter Compositing'
          WHEN name = 'Semantics' THEN 'Flutter Semantics'
          WHEN name LIKE 'Raster%' THEN 'Engine Raster'
          WHEN name LIKE '%Script::Execute%' THEN 'JS Scripting'
          WHEN name LIKE '%Render%' THEN 'Browser Rendering'
          WHEN name LIKE '%GC%' OR cat LIKE '%gc%' THEN 'GC'
          ELSE 'Other'
        END AS category,
        SUM(dur) / 1000000.0 AS total_dur_ms
      FROM slice
      WHERE name LIKE '%Script::Execute%'
         OR name LIKE '%Render%'
         OR name LIKE '%GC%'
         OR cat LIKE '%gc%'
         OR name = 'BUILD'
         OR name = 'Build'
         OR name LIKE 'BuildOwner%'
         OR name = 'LAYOUT'
         OR name = 'Layout'
         OR name LIKE 'LAYOUT%'
         OR name LIKE 'RenderObject.performLayout%'
         OR name = 'PAINT'
         OR name = 'Paint'
         OR name LIKE 'PAINT%'
         OR name LIKE 'RenderObject.paint%'
         OR name = 'COMPOSITING'
         OR name = 'Semantics'
         OR name LIKE 'Raster%'
      GROUP BY 1;
    ''';

    final tempDir = await Directory.systemTemp.createTemp('query_');
    final qFile = File(p.join(tempDir.path, 'query.sql'));

    FrameHealth? frameHealth;
    final breakdown = <String, double>{};

    try {
      // 1. Run frame health query
      await qFile.writeAsString(frameHealthQuery);
      final result = await Process.run(tpPath, [tracePath, '-q', qFile.path]);

      if (result.exitCode != 0) {
        throw Exception('Failed to run Trace Processor: ${result.stderr}');
      }

      final lines = result.stdout.toString().split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].startsWith('"avg_interval_ms"')) {
          if (i + 1 < lines.length) {
            final data = lines[i + 1].split(',');
            frameHealth = FrameHealth(
              avgIntervalMs: double.tryParse(data[0]),
              avgWorkMs: double.tryParse(data[1]),
              requestedCount: int.tryParse(data[2]) ?? 0,
              processedCount: int.tryParse(data[3]) ?? 0,
            );
          }
          break;
        }
      }

      // 2. Run breakdown query
      await qFile.writeAsString(breakdownQuery);
      final result2 = await Process.run(tpPath, [tracePath, '-q', qFile.path]);

      if (result2.exitCode != 0) {
        throw Exception(
          'Failed to run Trace Processor for breakdown: ${result2.stderr}',
        );
      }

      final lines2 = result2.stdout.toString().split('\n');
      for (var i = 0; i < lines2.length; i++) {
        if (lines2[i].startsWith('"category"')) {
          for (var j = i + 1; j < lines2.length; j++) {
            final line = lines2[j];
            if (line.isEmpty) continue;
            final data = line.split(',');
            if (data.length == 2) {
              final cat = data[0].replaceAll('"', '');
              final dur = double.tryParse(data[1]) ?? 0.0;
              breakdown[cat] = dur;
            }
          }
          break;
        }
      }
    } finally {
      await tempDir.delete(recursive: true);
    }

    if (frameHealth == null) {
      throw Exception('Failed to parse frame health data from Trace Processor');
    }

    // 3. Analyze Profile
    final profileFile = File(profilePath);
    if (!await profileFile.exists()) {
      throw Exception('Profile file not found: $profilePath');
    }

    final content = await profileFile.readAsString();
    final profile = CpuProfile.fromJson(
      json.decode(content) as Map<String, dynamic>,
    );

    final hotFunctions = processProfile(profile);

    return PerformanceReport(
      frameHealth: frameHealth,
      timeBreakdown: breakdown,
      slowTasks: [], // TODO: Add slow tasks query if needed
      hotFunctions: hotFunctions,
    );
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

    final exclusiveFunctionCounts = <String, int>{};
    final functionUrls = <String, String>{};
    final functionLineCounts = <String, Map<int, int>>{};
    final functionWasmIndices = <String, int?>{};

    bool isInternalOrInterop(CpuProfileNode node) {
      final frame = node.callFrame;
      final url = frame.url;
      final name = frame.functionName;

      // 1. V8 Internals and generic engine frames often have empty URLs or
      // are explicitly named.
      if (url.isEmpty) {
        return true;
      }

      // 2. JS Interop wrappers in Wasm builds. These are minified (e.g. gD, hD)
      // and represent the boundary between Dart and the Browser DOM/APIs.
      // We want to collapse these so the sample is attributed to the Dart code
      // that initiated the interop.
      if (url.endsWith('.mjs') || url.endsWith('.js')) {
        return true;
      }

      // 3. Dart infrastructure that we want to collapse to see the actual user/framework work.
      if (url.startsWith('dart:developer') || url.startsWith('dart:_')) {
        return true;
      }

      // 4. Raw wasm functions (unmapped trampolines).
      if (name.startsWith('wasm-function[') &&
          frame.wasmFunctionIndex == null) {
        return true;
      }

      // We no longer use a massive list of magic strings.
      // If it's a Dart frame (has a dart:, package:, or .wasm URL), we keep it!
      return false;
    }

    for (final leafNodeId in profile.samples) {
      int? currentNodeId = leafNodeId;
      CpuProfileNode? meaningfulNode;
      var meaningfulKey = '';
      var meaningfulUrl = '';

      while (currentNodeId != null) {
        final node = nodeMap[currentNodeId];
        if (node == null) break;

        final frame = node.callFrame;
        final key = frame.functionName;
        final url = normalizeLocation(frame.url);

        // Check if we should collapse CanvasKit
        if (!expandCanvaskitFrames &&
            (url.contains('canvaskit.wasm') || url.contains('skwasm.wasm'))) {
          meaningfulNode = node;
          meaningfulKey = 'CanvasKit Wasm (collapsed)';
          meaningfulUrl = url;
          break;
        }

        // If it's not an internal/interop frame, we've found our true caller!
        if (!isInternalOrInterop(node)) {
          // One final check: if the name is empty, we probably shouldn't
          // use it.
          if (key.isNotEmpty) {
            meaningfulNode = node;
            meaningfulKey = key;
            meaningfulUrl = url;
            break;
          }
        }

        // Walk up the call stack
        currentNodeId = parentMap[currentNodeId];
      }

      if (meaningfulNode != null) {
        final frame = meaningfulNode.callFrame;
        exclusiveFunctionCounts[meaningfulKey] =
            (exclusiveFunctionCounts[meaningfulKey] ?? 0) + 1;
        functionUrls[meaningfulKey] = meaningfulUrl;

        final lineNumber = frame.lineNumber;
        if (lineNumber != null && lineNumber >= 0) {
          final lineMap = functionLineCounts.putIfAbsent(
            meaningfulKey,
            () => <int, int>{},
          );
          lineMap[lineNumber] = (lineMap[lineNumber] ?? 0) + 1;
        }

        if (frame.wasmFunctionIndex != null) {
          functionWasmIndices[meaningfulKey] = frame.wasmFunctionIndex;
        }
      }
    }

    final totalSamples = profile.samples.length;

    final sortedFunctions = exclusiveFunctionCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final hotFunctions = <HotFunction>[];
    for (var i = 0; i < 10 && i < sortedFunctions.length; i++) {
      final entry = sortedFunctions[i];
      final lineMap = functionLineCounts[entry.key];
      int? hottestLine;
      if (lineMap != null && lineMap.isNotEmpty) {
        hottestLine = lineMap.entries
            .reduce((a, b) => a.value > b.value ? a : b)
            .key;
      }

      final samplesCount = entry.value;
      final percent = totalSamples > 0
          ? (samplesCount / totalSamples) * 100
          : 0.0;

      hotFunctions.add(
        HotFunction(
          name: entry.key,
          url: functionUrls[entry.key] ?? '',
          samples: samplesCount,
          percent: percent,
          lineNumber: hottestLine,
          // Column numbers are generally useless for human-readable output
          columnNumber: null,
          wasmFunctionIndex: functionWasmIndices[entry.key],
        ),
      );
    }

    return hotFunctions;
  }
}
