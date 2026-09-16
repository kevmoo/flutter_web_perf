import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    print(
      'Usage: dart run tool/extract_wasm_func.dart <path_to_wasm> <function_name_or_index>',
    );
    exit(1);
  }

  final wasmPath = args[0];
  final targetIdentifier = args[1];

  final wasmFile = File(wasmPath);
  if (!await wasmFile.exists()) {
    print('Error: File not found at $wasmPath');
    exit(1);
  }

  // Run wasm-tools print to get the textual representation
  final process = await Process.start('wasm-tools', ['print', wasmPath]);

  // Match either the index (;123;) or the exact name $name or
  // $"name with spaces"
  final escapedTarget = RegExp.escape(targetIdentifier);
  final funcSignatureRegex = RegExp(
    r'^\s*\(func (\$' +
        escapedTarget +
        r'\b|\$"' +
        escapedTarget +
        r'"|.*\(;' +
        escapedTarget +
        r';\))',
  );

  final extractor = _StreamFunctionExtractor(process, funcSignatureRegex);
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(extractor.processLine);

  final exitCode = await process.exitCode;
  // -15 is SIGTERM (when we kill it early)
  if (exitCode != 0 && exitCode != -15) {
    print('wasm-tools exited with code $exitCode');
    final stderr = await process.stderr.transform(utf8.decoder).join();
    if (stderr.isNotEmpty) {
      print('Error output: $stderr');
    }
  }
}

class _StreamFunctionExtractor {
  final Process _process;
  final RegExp _signatureRegex;
  bool _inTargetFunction = false;
  int _openParentheses = 0;

  _StreamFunctionExtractor(this._process, this._signatureRegex);

  void processLine(String line) {
    if (!_inTargetFunction) {
      if (!_signatureRegex.hasMatch(line)) return;
      _inTargetFunction = true;
    }

    print(_formatLine(line));
    _openParentheses += _countChar(line, '(') - _countChar(line, ')');
    if (_openParentheses <= 0) {
      _inTargetFunction = false;
      _process.kill();
    }
  }

  static String _formatLine(String l) =>
      l.startsWith('  ') ? l.substring(2) : l;
}

int _countChar(String text, String char) {
  var count = 0;
  for (var i = 0; i < text.length; i++) {
    if (text[i] == char) count++;
  }
  return count;
}
