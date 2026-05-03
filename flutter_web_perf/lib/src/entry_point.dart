import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'chrome_controller.dart';
import 'html_reporter.dart';
import 'profile_symbolicator.dart';
import 'server.dart';
import 'trace_analyzer.dart';
import 'wasm_parser.dart';

enum CompileTarget { js, wasm }

Future<void> runApp(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'target',
      abbr: 't',
      allowed: ['js', 'wasm'],
      defaultsTo: 'js',
      help: 'The compile target for the web app.',
    )
    ..addOption(
      'analyze-hotspot',
      help:
          'Provide the 1-based rank of the hot function to deeply analyze '
          'using Wasm disassembly.',
    );

  final results = parser.parse(arguments);
  final targetStr = results['target'] as String;
  final target = targetStr == 'wasm' ? CompileTarget.wasm : CompileTarget.js;
  final analyzeHotspotRank = int.tryParse(
    results['analyze-hotspot'] as String? ?? '',
  );

  print('Hello from flutter_web_perf tool!');
  print('Target: $targetStr');

  // 1. Build the app
  final appDir = '../sample_app';
  print('Building app in $appDir...');
  final buildArgs = ['build', 'web', '--profile', '--source-maps'];
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
    await Future<void>.delayed(const Duration(seconds: 5));

    final profile = await controller.stopProfiling();
    final events = await controller.stopTracing();

    print('Collected ${events.length} trace events.');

    final outDir = Directory('out');
    if (!await outDir.exists()) {
      await outDir.create();
    }

    final file = File('out/trace.json');
    await file.writeAsString(json.encode(events));
    print('Saved trace data to ${file.absolute.path}');

    final profileFile = File('out/profile.json');
    await profileFile.writeAsString(json.encode(profile));
    print('Saved profile data to ${profileFile.absolute.path}');

    final mapPath = target == CompileTarget.wasm
        ? '$buildPath/main.dart.wasm.map'
        : '$buildPath/main.dart.js.map';

    final analyzer = TraceAnalyzer(file.path, sourceMapPath: mapPath);

    final symbolicatedProfile = await symbolicateProfile(
      profilePath: profileFile.path,
      sourceMapPath: mapPath,
    );

    final symbolicatedFile = File('out/profile_symbolicated.json');
    await symbolicatedFile.writeAsString(json.encode(symbolicatedProfile));
    print('Saved symbolicated profile to ${symbolicatedFile.absolute.path}');

    final report = await analyzer.generateReport(
      profilePath: symbolicatedFile.path,
    );

    // Get current Flutter SHA
    String? flutterSha;
    const localFlutterRepo = '/Users/kevmoo/github/flutter';
    try {
      final shaResult = await Process.run('git', [
        'rev-parse',
        'HEAD',
      ], workingDirectory: localFlutterRepo);
      if (shaResult.exitCode == 0) {
        flutterSha = shaResult.stdout.toString().trim();
      }
    } catch (_) {}

    print('\n=== Performance Report Summary ===');
    print(
      'Average Frame Interval: '
      '${report.frameHealth.avgIntervalMs?.toStringAsFixed(2)} ms',
    );
    print(
      'Average Frame Work Duration: '
      '${report.frameHealth.avgWorkMs?.toStringAsFixed(2)} ms',
    );
    print('Drop Rate: ${report.frameHealth.dropRate.toStringAsFixed(2)}%');
    print('Requested Frames: ${report.frameHealth.requestedCount}');
    print('Processed Frames: ${report.frameHealth.processedCount}');

    print('\n=== Time Breakdown ===');
    report.timeBreakdown.forEach((cat, dur) {
      print('$cat: ${dur.toStringAsFixed(2)} ms');
    });

    print('\n=== Top 10 Hot Functions ===');
    for (var i = 0; i < report.hotFunctions.length; i++) {
      final f = report.hotFunctions[i];
      final wasmLabel = f.wasmFunctionIndex != null
          ? ' (Wasm Index: ${f.wasmFunctionIndex})'
          : '';
      print('${i + 1}. ${f.name}$wasmLabel: ${f.samples} samples');

      // Source-Aware Hotspot Analysis!
      if (f.url.contains('package:flutter/') && f.lineNumber != null) {
        try {
          final suffix = f.url.split('package:flutter/').last;
          final localFilePath =
              '$localFlutterRepo/packages/flutter/lib/$suffix';

          if (flutterSha != null) {
            f.githubUrl =
                'https://github.com/flutter/flutter/blob/$flutterSha/packages/flutter/lib/$suffix#L${f.lineNumber}';
          }

          final sourceFile = File(localFilePath);

          if (await sourceFile.exists()) {
            final lines = await sourceFile.readAsLines();
            final centerLineIdx = (f.lineNumber! - 1).clamp(
              0,
              lines.isNotEmpty ? lines.length - 1 : 0,
            );
            final startLineIdx = (centerLineIdx - 2).clamp(
              0,
              lines.isNotEmpty ? lines.length - 1 : 0,
            );
            final endLineIdx = (centerLineIdx + 3).clamp(0, lines.length);

            print('    📍 ${sourceFile.path}:${f.lineNumber!}');
            print('    ╭────────────────────────────────────────');
            for (var lineIdx = startLineIdx; lineIdx < endLineIdx; lineIdx++) {
              final prefix = lineIdx == centerLineIdx ? '    │ > ' : '    │   ';
              print('$prefix${lines[lineIdx]}');
            }
            print('    ╰────────────────────────────────────────');
          }
        } catch (e) {
          // Ignore source reading errors quietly to not break the report
        }
      }
    }

    if (target == CompileTarget.wasm) {
      print('\n=== Deep Dive Analysis: Extracting Wasm Disassembly ===');
      final watFile = File(p.join(outDir.path, 'main.wat'));

      // 1. Dump the entire Wasm module to WAT once (it's fast with wasm-tools)
      final dumpResult = await Process.run('wasm-tools', [
        'print',
        '$buildPath/main.dart.wasm',
        '-o',
        watFile.path,
      ]);

      if (dumpResult.exitCode == 0) {
        // 2. Identify all identifiers (names or indices) we want to extract
        final identifiers = report.hotFunctions
            .map((f) => f.wasmFunctionIndex?.toString() ?? f.name)
            .where((id) => id.isNotEmpty)
            .toList();

        // 3. Extract all at once
        final instructionsMap = extractWasmFunctions(watFile.path, identifiers);

        // 4. Populate the report model
        for (final f in report.hotFunctions) {
          final id = f.wasmFunctionIndex?.toString() ?? f.name;
          f.wasmInstructions = instructionsMap[id];
        }

        print(
          'Successfully extracted disassembly for ${instructionsMap.length} hot functions.',
        );

        // Keep the console output logic for the specific rank requested
        if (analyzeHotspotRank != null) {
          if (analyzeHotspotRank >= 1 &&
              analyzeHotspotRank <= report.hotFunctions.length) {
            final targetFunc = report.hotFunctions[analyzeHotspotRank - 1];
            if (targetFunc.wasmInstructions != null) {
              print(
                '\nDeep Dive Analysis for #${analyzeHotspotRank}: ${targetFunc.name}\n',
              );
              print(targetFunc.wasmInstructions);
            } else {
              print(
                '\nError: Could not find instructions for "${targetFunc.name}".',
              );
            }
          } else {
            print(
              '\nError: --analyze-hotspot rank $analyzeHotspotRank is out of bounds.',
            );
          }
        }
      } else {
        print('Failed to dump WAT: ${dumpResult.stderr}');
      }
    }

    // Generate HTML report (after we've populated wasmInstructions for everyone!)
    final htmlReporter = HtmlReporter();
    await htmlReporter.saveReport(report, 'out/report.html');
  } catch (e) {
    print('Error: $e');
  } finally {
    await controller.stop();
    await server.stop();
    print('Stopped server and Chrome.');
  }
}
