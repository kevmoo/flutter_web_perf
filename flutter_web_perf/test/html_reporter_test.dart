import 'package:flutter_web_perf/src/html_reporter.dart';
import 'package:flutter_web_perf/src/performance_report.dart';
import 'package:test/test.dart';

void main() {
  group('HtmlReporter', () {
    test('generates HTML from PerformanceReport', () {
      final reporter = HtmlReporter();
      final report = PerformanceReport(
        frameHealth: FrameHealth(
          avgIntervalMs: 16.6,
          avgWorkMs: 8.0,
          requestedCount: 60,
          processedCount: 59,
        ),
        timeBreakdown: {'Flutter Build': 100.0, 'JS Scripting': 50.0},
        slowTasks: [],
        hotFunctions: [
          HotFunction(
            name: 'build',
            url: 'package:flutter/src/widgets/framework.dart',
            samples: 100,
            lineNumber: 100,
            columnNumber: 5,
            wasmFunctionIndex: 42,
            wasmInstructions: '(func \$build ...)',
          ),
        ],
      );

      final html = reporter.generate(report);

      expect(html, contains('16.60 ms'));
      expect(html, contains('8.00 ms'));
      expect(html, contains('Flutter Build'));
      expect(html, contains('JS Scripting'));
      expect(
        html,
        contains('package:flutter&#x2F;src&#x2F;widgets&#x2F;framework.dart'),
      );
      expect(html, contains('View Wasm Instructions'));
      expect(html, contains('(func \$build ...)'));
    });
  });
}
