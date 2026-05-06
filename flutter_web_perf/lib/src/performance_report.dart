const wasmAllocationOpcodes = {
  'struct.new',
  'struct.new_default',
  'array.new',
  'array.new_default',
  'array.new_fixed',
};

const wasmTypeCheckOpcodes = {'ref.cast', 'ref.test', 'br_on_cast'};

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

  String get shortLabel => switch (this) {
    PerformanceCategory.flutterBuild => 'Build',
    PerformanceCategory.flutterLayout => 'Layout',
    PerformanceCategory.flutterPaint => 'Paint',
    PerformanceCategory.flutterCompositing => 'Compositing',
    PerformanceCategory.flutterSemantics => 'Semantics',
    PerformanceCategory.engineRaster => 'Raster',
    PerformanceCategory.jsScripting || PerformanceCategory.other => 'Script',
    PerformanceCategory.browserRendering => 'Rendering',
    PerformanceCategory.gc => 'GC',
  };
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
  int? totalAllocatedBytes;

  FrameHealth({
    this.avgIntervalMs,
    this.avgWorkMs,
    required this.requestedCount,
    required this.processedCount,
    this.totalAllocatedBytes,
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

class WasmAnalysis {
  final int totalInstructions;
  final int allocationCount;
  final int typeCheckCount;
  final Map<String, int> instructionCounts;

  WasmAnalysis({
    required this.totalInstructions,
    required this.allocationCount,
    required this.typeCheckCount,
    required this.instructionCounts,
  });
}

class HotFunction {
  final String name;
  final String url;
  final int samples;
  final double percent;
  final PerformanceCategory category;
  final int? lineNumber;
  final int? columnNumber;
  final int? wasmFunctionIndex;
  String? wasmInstructions;
  String? wasmInstructionsUnoptimized;
  WasmAnalysis? wasmAnalysis;
  WasmAnalysis? wasmAnalysisUnoptimized;
  int? allocationsBytes;
  String? githubUrl;

  HotFunction({
    required this.name,
    required this.url,
    required this.samples,
    required this.percent,
    required this.category,
    this.lineNumber,
    this.columnNumber,
    this.wasmFunctionIndex,
    this.wasmInstructions,
    this.wasmInstructionsUnoptimized,
    this.wasmAnalysis,
    this.wasmAnalysisUnoptimized,
    this.allocationsBytes,
    this.githubUrl,
  });
}
