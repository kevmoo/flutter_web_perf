import 'dart:convert';
import 'dart:io';
import 'package:source_maps/source_maps.dart';
import 'exceptions.dart';
import 'profile_model.dart';

String normalizeLocation(String url) {
  if (url.contains('flutter-canvaskit/')) {
    final index = url.indexOf('flutter-canvaskit/');
    final rest = url.substring(index + 'flutter-canvaskit/'.length);
    final parts = rest.split('/');
    if (parts.length > 1) {
      return parts.sublist(1).join('/');
    }
  }

  if (url.startsWith('org-dartlang-sdk:///dart-sdk/lib/')) {
    return url.replaceFirst('org-dartlang-sdk:///dart-sdk/lib/', 'dart:');
  }

  if (url.contains('flutter/packages/')) {
    final index = url.indexOf('flutter/packages/');
    final rest = url.substring(index + 'flutter/packages/'.length);
    final parts = rest.split('/');
    if (parts.length > 1 && parts[1] == 'lib') {
      parts.removeAt(1);
    }
    return 'package:${parts.join('/')}';
  }

  return url;
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

  for (final node in profile.nodes) {
    final frame = node.callFrame;
    final line = frame.lineNumber;
    final column = frame.columnNumber;

    if (line != null && column != null) {
      final span = mapping.spanFor(line, column);
      if (span != null) {
        if (span.text.isNotEmpty) {
          frame.functionName = span.text;
        }
        frame.url = normalizeLocation(span.sourceUrl.toString());
        frame.lineNumber = span.start.line + 1;
        frame.columnNumber = span.start.column + 1;
      }
    }
  }

  return profile.toJson();
}
