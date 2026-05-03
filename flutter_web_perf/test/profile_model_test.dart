import 'package:flutter_web_perf/src/profile_model.dart';
import 'package:test/test.dart';

void main() {
  group('CpuProfile Node parsing', () {
    test('parses a basic profile node', () {
      final json = {
        'id': 1,
        'callFrame': {
          'functionName': 'build',
          'url': 'package:flutter/src/widgets/framework.dart',
          'lineNumber': 4556,
          'columnNumber': 11,
        },
        'hitCount': 5,
        'children': [2, 3],
      };

      final node = CpuProfileNode.fromJson(json);

      expect(node.id, 1);
      expect(node.hitCount, 5);
      expect(node.children, containsAll([2, 3]));
      expect(node.callFrame.functionName, 'build');
      expect(node.callFrame.url, 'package:flutter/src/widgets/framework.dart');
      expect(node.callFrame.lineNumber, 4556);
      expect(node.callFrame.columnNumber, 11);
    });

    test('extracts wasmFunctionIndex if it exists', () {
      final json = {
        'id': 2,
        'callFrame': {
          'functionName': 'wasm-function[1610]',
          'url': 'main.dart.wasm',
        },
      };

      final node = CpuProfileNode.fromJson(json);
      expect(node.callFrame.functionName, 'wasm-function[1610]');
      expect(node.callFrame.wasmFunctionIndex, 1610);
    });

    test('retains wasmFunctionIndex if explicitly provided', () {
      final json = {
        'id': 3,
        'callFrame': {
          'functionName': 'SomeSymbolicatedName',
          'url': 'main.dart.wasm',
          'wasmFunctionIndex': 42,
        },
      };

      final node = CpuProfileNode.fromJson(json);
      expect(node.callFrame.functionName, 'SomeSymbolicatedName');
      expect(node.callFrame.wasmFunctionIndex, 42);
    });
  });

  group('CpuProfile parsing', () {
    test('parses entire profile', () {
      final json = {
        'nodes': [
          {
            'id': 1,
            'callFrame': {'functionName': '(root)', 'url': ''},
            'children': [2],
          },
          {
            'id': 2,
            'callFrame': {'functionName': 'main', 'url': ''},
          },
        ],
        'samples': [1, 2, 2, 1],
        'timeDeltas': [1000, 2000, 1500, 500],
      };

      final profile = CpuProfile.fromJson(json);
      expect(profile.nodes.length, 2);
      expect(profile.samples, [1, 2, 2, 1]);
      expect(profile.timeDeltas, [1000, 2000, 1500, 500]);
    });
  });
}
