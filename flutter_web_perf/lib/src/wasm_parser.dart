import 'dart:io';

import 'performance_report.dart';

/// Extracts multiple functions from a WAT file by their names or indices.
/// Returns a map of identifier -> instructions.
Map<String, String> extractWasmFunctions(
  String watPath,
  List<String> identifiers,
) {
  final file = File(watPath);
  if (!file.existsSync()) return {};

  final lines = file.readAsLinesSync();
  return parseWasmFunctions(lines, identifiers);
}

/// Parses multiple functions from WAT lines by their names or indices.
/// Returns a map of identifier -> instructions.
Map<String, String> parseWasmFunctions(
  List<String> lines,
  List<String> identifiers,
) {
  final results = <String, String>{};

  // Pre-compile regexes for each identifier
  final regexMap = <String, RegExp>{};
  for (final id in identifiers) {
    final escapedTarget = RegExp.escape(id);
    // Wasm names start with a literal $ (e.g. $runBinary).
    // We escape the $ so it's not treated as an end-of-string anchor.
    final namePattern = r'\$.*' + escapedTarget + r'(?:\s|\(|"|$)';
    final indexPattern = r'\(func[^\)]*\(;' + escapedTarget + r';\)';
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
          var openParentheses = 0;
          var inString = false;
          var blockCommentDepth = 0;

          void processLine(String l) {
            buffer.writeln(_formatLine(l));
            for (var c = 0; c < l.length; c++) {
              final char = l[c];

              if (inString) {
                if (char == '"') {
                  var backslashes = 0;
                  for (var k = c - 1; k >= 0 && l[k] == '\\'; k--) {
                    backslashes++;
                  }
                  if (backslashes.isEven) {
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

/// Analyzes raw Wasm Text (WAT) instructions of a function.
///
/// Generates total counts, WasmGC allocation metrics, and dynamic casting
/// checks.
WasmAnalysis? analyzeWasmInstructions(String? instructions) {
  if (instructions == null || instructions.isEmpty) return null;

  var totalInstructions = 0;
  var allocationCount = 0;
  var typeCheckCount = 0;
  final instructionCounts = <String, int>{};

  final lines = instructions.split('\n');
  final opcodeRegex = RegExp(r'^[a-z0-9_]+(?:\.[a-z0-9_]+)*');

  const declKeywords = {
    'func',
    'local',
    'param',
    'result',
    'type',
    'import',
    'export',
    'table',
    'memory',
    'elem',
    'data',
    'global',
  };

  for (final rawLine in lines) {
    var line = rawLine.trim();
    // Strip leading parenthetical wrappers
    while (line.startsWith('(')) {
      line = line.substring(1).trim();
    }

    if (line.isEmpty || line.startsWith(';;') || line.startsWith('(;')) {
      continue;
    }

    final match = opcodeRegex.firstMatch(line);
    if (match != null) {
      final opcode = match.group(0)!;
      if (declKeywords.contains(opcode)) {
        continue;
      }

      totalInstructions++;
      instructionCounts[opcode] = (instructionCounts[opcode] ?? 0) + 1;

      if (wasmAllocationOpcodes.contains(opcode)) {
        allocationCount++;
      } else if (wasmTypeCheckOpcodes.contains(opcode)) {
        typeCheckCount++;
      }
    }
  }

  return WasmAnalysis(
    totalInstructions: totalInstructions,
    allocationCount: allocationCount,
    typeCheckCount: typeCheckCount,
    instructionCounts: instructionCounts,
  );
}
