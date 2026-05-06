enum PerformanceCategory {
  flutterBuild(
    label: 'Flutter Build',
    sqlPatterns: ['BUILD', 'Build', 'BuildOwner%'],
  ),
  flutterLayout(
    label: 'Flutter Layout',
    sqlPatterns: ['LAYOUT', 'Layout', 'LAYOUT%', 'RenderObject.performLayout%'],
  ),
  flutterPaint(
    label: 'Flutter Paint',
    sqlPatterns: ['PAINT', 'Paint', 'PAINT%', 'RenderObject.paint%'],
  ),
  flutterCompositing(
    label: 'Flutter Compositing',
    sqlPatterns: ['COMPOSITING'],
  ),
  flutterSemantics(label: 'Flutter Semantics', sqlPatterns: ['Semantics']),
  engineRaster(label: 'Engine Raster', sqlPatterns: ['Raster%']),
  jsScripting(label: 'JS Scripting', sqlPatterns: ['%Script::Execute%']),
  browserRendering(label: 'Browser Rendering', sqlPatterns: ['%Render%']),
  gc(label: 'GC', sqlPatterns: ['%GC%', '%gc%']),
  other(label: 'Other', sqlPatterns: []);

  /// The human-readable label displayed in the visual dashboard report
  final String label;

  /// SQL LIKE/equals patterns used by Perfetto's Trace Processor
  final List<String> sqlPatterns;

  const PerformanceCategory({required this.label, required this.sqlPatterns});

  static PerformanceCategory fromLabel(String label) {
    return PerformanceCategory.values.firstWhere(
      (c) => c.label == label,
      orElse: () => PerformanceCategory.other,
    );
  }
}

class PerformanceReport {
  final FrameHealth frameHealth;
  final Map<PerformanceCategory, double> timeBreakdown;
  final List<SlowTask> slowTasks;
  final List<HotFunction> hotFunctions;

  PerformanceReport({
    required this.frameHealth,
    required this.timeBreakdown,
    required this.slowTasks,
    required this.hotFunctions,
  });
}

class FrameHealth {
  final double? avgIntervalMs;
  final double? avgWorkMs;
  final int requestedCount;
  final int processedCount;

  FrameHealth({
    this.avgIntervalMs,
    this.avgWorkMs,
    required this.requestedCount,
    required this.processedCount,
  });

  double get dropRate =>
      requestedCount > 0 ? (1 - (processedCount / requestedCount)) * 100 : 0.0;
}

class SlowTask {
  final String name;
  final double durationMs;
  final String category;
  final String? originalLocation;
  final String? identifier;

  SlowTask({
    required this.name,
    required this.durationMs,
    required this.category,
    this.originalLocation,
    this.identifier,
  });
}

class HotFunction {
  final String name;
  final String url;
  final int samples;
  final double percent;
  final int? lineNumber;
  final int? columnNumber;
  final int? wasmFunctionIndex;
  String? wasmInstructions;
  String? wasmInstructionsUnoptimized;
  String? githubUrl;

  HotFunction({
    required this.name,
    required this.url,
    required this.samples,
    required this.percent,
    this.lineNumber,
    this.columnNumber,
    this.wasmFunctionIndex,
    this.wasmInstructions,
    this.wasmInstructionsUnoptimized,
    this.githubUrl,
  });
}
