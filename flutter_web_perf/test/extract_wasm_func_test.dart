import 'dart:io';
import 'package:test/test.dart';
import 'package:flutter_web_perf/src/wasm_parser.dart';

void main() {
  group('extract_wasm_func', () {
    late File tempWatFile;

    setUp(() {
      tempWatFile = File('test_dummy.wat');
      tempWatFile.writeAsStringSync('''
(module
  (type (;0;) (func))
  (func \$testFunc (;0;) (type 0)
    (local i32)
    i32.const 42
    drop
  )
  (func \$otherFunc (;1;) (type 0)
    global.get \$"C455 )"
    nop
  )
)
''');
    });

    tearDown(() {
      if (tempWatFile.existsSync()) {
        tempWatFile.deleteSync();
      }
    });

    test('extracts function by name', () {
      final results = extractWasmFunctions(tempWatFile.path, ['testFunc']);
      expect(results['testFunc'], contains('i32.const 42'));
    });

    test('extracts function with string containing unbalanced parentheses', () {
      final results = extractWasmFunctions(tempWatFile.path, ['otherFunc']);
      expect(results['otherFunc'], contains('nop'));
      expect(results['otherFunc'], endsWith(')'));
    });
  });
}
