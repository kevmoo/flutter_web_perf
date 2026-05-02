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

    final nodeMap = <int, CpuProfileNode>{};
    final parentMap = <int, int>{};

    for (final node in profile.nodes) {
      nodeMap[node.id] = node;
      for (final childId in node.children) {
        parentMap[childId] = node.id;
      }
    }

    final inclusiveFunctionCounts = <String, int>{};
    final functionUrls = <String, String>{};

    for (final leafNodeId in profile.samples) {
      var currentNodeId = leafNodeId;
      final seenFunctionsInStack = <String>{};

      while (currentNodeId != null) {
        final node = nodeMap[currentNodeId];
        if (node == null) break;

        final frame = node.callFrame;
        final functionName = frame.functionName;
        final url = normalizeLocation(frame.url);

        var key = functionName;
        if (!expandCanvaskitFrames &&
            (url.contains('canvaskit.wasm') || url.contains('skwasm.wasm'))) {
          key = 'CanvasKit Wasm (collapsed)';
        }

        if (key.isNotEmpty &&
            key != '(root)' &&
            key != '(program)' &&
            key != '(idle)' &&
            key != '(garbage collector)' &&
            !key.startsWith('js-to-wasm') &&
            !key.startsWith('wasm-to-js') &&
            key.length > 2) {
          if (seenFunctionsInStack.add(key)) {
            inclusiveFunctionCounts[key] =
                (inclusiveFunctionCounts[key] ?? 0) + 1;
            functionUrls[key] = url;
          }
        }

        currentNodeId = parentMap[currentNodeId] ?? -1;
        if (currentNodeId == -1) break;
      }
    }

    final sortedFunctions = inclusiveFunctionCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final hotFunctions = <HotFunction>[];
    for (var i = 0; i < 10 && i < sortedFunctions.length; i++) {
      final entry = sortedFunctions[i];
      hotFunctions.add(
        HotFunction(
          name: entry.key,
          url: functionUrls[entry.key] ?? '',
          samples: entry.value,
        ),
      );
    }

    return PerformanceReport(
      frameHealth: frameHealth,
      timeBreakdown: breakdown,
      slowTasks: [], // TODO: Add slow tasks query if needed
      hotFunctions: hotFunctions,
    );
  }
}
