import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

void main() async {
  // Get the directory of the current script
  final scriptPath = Platform.script.toFilePath();
  final scriptDir = p.dirname(scriptPath);
  final projectDir = p.dirname(scriptDir);

  final templateFile = File(
    p.join(projectDir, 'lib', 'src', 'resources', 'report.mustache'),
  );
  final outputFile = File(
    p.join(projectDir, 'lib', 'src', 'resources', 'report_template.dart'),
  );

  if (!await templateFile.exists()) {
    print('Template file not found: \${templateFile.path}');
    exitCode = 1;
    return;
  }

  final content = await templateFile.readAsString();
  final base64Content = base64.encode(utf8.encode(content));

  const lineLength = 74;
  final chunked = StringBuffer();
  for (var i = 0; i < base64Content.length; i += lineLength) {
    final end = i + lineLength < base64Content.length
        ? i + lineLength
        : base64Content.length;
    chunked.write("  '${base64Content.substring(i, end)}'\n");
  }

  final dartContent =
      '''
// GENERATED CODE - DO NOT MODIFY BY HAND

const String reportTemplateBase64 =
${chunked.toString().trimRight()};
''';

  await outputFile.writeAsString(dartContent);
  print('Generated \${outputFile.path}');
}
