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
  final regexMap = _buildIdentifierRegexMap(identifiers);

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (!line.contains('(func ')) continue;

    final matchedId = _findMatchingIdentifier(line, regexMap, results);
    if (matchedId == null) continue;

    results[matchedId] = _extractSingleFunction(lines, i);
  }

  return results;
}

Map<String, RegExp> _buildIdentifierRegexMap(List<String> identifiers) {
  final regexMap = <String, RegExp>{};
  for (final id in identifiers) {
    final escapedTarget = RegExp.escape(id);
    final namePattern = r'\$.*' + escapedTarget + r'(?:\s|\(|"|$)';
    final indexPattern = r'\(func[^\)]*\(;' + escapedTarget + r';\)';
    regexMap[id] = RegExp('($namePattern|$indexPattern)');
  }
  return regexMap;
}

String? _findMatchingIdentifier(
  String line,
  Map<String, RegExp> regexMap,
  Map<String, String> existingResults,
) {
  for (final entry in regexMap.entries) {
    if (!existingResults.containsKey(entry.key) && entry.value.hasMatch(line)) {
      return entry.key;
    }
  }
  return null;
}

String _extractSingleFunction(List<String> lines, int startIndex) {
  final scanner = _WatBlockScanner();
  scanner.processLine(lines[startIndex]);

  var j = startIndex + 1;
  while (scanner.openParentheses > 0 && j < lines.length) {
    scanner.processLine(lines[j]);
    j++;
  }
  return scanner.buffer.toString().trim();
}

class _WatBlockScanner {
  final StringBuffer buffer = StringBuffer();
  int openParentheses = 0;
  bool _inString = false;
  int _blockCommentDepth = 0;

  void processLine(String line) {
    buffer.writeln(_formatLine(line));
    for (var c = 0; c < line.length; c++) {
      final step = _consumeToken(line, c);
      if (step < 0) break;
      c += step;
    }
  }

  /// Processes character at [index] in [line].
  /// Returns extra characters consumed (`0` or `1`), or `-1` for line comment.
  int _consumeToken(String line, int index) {
    final char = line[index];
    final nextChar = index + 1 < line.length ? line[index + 1] : '';

    if (_inString) {
      if (char == '"' && _isUnescapedQuote(line, index)) {
        _inString = false;
      }
      return 0;
    }

    if (_blockCommentDepth > 0) {
      return _consumeInsideBlockComment(char, nextChar);
    }

    return _consumeCodeToken(char, nextChar);
  }

  int _consumeInsideBlockComment(String char, String nextChar) {
    if (char == '(' && nextChar == ';') {
      _blockCommentDepth++;
      return 1;
    }
    if (char == ';' && nextChar == ')') {
      _blockCommentDepth--;
      return 1;
    }
    return 0;
  }

  int _consumeCodeToken(String char, String nextChar) {
    if (char == '"') {
      _inString = true;
      return 0;
    }
    if (char == '(' && nextChar == ';') {
      _blockCommentDepth++;
      return 1;
    }
    if (char == ';' && nextChar == ';') {
      return -1;
    }
    if (char == '(') {
      openParentheses++;
    } else if (char == ')') {
      openParentheses--;
    }
    return 0;
  }

  bool _isUnescapedQuote(String line, int quoteIndex) {
    var backslashes = 0;
    for (var k = quoteIndex - 1; k >= 0 && line[k] == '\\'; k--) {
      backslashes++;
    }
    return backslashes.isEven;
  }
}

String _formatLine(String l) => l.startsWith('  ') ? l.substring(2) : l;

const _declKeywords = {
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

final _opcodeRegex = RegExp(r'^[a-z0-9_]+(?:\.[a-z0-9_]+)*');

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

  for (final rawLine in instructions.split('\n')) {
    final opcode = _extractExecutableOpcode(rawLine);
    if (opcode == null) continue;

    totalInstructions++;
    instructionCounts[opcode] = (instructionCounts[opcode] ?? 0) + 1;

    if (wasmAllocationOpcodes.contains(opcode)) {
      allocationCount++;
    } else if (wasmTypeCheckOpcodes.contains(opcode)) {
      typeCheckCount++;
    }
  }

  return WasmAnalysis(
    totalInstructions: totalInstructions,
    allocationCount: allocationCount,
    typeCheckCount: typeCheckCount,
    instructionCounts: instructionCounts,
  );
}

String? _extractExecutableOpcode(String rawLine) {
  var line = rawLine.trim();
  while (line.startsWith('(')) {
    line = line.substring(1).trim();
  }
  if (line.isEmpty || line.startsWith(';;') || line.startsWith('(;')) {
    return null;
  }
  final opcode = _opcodeRegex.firstMatch(line)?.group(0);
  if (opcode == null || _declKeywords.contains(opcode)) {
    return null;
  }
  return opcode;
}
