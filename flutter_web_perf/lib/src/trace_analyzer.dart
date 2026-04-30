import 'dart:convert';
import 'dart:io';
import 'package:source_maps/source_maps.dart';

class TraceAnalyzer {
  final String tracePath;
  final String? sourceMapPath;
  final bool expandCanvaskitFrames;

  TraceAnalyzer(
    this.tracePath, {
    this.sourceMapPath,
    this.expandCanvaskitFrames = false,
  });

  Future<void> analyze() async {
    final file = File(tracePath);
    if (!await file.exists()) {
      print('Trace file not found: $tracePath');
      return;
    }

    final content = await file.readAsString();
    final events = json.decode(content) as List;
    print('Loaded ${events.length} events.');

    SingleMapping? mapping;
    if (sourceMapPath != null) {
      final mapFile = File(sourceMapPath!);
      if (await mapFile.exists()) {
        final mapContent = await mapFile.readAsString();
        mapping = parse(mapContent) as SingleMapping;
        print('Loaded source map: $sourceMapPath');
      } else {
        print('Source map file not found: $sourceMapPath');
      }
    }

    // 1. Frame Health
    final beginFrames = events
        .where((e) => e['name'] == 'Scheduler::BeginFrame')
        .toList();
    final animationFrames = events
        .where((e) => e['name'] == 'AnimationFrame')
        .toList();

    print('\n=== Frame Health ===');
    print('Requested Frames (BeginFrame): ${beginFrames.length}');
    print('Processed Frames (AnimationFrame): ${animationFrames.length}');

    if (beginFrames.isNotEmpty) {
      beginFrames.sort((a, b) => (a['ts'] as num).compareTo(b['ts'] as num));
      var totalInterval = 0.0;
      var intervalCount = 0;
      for (var i = 0; i < beginFrames.length - 1; i++) {
        final current = beginFrames[i]['ts'] as num;
        final next = beginFrames[i + 1]['ts'] as num;
        totalInterval += (next - current);
        intervalCount++;
      }
      final avgIntervalMs = intervalCount > 0
          ? (totalInterval / intervalCount) / 1000.0
          : 0.0;
      print('Average Frame Interval: ${avgIntervalMs.toStringAsFixed(2)} ms');
    }

    if (animationFrames.isNotEmpty) {
      final totalDur = animationFrames
          .map((e) => e['dur'] as num? ?? 0)
          .reduce((a, b) => a + b);
      final avgDurMs = (totalDur / animationFrames.length) / 1000.0;
      print('Average Frame Work Duration: ${avgDurMs.toStringAsFixed(2)} ms');
    }

    final dropRate = beginFrames.isNotEmpty
        ? (1 - (animationFrames.length / beginFrames.length)) * 100
        : 0.0;
    print('Estimated Frame Drop Rate: ${dropRate.toStringAsFixed(2)}%');

    // 2. Task Breakdown
    final slowTasks = events.where((e) {
      final dur = e['dur'];
      return dur != null && dur > 16666; // > 16.6ms
    }).toList();

    print('\n=== Task Breakdown ===');
    print('Slow Tasks (>16.6ms): ${slowTasks.length}');

    // Sum GC overhead
    final gcEvents = events.where((e) {
      final name = e['name'] as String?;
      final cat = e['cat'] as String?;
      return (name != null && name.contains('GC')) ||
          (cat != null && cat.contains('gc'));
    }).toList();

    final totalGcDur = gcEvents.isNotEmpty
        ? gcEvents.map((e) => e['dur'] as num? ?? 0).reduce((a, b) => a + b)
        : 0;
    print(
      'Total GC Overhead: ${(totalGcDur / 1000.0).toStringAsFixed(2)} ms (${gcEvents.length} events)',
    );

    // 3. Symbolication & Attribution
    // Sort slow tasks by duration
    slowTasks.sort((a, b) => (b['dur'] as num).compareTo(a['dur'] as num));

    print('\n=== Top 5 Slowest Tasks ===');
    for (var i = 0; i < 5 && i < slowTasks.length; i++) {
      final t = slowTasks[i];
      final name = t['name'];
      final dur = t['dur'];
      final cat = t['cat'];

      print(
        'Task: $name, Duration: ${(dur / 1000.0).toStringAsFixed(2)} ms, Category: $cat',
      );

      // Try to symbolicate
      final args = t['args'];
      if (args != null && args['data'] != null) {
        final data = args['data'] as Map<String, dynamic>;
        final line = data['lineNumber'] as int?;
        final column = data['columnNumber'] as int?;

        if (line != null && column != null && mapping != null) {
          final span = mapping.spanFor(line, column);
          if (span != null) {
            print(
              '  -> Original: ${span.sourceUrl}:${span.start.line + 1}:${span.start.column + 1}',
            );
            if (span.isIdentifier) {
              print('  -> Identifier: ${span.text}');
            }
          }
        }
      }
    }

    // 4. Search for package: URIs in all events
    print('\n=== Non-SDK Mapped Locations (First 20) ===');
    var printedCount = 0;
    final seenUrls = <String>{};

    for (final e in events) {
      final args = e['args'];
      if (args != null && args['data'] != null) {
        final data = args['data'] as Map<String, dynamic>;
        final line = data['lineNumber'] as int?;
        final column = data['columnNumber'] as int?;

        if (line != null && column != null && mapping != null) {
          final span = mapping.spanFor(line, column);
          if (span != null) {
            final url = span.sourceUrl.toString();
            if (!url.contains('org-dartlang-sdk:///')) {
              if (seenUrls.add(url)) {
                print('  -> $url');
                printedCount++;
                if (printedCount >= 20) break;
              }
            }
          }
        }
      }
    }
  }

  Future<void> analyzeProfile(String profilePath) async {
    final file = File(profilePath);
    if (!await file.exists()) {
      print('Profile file not found: $profilePath');
      return;
    }

    final content = await file.readAsString();
    final profile = json.decode(content) as Map<String, dynamic>;

    final nodes = profile['nodes'] as List;
    final samples = profile['samples'] as List;

    final nodeCounts = <int, int>{};
    for (final sample in samples) {
      final nodeId = sample as int;
      nodeCounts[nodeId] = (nodeCounts[nodeId] ?? 0) + 1;
    }

    // Map node ID to node object for easy lookup
    final nodeMap = <int, Map<String, dynamic>>{};
    for (final node in nodes) {
      final id = node['id'] as int;
      nodeMap[id] = node as Map<String, dynamic>;
    }

    // Aggregate by function name
    final functionCounts = <String, int>{};
    nodeCounts.forEach((nodeId, count) {
      final node = nodeMap[nodeId];
      if (node != null) {
        final callFrame = node['callFrame'] as Map<String, dynamic>;
        final functionName = callFrame['functionName'] as String;
        final url = callFrame['url'] as String;

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
