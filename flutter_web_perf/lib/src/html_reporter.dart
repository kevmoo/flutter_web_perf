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

    final mutableBreakdown = _computeExclusiveBreakdown(report.timeBreakdown);
    final totalDur = mutableBreakdown.values.isEmpty
        ? 1.0
        : mutableBreakdown.values.reduce((a, b) => a + b);
    final chartScale = _computeChartScale(mutableBreakdown, totalDur);
    final timeBreakdownData = _buildTimeBreakdownData(
      mutableBreakdown,
      totalDur,
      chartScale,
    );

    final hotFunctionsData = [
      for (var i = 0; i < report.hotFunctions.length; i++)
        _buildHotFunctionData(report.hotFunctions[i], i + 1),
    ];

    final data = {
      'frameHealth': _buildFrameHealthData(report.frameHealth),
      'timeBreakdown': timeBreakdownData,
      'chartScale': chartScale.toStringAsFixed(0),
      'hotFunctions': hotFunctionsData,
    };

    return template.renderString(data);
  }

  Map<PerformanceCategory, double> _computeExclusiveBreakdown(
    Map<PerformanceCategory, double> source,
  ) {
    final mutable = Map<PerformanceCategory, double>.from(source);
    final jsScripting = mutable[PerformanceCategory.jsScripting] ?? 0.0;
    final buildTime = mutable[PerformanceCategory.flutterBuild] ?? 0.0;
    final layoutTime = mutable[PerformanceCategory.flutterLayout] ?? 0.0;
    final paintTime = mutable[PerformanceCategory.flutterPaint] ?? 0.0;

    final exclusiveJs = (jsScripting - (buildTime + layoutTime + paintTime))
        .clamp(0.0, double.infinity);
    mutable[PerformanceCategory.jsScripting] = exclusiveJs;
    return mutable;
  }

  double _computeChartScale(
    Map<PerformanceCategory, double> breakdown,
    double totalDur,
  ) {
    var maxPct = 0.0;
    for (final value in breakdown.values) {
      final pct = totalDur > 0 ? (value / totalDur) * 100 : 0.0;
      if (pct > maxPct) maxPct = pct;
    }

    if (maxPct <= 0.0) return 10.0;
    final scaled = (maxPct / 10.0).ceil() * 10.0;
    return scaled > 100.0 ? 100.0 : scaled;
  }

  List<Map<String, dynamic>> _buildTimeBreakdownData(
    Map<PerformanceCategory, double> breakdown,
    double totalDur,
    double chartScale,
  ) {
    return breakdown.entries.map((e) {
      final category = e.key;
      final duration = e.value;
      final percent = totalDur > 0 ? (duration / totalDur) * 100 : 0.0;
      final displayWidth = chartScale > 0 ? (percent / chartScale) * 100 : 0.0;
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
  }

  Map<String, dynamic> _buildHotFunctionData(HotFunction f, int rank) {
    final wasmLines = _formatWasmLines(f.wasmInstructions);
    final wasmUnoptLines = _formatWasmLines(f.wasmInstructionsUnoptimized);
    final wasmAnalysisData = _buildWasmAnalysisMap(f.wasmAnalysis);
    final wasmUnoptAnalysisData = _buildWasmAnalysisMap(
      f.wasmAnalysisUnoptimized,
    );

    return {
      'index': rank,
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
    };
  }

  List<Map<String, dynamic>>? _formatWasmLines(String? instructions) {
    if (instructions == null) return null;
    final lines = const LineSplitter().convert(instructions);
    return [
      for (var i = 0; i < lines.length; i++)
        {'number': i + 1, 'text': lines[i], 'isBad': _isLineBad(lines[i])},
    ];
  }

  Map<String, dynamic>? _buildWasmAnalysisMap(WasmAnalysis? analysis) {
    if (analysis == null) return null;
    return {
      'totalInstructions': analysis.totalInstructions,
      'allocationCount': analysis.allocationCount,
      'typeCheckCount': analysis.typeCheckCount,
      'hasAllocationCount': analysis.allocationCount > 0,
      'hasTypeCheckCount': analysis.typeCheckCount > 0,
      'hasWarnings':
          analysis.allocationCount > 0 || analysis.typeCheckCount > 0,
    };
  }

  Map<String, dynamic> _buildFrameHealthData(FrameHealth fh) {
    return {
      'avgIntervalMs': fh.avgIntervalMs?.toStringAsFixed(2) ?? 'N/A',
      'avgWorkMs': fh.avgWorkMs?.toStringAsFixed(2) ?? 'N/A',
      'dropRate': fh.dropRate.toStringAsFixed(2),
      'requestedCount': fh.requestedCount,
      'processedCount': fh.processedCount,
      'totalAllocatedText': fh.totalAllocatedBytes != null
          ? _formatBytes(fh.totalAllocatedBytes!)
          : 'N/A',
      'hasAllocatedBytes':
          fh.totalAllocatedBytes != null && fh.totalAllocatedBytes! > 0,
    };
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
