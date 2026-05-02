class PerformanceReport {
  final FrameHealth frameHealth;
  final Map<String, double> timeBreakdown;
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
  final int? lineNumber;
  final int? columnNumber;
  final int? wasmFunctionIndex;
  String? wasmInstructions;

  HotFunction({
    required this.name,
    required this.url,
    required this.samples,
    this.lineNumber,
    this.columnNumber,
    this.wasmFunctionIndex,
    this.wasmInstructions,
  });
}
