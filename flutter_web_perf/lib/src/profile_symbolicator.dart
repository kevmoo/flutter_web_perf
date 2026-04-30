import 'dart:convert';
import 'dart:io';
import 'package:source_maps/source_maps.dart';
import 'exceptions.dart';
import 'profile_model.dart';

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
  final profile = CpuProfile.fromJson(json.decode(profileContent));

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
        frame.url = span.sourceUrl.toString();
        frame.lineNumber = span.start.line + 1;
        frame.columnNumber = span.start.column + 1;
      }
    }
  }

  return profile.toJson();
}
