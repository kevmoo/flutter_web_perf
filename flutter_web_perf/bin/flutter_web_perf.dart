import 'package:args/args.dart';
import 'package:flutter_web_perf/src/entry_point.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'target',
      abbr: 't',
      allowed: ['js', 'wasm'],
      defaultsTo: 'wasm',
      help: 'The compile target for the web app.',
    )
    ..addOption(
      'app-dir',
      abbr: 'd',
      defaultsTo: '../sample_app',
      help: 'The path to the Flutter application directory to profile.',
    )
    ..addOption(
      'analyze-hotspot',
      help:
          'Provide the 1-based rank of the hot function to deeply analyze '
          'using Wasm disassembly.',
    )
    ..addFlag(
      'analyze-only',
      abbr: 'a',
      negatable: false,
      help:
          'Skip building and profiling; analyze existing trace/profile files in out/ directly.',
    );

  final results = parser.parse(arguments);
  final targetStr = results['target'] as String;
  final target = targetStr == 'wasm' ? CompileTarget.wasm : CompileTarget.js;
  final analyzeHotspotRank = int.tryParse(
    results['analyze-hotspot'] as String? ?? '',
  );
  final appDir = results['app-dir'] as String;
  final analyzeOnly = results['analyze-only'] as bool? ?? false;

  await runApp(
    target: target,
    appDir: appDir,
    analyzeOnly: analyzeOnly,
    analyzeHotspotRank: analyzeHotspotRank,
  );
}
