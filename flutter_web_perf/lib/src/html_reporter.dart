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

    // Prepare data for template
    final maxDur = report.timeBreakdown.values.fold(
      0.0,
      (a, b) => a > b ? a : b,
    );

    final timeBreakdownData = report.timeBreakdown.entries.map((e) {
      final duration = e.value;
      final percent = maxDur > 0 ? (duration / maxDur) * 100 : 0;
      return {
        'category': e.key,
        'percent': percent.toStringAsFixed(2),
        'durationMs': duration.toStringAsFixed(2),
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
