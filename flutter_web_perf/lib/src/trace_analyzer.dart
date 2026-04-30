import 'dart:convert';
import 'dart:io';
import 'package:source_maps/source_maps.dart';

class TraceAnalyzer {
  final String tracePath;
  final String? sourceMapPath;

  TraceAnalyzer(this.tracePath, {this.sourceMapPath});

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
  }
}
