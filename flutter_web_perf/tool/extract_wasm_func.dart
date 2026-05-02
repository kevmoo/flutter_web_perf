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

  print('Extracting WebAssembly Text (WAT) for "$targetIdentifier"...');

  // Run wasm-tools print to get the textual representation
  final process = await Process.start('wasm-tools', ['print', wasmPath]);

  var inTargetFunction = false;
  var openParentheses = 0;

  // Match either the index (;123;) or the exact name $name or $"name with spaces"
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

  // Process the output stream line by line
  final linesStream = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  linesStream.listen((line) {
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
        // Found our function, stop parsing.
        process.kill();
      }
    }
  });

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

int _countChar(String text, String char) {
  var count = 0;
  for (var i = 0; i < text.length; i++) {
    if (text[i] == char) count++;
  }
  return count;
}
