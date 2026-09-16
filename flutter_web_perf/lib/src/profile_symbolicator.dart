import 'dart:convert';
import 'dart:io';

import 'package:source_maps/source_maps.dart';

import 'exceptions.dart';
import 'profile_model.dart';

String normalizeLocation(String url) {
  final canvasKitSuffix = _extractAfterMarker(url, 'flutter-canvaskit/');
  if (canvasKitSuffix != null && canvasKitSuffix.length > 1) {
    return canvasKitSuffix.sublist(1).join('/');
  }

  if (url.startsWith('org-dartlang-sdk:///dart-sdk/lib/')) {
    return url.replaceFirst('org-dartlang-sdk:///dart-sdk/lib/', 'dart:');
  }

  final flutterPkgParts = _extractAfterMarker(url, 'flutter/packages/');
  if (flutterPkgParts != null) {
    if (flutterPkgParts.length > 1 && flutterPkgParts[1] == 'lib') {
      flutterPkgParts.removeAt(1);
    }
    return 'package:${flutterPkgParts.join('/')}';
  }

  return url;
}

List<String>? _extractAfterMarker(String url, String marker) {
  final index = url.indexOf(marker);
  if (index < 0) return null;
  final rest = url.substring(index + marker.length);
  return rest.split('/');
}

Future<Map<String, dynamic>> symbolicateProfile({
  required String profilePath,
  required String sourceMapPath,
}) async {
  final profileFile = File(profilePath);
  final mapFile = File(sourceMapPath);

  if (!await profileFile.exists()) {
    throw FlutterWebPerfException('Profile file not found: $profilePath');
  }
  if (!await mapFile.exists()) {
    throw FlutterWebPerfException('Source map file not found: $sourceMapPath');
  }

  final profileContent = await profileFile.readAsString();
  final profile = CpuProfile.fromJson(
    json.decode(profileContent) as Map<String, dynamic>,
  );

  final mapContent = await mapFile.readAsString();
  final mapping = parse(mapContent) as SingleMapping;
  final isWasmMap = sourceMapPath.endsWith('.wasm.map');

  for (final node in profile.nodes) {
    _symbolicateCallFrame(node.callFrame, mapping, isWasmMap: isWasmMap);
  }

  return profile.toJson();
}

void _symbolicateCallFrame(
  CallFrame frame,
  SingleMapping mapping, {
  required bool isWasmMap,
}) {
  final line = frame.lineNumber;
  final column = frame.columnNumber;
  if (line == null || column == null) return;

  final targetArtifact = isWasmMap ? 'main.dart.wasm' : 'main.dart.js';
  if (!frame.url.contains(targetArtifact)) {
    frame.url = normalizeLocation(frame.url);
    return;
  }

  final span = _findSpanWithPrologueFallback(mapping, line, column);
  if (span == null) return;

  final hasWasmSymbol =
      isWasmMap &&
      frame.functionName.isNotEmpty &&
      !frame.functionName.startsWith('wasm-function[');
  if (!hasWasmSymbol && span.text.isNotEmpty) {
    frame.functionName = span.text;
  }
  frame.url = normalizeLocation(span.sourceUrl.toString());
  frame.lineNumber = span.start.line + 1;
  frame.columnNumber = span.start.column + 1;
}

SourceMapSpan? _findSpanWithPrologueFallback(
  SingleMapping mapping,
  int line,
  int column,
) {
  final direct = mapping.spanFor(line, column);
  if (direct != null) return direct;

  // Wasm source maps often lack an entry for the function prologue; scan ahead.
  for (var offset = column; offset < column + 100; offset++) {
    final candidate = mapping.spanFor(line, offset);
    if (candidate != null) return candidate;
  }
  return null;
}
