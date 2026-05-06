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

    // Prepare data for template (Exclusive Platform Allocations)
    final mutableBreakdown = Map<PerformanceCategory, double>.from(
      report.timeBreakdown,
    );
    final jsScripting =
        mutableBreakdown[PerformanceCategory.jsScripting] ?? 0.0;
    final buildTime = mutableBreakdown[PerformanceCategory.flutterBuild] ?? 0.0;
    final layoutTime =
        mutableBreakdown[PerformanceCategory.flutterLayout] ?? 0.0;
    final paintTime = mutableBreakdown[PerformanceCategory.flutterPaint] ?? 0.0;

    // Subtract children framework times to get true exclusive platform
    // scripting
    final exclusiveJs = (jsScripting - (buildTime + layoutTime + paintTime))
        .clamp(0.0, double.infinity);
    mutableBreakdown[PerformanceCategory.jsScripting] = exclusiveJs;

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
      final category = e.key;
      final duration = e.value;
      final percent = totalDur > 0 ? (duration / totalDur) * 100 : 0.0;
      final displayWidth = chartScale > 0 ? (percent / chartScale) * 100 : 0.0;

      // Overlay text inside the bar only if it is wide enough
      // (>= 12% of chart scale)
      final hasPercentVal = percent >= (chartScale * 0.12);

      final label = category == PerformanceCategory.jsScripting
          ? 'JS Scripting (other)'
          : category.label;

      return {
        'category': label,
        'percent': percent.toStringAsFixed(1),
        'displayWidth': displayWidth.toStringAsFixed(1),
        'hasPercentVal': hasPercentVal,
        'durationMs': duration.toStringAsFixed(1),
      };
    }).toList();

    final hotFunctionsData = <Map>[];
    for (var i = 0; i < report.hotFunctions.length; i++) {
      final f = report.hotFunctions[i];

      List<Map>? wasmLines;
      if (f.wasmInstructions != null) {
        final lines = const LineSplitter().convert(f.wasmInstructions!);
        wasmLines = [];
        for (var lineIdx = 0; lineIdx < lines.length; lineIdx++) {
          final lineText = lines[lineIdx];
          wasmLines.add({
            'number': lineIdx + 1,
            'text': lineText,
            'isBad': _isLineBad(lineText),
          });
        }
      }

      List<Map>? wasmUnoptLines;
      if (f.wasmInstructionsUnoptimized != null) {
        final lines = const LineSplitter().convert(
          f.wasmInstructionsUnoptimized!,
        );
        wasmUnoptLines = [];
        for (var lineIdx = 0; lineIdx < lines.length; lineIdx++) {
          final lineText = lines[lineIdx];
          wasmUnoptLines.add({
            'number': lineIdx + 1,
            'text': lineText,
            'isBad': _isLineBad(lineText),
          });
        }
      }

      Map? wasmAnalysisData;
      if (f.wasmAnalysis != null) {
        wasmAnalysisData = {
          'totalInstructions': f.wasmAnalysis!.totalInstructions,
          'allocationCount': f.wasmAnalysis!.allocationCount,
          'typeCheckCount': f.wasmAnalysis!.typeCheckCount,
          'hasAllocationCount': f.wasmAnalysis!.allocationCount > 0,
          'hasTypeCheckCount': f.wasmAnalysis!.typeCheckCount > 0,
          'hasWarnings':
              f.wasmAnalysis!.allocationCount > 0 ||
              f.wasmAnalysis!.typeCheckCount > 0,
        };
      }

      Map? wasmUnoptAnalysisData;
      if (f.wasmAnalysisUnoptimized != null) {
        wasmUnoptAnalysisData = {
          'totalInstructions': f.wasmAnalysisUnoptimized!.totalInstructions,
          'allocationCount': f.wasmAnalysisUnoptimized!.allocationCount,
          'typeCheckCount': f.wasmAnalysisUnoptimized!.typeCheckCount,
          'hasAllocationCount': f.wasmAnalysisUnoptimized!.allocationCount > 0,
          'hasTypeCheckCount': f.wasmAnalysisUnoptimized!.typeCheckCount > 0,
          'hasWarnings':
              f.wasmAnalysisUnoptimized!.allocationCount > 0 ||
              f.wasmAnalysisUnoptimized!.typeCheckCount > 0,
        };
      }

      hotFunctionsData.add({
        'index': i + 1,
        'name': f.name,
        'url': f.url,
        'samples': f.samples,
        'percent': f.percent.toStringAsFixed(1),
        'estimatedMs': f.samples,
        'tagClass': f.category.name,
        'tagText': f.category.shortLabel,
        'hasWasm': wasmLines != null,
        'wasmLines': wasmLines,
        'hasWasmUnopt': wasmUnoptLines != null,
        'wasmUnoptLines': wasmUnoptLines,
        'wasmAnalysis': wasmAnalysisData,
        'hasWasmAnalysis': wasmAnalysisData != null,
        'wasmUnoptAnalysis': wasmUnoptAnalysisData,
        'hasWasmUnoptAnalysis': wasmUnoptAnalysisData != null,
        'allocationsText': f.allocationsBytes != null
            ? _formatBytes(f.allocationsBytes!)
            : null,
        'hasAllocations': f.allocationsBytes != null && f.allocationsBytes! > 0,
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
        'totalAllocatedText': report.frameHealth.totalAllocatedBytes != null
            ? _formatBytes(report.frameHealth.totalAllocatedBytes!)
            : 'N/A',
        'hasAllocatedBytes':
            report.frameHealth.totalAllocatedBytes != null &&
            report.frameHealth.totalAllocatedBytes! > 0,
      },
      'timeBreakdown': timeBreakdownData,
      'chartScale': chartScale.toStringAsFixed(0),
      'hotFunctions': hotFunctionsData,
    };

    return template.renderString(data);
  }

  bool _isLineBad(String lineText) {
    var cleaned = lineText.trim();
    while (cleaned.startsWith('(')) {
      cleaned = cleaned.substring(1).trim();
    }
    final match = RegExp(r'^[a-z0-9_]+(?:\.[a-z0-9_]+)*').firstMatch(cleaned);
    if (match != null) {
      final opcode = match.group(0)!;
      return wasmAllocationOpcodes.contains(opcode) ||
          wasmTypeCheckOpcodes.contains(opcode);
    }
    return false;
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    var i = 0;
    var val = bytes.toDouble();
    while (val >= 1024 && i < suffixes.length - 1) {
      val /= 1024;
      i++;
    }
    return '${val.toStringAsFixed(i == 0 ? 0 : 1)} ${suffixes[i]}';
  }

  Future<void> saveReport(PerformanceReport report, String path) async {
    final html = generate(report);
    final file = File(path);
    await file.writeAsString(html);
    print('Saved HTML report to ${file.absolute.path}');
  }
}
