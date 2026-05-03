import 'dart:io';

/// Extracts multiple functions from a WAT file by their names or indices.
/// Returns a map of identifier -> instructions.
Map<String, String> extractWasmFunctions(
  String watPath,
  List<String> identifiers,
) {
  final file = File(watPath);
  if (!file.existsSync()) return {};

  final lines = file.readAsLinesSync();
  final results = <String, String>{};

  for (final id in identifiers) {
    final escapedTarget = RegExp.escape(id);
    final funcSignatureRegex = RegExp(
      r'^\s*\(func (\$' +
          escapedTarget +
          r'\b|\$"' +
          escapedTarget +
          r'"|.*\(;' +
          escapedTarget +
          r';\))',
    );

    var inTargetFunction = false;
    var openParentheses = 0;
    final buffer = StringBuffer();

    for (var line in lines) {
      String formatLine(String l) => l.startsWith('  ') ? l.substring(2) : l;

      if (!inTargetFunction) {
        if (funcSignatureRegex.hasMatch(line)) {
          inTargetFunction = true;
          openParentheses += _countChar(line, '(') - _countChar(line, ')');
          buffer.writeln(formatLine(line));
        }
      } else {
        buffer.writeln(formatLine(line));
        openParentheses += _countChar(line, '(') - _countChar(line, ')');
        if (openParentheses <= 0) {
          break;
        }
      }
    }

    if (buffer.isNotEmpty) {
      results[id] = buffer.toString().trim();
    }
  }

  return results;
}

int _countChar(String text, String char) {
  var count = 0;
  for (var i = 0; i < text.length; i++) {
    if (text[i] == char) count++;
  }
  return count;
}
