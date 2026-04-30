import 'dart:convert';
import 'dart:io';
import 'package:source_maps/source_maps.dart';

class ProfileSymbolicator {
  final String profilePath;
  final String sourceMapPath;
  final String outputPath;

  ProfileSymbolicator({
    required this.profilePath,
    required this.sourceMapPath,
    required this.outputPath,
  });

  Future<void> symbolicate() async {
    final profileFile = File(profilePath);
    final mapFile = File(sourceMapPath);

    if (!await profileFile.exists()) {
      print('Profile file not found: \$profilePath');
      return;
    }
    if (!await mapFile.exists()) {
      print('Source map file not found: \$sourceMapPath');
      return;
    }

    final profileContent = await profileFile.readAsString();
    final profile = json.decode(profileContent) as Map<String, dynamic>;

    final mapContent = await mapFile.readAsString();
    final mapping = parse(mapContent) as SingleMapping;

    final nodes = profile['nodes'] as List;
    var mappedCount = 0;

    for (final node in nodes) {
      final callFrame = node['callFrame'] as Map<String, dynamic>;
      final line = callFrame['lineNumber'] as int?;
      final column = callFrame['columnNumber'] as int?;

      if (line != null && column != null) {
        final span = mapping.spanFor(line, column);
        if (span != null) {
          // Use the identifier name if available, otherwise keep original
          if (span.text.isNotEmpty) {
            callFrame['functionName'] = span.text;
          }
          callFrame['url'] = span.sourceUrl.toString();
          callFrame['lineNumber'] =
              span.start.line + 1; // Convert to 1-based for human readability
          callFrame['columnNumber'] = span.start.column + 1;
          mappedCount++;
        }
      }
    }

    print('Symbolicated $mappedCount nodes.');

    final outputFile = File(outputPath);
    await outputFile.writeAsString(json.encode(profile));
    print('Saved symbolicated profile to ${outputFile.absolute.path}');
  }
}
