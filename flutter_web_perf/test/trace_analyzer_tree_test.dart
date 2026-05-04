import 'package:flutter_web_perf/src/profile_model.dart';
import 'package:flutter_web_perf/src/trace_analyzer.dart';
import 'package:test/test.dart';

void main() {
  group('TraceAnalyzer profile processing', () {
    late TraceAnalyzer analyzer;

    setUp(() {
      analyzer = TraceAnalyzer('dummy.json');
    });

    test('collapses JS interop and empty URLs to true caller', () {
      final profile = CpuProfile(
        nodes: [
          CpuProfileNode(
            id: 1,
            callFrame: CallFrame(functionName: '(root)', url: ''),
            children: [2],
          ),
          CpuProfileNode(
            id: 2,
            callFrame: CallFrame(functionName: 'main', url: 'main.dart'),
            children: [3, 4],
          ),
          CpuProfileNode(
            id: 3,
            callFrame: CallFrame(
              functionName: 'someFlutterFunc',
              url: 'package:flutter/flutter.dart',
            ),
            children: [5],
          ),
          CpuProfileNode(
            id: 4,
            callFrame: CallFrame(
              functionName: 'dartDeveloperFunc',
              url: 'dart:developer/timeline.dart',
            ),
            children: [6],
          ),
          CpuProfileNode(
            id: 5,
            callFrame: CallFrame(
              functionName: 'interopCall',
              url: 'main.dart.mjs',
            ),
            children: [7],
          ),
          CpuProfileNode(
            id: 6,
            callFrame: CallFrame(
              functionName: 'internalFunc',
              url: 'dart:_internal/something.dart',
            ),
            children: [],
          ),
          CpuProfileNode(
            id: 7,
            callFrame: CallFrame(functionName: 'v8_internal', url: ''),
            children: [],
          ),
        ],
        samples: [
          // 2 samples in someFlutterFunc directly
          3, 3,
          // 4 samples in interop wrapper, should attribute to someFlutterFunc
          5, 5, 5, 5,
          // 3 samples in v8 internal called by interop, should attribute to
          // someFlutterFunc
          7, 7, 7,
          // 5 samples in dart:developer func, should attribute to main
          4, 4, 4, 4, 4,
          // 2 samples in dart:_internal, should attribute to main
          6, 6,
        ],
      );

      final hotFunctions = analyzer.processProfile(profile);

      // We expect:
      // someFlutterFunc: 2 (direct) + 4 (from 5) + 3 (from 7) = 9 samples
      // main: 5 (from 4) + 2 (from 6) = 7 samples
      expect(hotFunctions.length, 2);
      expect(hotFunctions[0].name, 'someFlutterFunc');
      expect(hotFunctions[0].samples, 9);
      expect(hotFunctions[1].name, 'main');
      expect(hotFunctions[1].samples, 7);
    });

    test('collapses CanvasKit Wasm', () {
      final profile = CpuProfile(
        nodes: [
          CpuProfileNode(
            id: 1,
            callFrame: CallFrame(functionName: '(root)', url: ''),
            children: [2],
          ),
          CpuProfileNode(
            id: 2,
            callFrame: CallFrame(
              functionName: 'paint',
              url: 'package:flutter/paint.dart',
            ),
            children: [3],
          ),
          CpuProfileNode(
            id: 3,
            callFrame: CallFrame(
              functionName: 'wasm-function[10]',
              url: 'canvaskit.wasm',
            ),
            children: [],
          ),
        ],
        samples: [3, 3, 3, 3],
      );

      final hotFunctions = analyzer.processProfile(profile);

      expect(hotFunctions.length, 1);
      expect(hotFunctions[0].name, 'CanvasKit Wasm (collapsed)');
      expect(hotFunctions[0].samples, 4);
    });

    test('handles completely unmapped trampolines', () {
      final profile = CpuProfile(
        nodes: [
          CpuProfileNode(
            id: 1,
            callFrame: CallFrame(functionName: '(root)', url: ''),
            children: [2],
          ),
          CpuProfileNode(
            id: 2,
            callFrame: CallFrame(functionName: 'usefulFunc', url: 'app.dart'),
            children: [3],
          ),
          CpuProfileNode(
            id: 3,
            callFrame: CallFrame(
              functionName: 'wasm-function[100]',
              url: 'main.dart.wasm',
            ),
            // no wasmFunctionIndex, so it's treated as unmapped
            children: [],
          ),
        ],
        samples: [3, 3],
      );

      final hotFunctions = analyzer.processProfile(profile);

      expect(hotFunctions.length, 1);
      expect(hotFunctions[0].name, 'usefulFunc');
      expect(hotFunctions[0].samples, 2);
    });
  });
}
