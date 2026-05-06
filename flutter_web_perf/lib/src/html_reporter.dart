import 'dart:convert';
import 'dart:io';
import 'package:mustache_template/mustache_template.dart';
import 'performance_report.dart';
import 'resources/report_template.dart';

class HtmlReporter {
  String generate(PerformanceReport report) {
    final templateBytes = base64.decode(reportTemplateBase64);
    final templateString = utf8.decode(templateBytes);
    final template = Template(templateString, name: 'report.mustache');

    // Prepare data for template (Concept 1 & 3: Scaled Platform Allocations)
    final mutableBreakdown = Map<String, double>.from(report.timeBreakdown);
    final jsScripting = mutableBreakdown['JS Scripting'] ?? 0.0;
    final buildTime = mutableBreakdown['Flutter Build'] ?? 0.0;
    final layoutTime = mutableBreakdown['Flutter Layout'] ?? 0.0;
    final paintTime = mutableBreakdown['Flutter Paint'] ?? 0.0;

    // Subtract children framework times to get true exclusive platform
    // scripting
    final exclusiveJs = (jsScripting - (buildTime + layoutTime + paintTime))
        .clamp(0.0, double.infinity);
    mutableBreakdown['JS Scripting'] = exclusiveJs;

    final totalDur = mutableBreakdown.values.isEmpty
        ? 1.0
        : mutableBreakdown.values.reduce((a, b) => a + b);

    // 1. Find maximum percentage in the categories
    var maxPct = 0.0;
    for (final entry in mutableBreakdown.entries) {
      final pct = totalDur > 0 ? (entry.value / totalDur) * 100 : 0.0;
      if (pct > maxPct) maxPct = pct;
    }

    // 2. Round up to the next 10% increment (minimum 10%, maximum 100%)
    var chartScale = 10.0;
    if (maxPct > 0.0) {
      chartScale = (maxPct / 10.0).ceil() * 10.0;
    }
    if (chartScale > 100.0) chartScale = 100.0;

    final timeBreakdownData = mutableBreakdown.entries.map((e) {
      final duration = e.value;
      final percent = totalDur > 0 ? (duration / totalDur) * 100 : 0.0;
      final displayWidth = chartScale > 0 ? (percent / chartScale) * 100 : 0.0;

      // Overlay text inside the bar only if it is wide enough
      // (>= 12% of chart scale)
      final hasPercentVal = percent >= (chartScale * 0.12);

      return {
        'category': e.key == 'JS Scripting' ? 'JS Scripting (other)' : e.key,
        'percent': percent.toStringAsFixed(1),
        'displayWidth': displayWidth.toStringAsFixed(1),
        'hasPercentVal': hasPercentVal,
        'durationMs': duration.toStringAsFixed(1),
      };
    }).toList();

    final hotFunctionsData = <Map>[];
    for (var i = 0; i < report.hotFunctions.length; i++) {
      final f = report.hotFunctions[i];
      final isSdk = f.url.contains('org-dartlang-sdk:///');

      List<Map>? wasmLines;
      if (f.wasmInstructions != null) {
        final lines = const LineSplitter().convert(f.wasmInstructions!);
        wasmLines = [];
        for (var lineIdx = 0; lineIdx < lines.length; lineIdx++) {
          wasmLines.add({'number': lineIdx + 1, 'text': lines[lineIdx]});
        }
      }

      List<Map>? wasmUnoptLines;
      if (f.wasmInstructionsUnoptimized != null) {
        final lines = const LineSplitter().convert(
          f.wasmInstructionsUnoptimized!,
        );
        wasmUnoptLines = [];
        for (var lineIdx = 0; lineIdx < lines.length; lineIdx++) {
          wasmUnoptLines.add({'number': lineIdx + 1, 'text': lines[lineIdx]});
        }
      }

      hotFunctionsData.add({
        'index': i + 1,
        'name': f.name,
        'url': f.url,
        'samples': f.samples,
        'percent': f.percent.toStringAsFixed(1),
        'estimatedMs': f.samples,
        'tagClass': isSdk ? 'tag sdk' : 'tag',
        'tagText': isSdk ? 'SDK' : 'App',
        'hasWasm': wasmLines != null,
        'wasmLines': wasmLines,
        'hasWasmUnopt': wasmUnoptLines != null,
        'wasmUnoptLines': wasmUnoptLines,
        'githubUrl': f.githubUrl,
        'hasGithubUrl': f.githubUrl != null && f.githubUrl!.isNotEmpty,
      });
    }

    final data = {
      'frameHealth': {
        'avgIntervalMs':
            report.frameHealth.avgIntervalMs?.toStringAsFixed(2) ?? 'N/A',
        'avgWorkMs': report.frameHealth.avgWorkMs?.toStringAsFixed(2) ?? 'N/A',
        'dropRate': report.frameHealth.dropRate.toStringAsFixed(2),
        'requestedCount': report.frameHealth.requestedCount,
        'processedCount': report.frameHealth.processedCount,
      },
      'timeBreakdown': timeBreakdownData,
      'chartScale': chartScale.toStringAsFixed(0),
      'hotFunctions': hotFunctionsData,
    };

    return template.renderString(data);
  }

  Future<void> saveReport(PerformanceReport report, String path) async {
    final html = generate(report);
    final file = File(path);
    await file.writeAsString(html);
    print('Saved HTML report to ${file.absolute.path}');
  }
}
