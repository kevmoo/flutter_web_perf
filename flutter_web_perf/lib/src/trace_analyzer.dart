import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'profile_model.dart';

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

  Future<void> analyze({String? traceProcessorPath}) async {
    final tpPath = traceProcessorPath ?? defaultTraceProcessorPath;
    final tpFile = File(tpPath);
    if (!await tpFile.exists()) {
      print('Trace Processor not found at: $tpPath');
      print('Skipping advanced analysis.');
      return;
    }

    print('Analyzing trace using Trace Processor...');

    // Query for Frame Health
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

    // Query for Advanced Metrics (Breakdown)
    final breakdownQuery = '''
      SELECT 
        CASE 
          WHEN name LIKE '%Script::Execute%' THEN 'Scripting'
          WHEN name LIKE '%Render%' THEN 'Rendering'
          WHEN name LIKE '%GC%' OR cat LIKE '%gc%' THEN 'GC'
          ELSE 'Other'
        END AS category,
        SUM(dur) / 1000000.0 AS total_dur_ms
      FROM slice
      WHERE name LIKE '%Script::Execute%' OR name LIKE '%Render%' OR name LIKE '%GC%' OR cat LIKE '%gc%'
      GROUP BY category;
    ''';

    final tempDir = await Directory.systemTemp.createTemp('query_');
    final qFile = File(p.join(tempDir.path, 'query.sql'));

    try {
      // Run frame health query
      await qFile.writeAsString(frameHealthQuery);
      final result = await Process.run(tpPath, [tracePath, '-q', qFile.path]);

      if (result.exitCode != 0) {
        print('Failed to run Trace Processor: ${result.stderr}');
        return;
      }

      print('\n=== Frame Health (via Trace Processor) ===');
      var lines = result.stdout.toString().split('\n');
      for (final line in lines) {
        if (line.startsWith('"') || line.contains(',')) {
          print(line);
        }
      }

      // Run breakdown query
      await qFile.writeAsString(breakdownQuery);
      final result2 = await Process.run(tpPath, [tracePath, '-q', qFile.path]);

      if (result2.exitCode != 0) {
        print('Failed to run Trace Processor for breakdown: ${result2.stderr}');
        return;
      }

      print('\n=== Time Breakdown (via Trace Processor) ===');
      lines = result2.stdout.toString().split('\n');
      for (final line in lines) {
        if (line.startsWith('"') || line.contains(',')) {
          print(line);
        }
      }
    } finally {
      await tempDir.delete(recursive: true);
    }
  }

  Future<void> analyzeProfile(String profilePath) async {
    final file = File(profilePath);
    if (!await file.exists()) {
      print('Profile file not found: $profilePath');
      return;
    }

    final content = await file.readAsString();
    final profile = CpuProfile.fromJson(
      json.decode(content) as Map<String, dynamic>,
    );

    final nodeCounts = <int, int>{};
    for (final sample in profile.samples) {
      nodeCounts[sample] = (nodeCounts[sample] ?? 0) + 1;
    }

    // Map node ID to node object for easy lookup
    final nodeMap = <int, CpuProfileNode>{};
    for (final node in profile.nodes) {
      nodeMap[node.id] = node;
    }

    // Aggregate by function name
    final functionCounts = <String, int>{};
    nodeCounts.forEach((nodeId, count) {
      final node = nodeMap[nodeId];
      if (node != null) {
        final frame = node.callFrame;
        final functionName = frame.functionName;
        final url = frame.url;

        var key = '$functionName ($url)';
        // TODO: be exhaustive about the canvaskit variants here.
        // We have skwasm, etc etc
        if (!expandCanvaskitFrames &&
            (url.contains('canvaskit.wasm') || url.contains('skwasm.wasm'))) {
          key = 'CanvasKit Wasm (collapsed)';
        }

        functionCounts[key] = (functionCounts[key] ?? 0) + count;
      }
    });

    final sortedFunctions = functionCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    print('\n=== Top 10 Hot Functions (from Profile) ===');
    for (var i = 0; i < 10 && i < sortedFunctions.length; i++) {
      final entry = sortedFunctions[i];
      print('${i + 1}. ${entry.key}: ${entry.value} samples');
    }
  }
}
