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
    if (results.containsKey(id)) continue;

    final escapedTarget = RegExp.escape(id);
    // Match either the name (ending with $Target) or the exact index (;Target;)
    // Wasm function names are often mangled, e.g. $_RootZone.runBinary
    final namePattern = r'\$.*' + escapedTarget + r'(\b|")';
    final indexPattern = r'\(;' + escapedTarget + r';\)';
    final funcSignatureRegex = RegExp(
      '(' + namePattern + '|' + indexPattern + ')',
    );

    StringBuffer? buffer;
    int openParentheses = 0;

    for (var line in lines) {
      if (buffer == null) {
        if (line.contains('(func ') && funcSignatureRegex.hasMatch(line)) {
          buffer = StringBuffer();
          openParentheses += _countChar(line, '(') - _countChar(line, ')');
          buffer.writeln(_formatLine(line));
          if (openParentheses <= 0) break; // One-liner
        }
      } else {
        buffer.writeln(_formatLine(line));
        openParentheses += _countChar(line, '(') - _countChar(line, ')');
        if (openParentheses <= 0) {
          break;
        }
      }
    }

    if (buffer != null) {
      results[id] = buffer.toString().trim();
    }
  }

  return results;
}

String _formatLine(String l) => l.startsWith('  ') ? l.substring(2) : l;

int _countChar(String text, String char) {
  int count = 0;
  for (var i = 0; i < text.length; i++) {
    if (text[i] == char) count++;
  }
  return count;
}
