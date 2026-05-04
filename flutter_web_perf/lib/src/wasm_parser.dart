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

  // Pre-compile regexes for each identifier
  final regexMap = <String, RegExp>{};
  for (final id in identifiers) {
    final escapedTarget = RegExp.escape(id);
    // Wasm names start with a literal $ (e.g. $runBinary).
    // We escape the $ so it's not treated as an end-of-string anchor.
    final namePattern = r'\$.*' + escapedTarget + r'(\b|")';
    final indexPattern = r'\(;' + escapedTarget + r';\)';
    regexMap[id] = RegExp('($namePattern|$indexPattern)');
  }

  // Single pass over the file to extract everything
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.contains('(func ')) {
      for (final entry in regexMap.entries) {
        if (entry.value.hasMatch(line)) {
          final id = entry.key;
          if (results.containsKey(id)) continue;

          final buffer = StringBuffer();
          var openParentheses = _countChar(line, '(') - _countChar(line, ')');
          buffer.writeln(_formatLine(line));

          var j = i + 1;
          while (openParentheses > 0 && j < lines.length) {
            final nextLine = lines[j];
            buffer.writeln(_formatLine(nextLine));
            openParentheses +=
                _countChar(nextLine, '(') - _countChar(nextLine, ')');
            j++;
          }

          results[id] = buffer.toString().trim();
          break; // Found a match for this line
        }
      }
    }
  }

  return results;
}

String _formatLine(String l) => l.startsWith('  ') ? l.substring(2) : l;

int _countChar(String text, String char) {
  var count = 0;
  for (var i = 0; i < text.length; i++) {
    if (text[i] == char) count++;
  }
  return count;
}
