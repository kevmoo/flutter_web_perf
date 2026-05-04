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
    final namePattern = r'\$.*' + escapedTarget + r'(?:\s|\(|"|$)';
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
          int openParentheses = 0;
          bool inString = false;
          int blockCommentDepth = 0;

          void processLine(String l) {
            buffer.writeln(_formatLine(l));
            for (var c = 0; c < l.length; c++) {
              final char = l[c];

              if (inString) {
                if (char == '"') {
                  int backslashes = 0;
                  for (var k = c - 1; k >= 0 && l[k] == '\\'; k--) {
                    backslashes++;
                  }
                  if (backslashes % 2 == 0) {
                    inString = false;
                  }
                }
              } else if (blockCommentDepth > 0) {
                if (char == '(' && c + 1 < l.length && l[c + 1] == ';') {
                  blockCommentDepth++;
                  c++;
                } else if (char == ';' && c + 1 < l.length && l[c + 1] == ')') {
                  blockCommentDepth--;
                  c++; // skip ')'
                }
              } else {
                if (char == '"') {
                  inString = true;
                } else if (char == '(' && c + 1 < l.length && l[c + 1] == ';') {
                  blockCommentDepth++;
                  c++; // skip ';'
                } else if (char == '(') {
                  openParentheses++;
                } else if (char == ')') {
                  openParentheses--;
                } else if (char == ';' && c + 1 < l.length && l[c + 1] == ';') {
                  // line comment, stop processing this line
                  break;
                }
              }
            }
          }

          processLine(line);

          var j = i + 1;
          while (openParentheses > 0 && j < lines.length) {
            processLine(lines[j]);
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
