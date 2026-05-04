import 'dart:io';

import 'package:flutter_web_perf/src/wasm_parser.dart';
import 'package:test/test.dart';

void main() {
  test('extractWasmFunctions handles strings with parentheses', () {
    final file = File('test_strings.wat');
    file.writeAsStringSync('''
(module
  (func \$test (;0;)
    (local i32)
    global.get \$"string with )"
    drop
  )
)
''');
    final result = extractWasmFunctions(file.path, ['test']);
    expect(result['test'], contains('drop'));
    file.deleteSync();
  });
}
