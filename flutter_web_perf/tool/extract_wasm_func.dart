import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    print(
      'Usage: dart run tool/extract_wasm_func.dart <path_to_wasm> <function_index>',
    );
    exit(1);
  }

  final wasmPath = args[0];
  final functionIndexStr = args[1];
  final functionIndex = int.tryParse(functionIndexStr);

  if (functionIndex == null) {
    print('Error: function_index must be an integer.');
    exit(1);
  }

  final wasmFile = File(wasmPath);
  if (!await wasmFile.exists()) {
    print('Error: File not found at $wasmPath');
    exit(1);
  }

  print(
    'Extracting WebAssembly Text (WAT) for function index $functionIndex...',
  );

  // Run wasm-tools print to get the textual representation
  final process = await Process.start('wasm-tools', ['print', wasmPath]);

  bool inTargetFunction = false;
  int openParentheses = 0;
  final funcSignatureRegex = RegExp(
    r'^\s*\(func .*\(;' + functionIndex.toString() + r';\)',
  );

  // Process the output stream line by line
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) {
    if (!inTargetFunction) {
      // Look for the start of the target function
      if (funcSignatureRegex.hasMatch(line)) {
        inTargetFunction = true;
        // Count initial parentheses
        openParentheses += _countChar(line, '(') - _countChar(line, ')');
        print(line);
      }
    } else {
      print(line);
      openParentheses += _countChar(line, '(') - _countChar(line, ')');

      // If we've closed all parentheses opened by the function, we're done
      if (openParentheses <= 0) {
        inTargetFunction = false;
        process
            .kill(); // We found our function, no need to parse the rest of the massive file
      }
    }
  });

  final exitCode = await process.exitCode;
  if (exitCode != 0 && exitCode != -15) {
    // -15 is SIGTERM (when we kill it early)
    print('wasm-tools exited with code $exitCode');
    final stderr = await process.stderr.transform(utf8.decoder).join();
    if (stderr.isNotEmpty) {
      print('Error output: $stderr');
    }
  }
}

int _countChar(String text, String char) {
  int count = 0;
  for (var i = 0; i < text.length; i++) {
    if (text[i] == char) count++;
  }
  return count;
}
