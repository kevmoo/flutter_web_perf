import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'chrome_controller.dart';
import 'server.dart';
import 'trace_analyzer.dart';
import 'profile_symbolicator.dart';

enum CompileTarget { js, wasm }

Future<void> runApp(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'target',
      abbr: 't',
      allowed: ['js', 'wasm'],
      defaultsTo: 'js',
      help: 'The compile target for the web app.',
    );

  final results = parser.parse(arguments);
  final targetStr = results['target'] as String;
  final target = targetStr == 'wasm' ? CompileTarget.wasm : CompileTarget.js;

  print('Hello from flutter_web_perf tool!');
  print('Target: $targetStr');

  // 1. Build the app
  final appDir = '../sample_app';
  print('Building app in $appDir...');
  final buildArgs = ['build', 'web', '--source-maps'];
  if (target == CompileTarget.wasm) {
    buildArgs.add('--wasm');
  }

  final buildResult = await Process.run(
    'flutter',
    buildArgs,
    workingDirectory: appDir,
  );
  if (buildResult.exitCode != 0) {
    print('Build failed!');
    print(buildResult.stderr);
    exitCode = buildResult.exitCode;
    return;
  }
  print('Build successful.');

  final server = DevServer();
  final controller = ChromeController();

  try {
    final buildPath = '$appDir/build/web';
    final port = await server.start(buildPath);
    final url = 'http://localhost:$port';

    await controller.start(url);
    print('Chrome started and navigated to $url');

    await controller.startTracing();
    await controller.startProfiling();

    // Wait a bit to collect data
    await Future.delayed(const Duration(seconds: 5));

    final profile = await controller.stopProfiling();
    final events = await controller.stopTracing();

    print('Collected ${events.length} trace events.');

    final file = File('trace.json');
    await file.writeAsString(json.encode(events));
    print('Saved trace data to ${file.absolute.path}');

    final profileFile = File('profile.json');
    await profileFile.writeAsString(json.encode(profile));
    print('Saved profile data to ${profileFile.absolute.path}');

    final mapPath = target == CompileTarget.wasm
        ? '$buildPath/main.dart.wasm.map'
        : '$buildPath/main.dart.js.map';

    final analyzer = TraceAnalyzer(file.path, sourceMapPath: mapPath);
    await analyzer.analyze();

    final symbolicator = ProfileSymbolicator(
      profilePath: profileFile.path,
      sourceMapPath: mapPath,
      outputPath: 'profile_symbolicated.json',
    );
    await symbolicator.symbolicate();

    await analyzer.analyzeProfile('profile_symbolicated.json');
  } catch (e) {
    print('Error: $e');
  } finally {
    await controller.stop();
    await server.stop();
    print('Stopped server and Chrome.');
  }
}
