import 'dart:convert';
import 'dart:io';

import 'chrome_controller.dart';
import 'html_reporter.dart';
import 'performance_report.dart';
import 'profile_symbolicator.dart';
import 'report_directory.dart';
import 'server.dart';
import 'trace_analyzer.dart';
import 'utils.dart';
import 'wasm_parser.dart';

enum CompileTarget { js, wasm }

Future<void> runApp({
  required CompileTarget target,
  required String appDir,
  required String outDir,
  required bool analyzeOnly,
  int? analyzeHotspotRank,
  int? samplingIntervalUs,
}) async {
  final runner = _AppRunner(
    target: target,
    appDir: appDir,
    outDir: outDir,
    analyzeOnly: analyzeOnly,
    analyzeHotspotRank: analyzeHotspotRank,
    samplingIntervalUs: samplingIntervalUs,
  );
  await runner._run();
}

class _AppRunner {
  final CompileTarget _target;
  final String _appDir;
  final bool _analyzeOnly;
  final int? _analyzeHotspotRank;
  final int? _samplingIntervalUs;

  late final String _buildPath;
  late final PerformanceReportDirectory _reportDir;
  final _server = DevServer();
  final _controller = ChromeController();

  _AppRunner({
    required this._target,
    required String appDir,
    required String outDir,
    required this._analyzeOnly,
    this._analyzeHotspotRank,
    this._samplingIntervalUs,
  }) : _appDir = appDir {
    _buildPath = '$appDir/build/web';
    _reportDir = PerformanceReportDirectory(outDir);
  }

  Future<void> _run() async {
    print('Hello from flutter_web_perf tool!');
    print('Target: ${_target.name}');
    print('App Directory: $_appDir');
    if (_analyzeOnly) {
      print('Mode: Analyze-Only (Skipping build & profile runs)');
    }

    if (_analyzeOnly) {
      if (!_reportDir.traceFile.existsSync() ||
          !_reportDir.profileFile.existsSync()) {
        print(
          'Error: Cannot run in --analyze-only mode because trace or profile '
          'files are missing in ${_reportDir.path} directory.',
        );
        print('Please run a full profiling session first.');
        exitCode = 1;
        return;
      }
    }

    try {
      if (!_analyzeOnly) {
        await _runTracePhase();
        await _runProfilePhase();
      }

      await _runAnalysisPhase();
    } catch (e) {
      print('Error: $e');
    } finally {
      await _controller.stop();
      await _server.stop();
      print('Stopped server and Chrome.');
    }
  }

  Future<void> _runFlutterBuild(List<String> args) async {
    final buildResult = await Process.run(
      'flutter',
      args,
      workingDirectory: _appDir,
    );
    if (buildResult.exitCode != 0) {
      throw Exception('Build failed!\n${buildResult.stderr}');
    }
    print('Build successful.');
  }

  Future<void> _runTracePhase() async {
    // --- PHASE 1: TRACE RUN ---
    print('\n=== Phase 1: Trace Run (--profile) ===');
    print('Building app in $_appDir...');
    final traceBuildArgs = ['build', 'web', '--profile', '--source-maps'];
    if (_target == CompileTarget.wasm) traceBuildArgs.add('--wasm');
    await _runFlutterBuild(traceBuildArgs);

    final port = await _server.start(_buildPath);
    final url = 'http://localhost:$port';
    await _controller.start(url);
    print('Chrome started and navigated to $url');

    await _controller.startTracing();
    await Future<void>.delayed(const Duration(seconds: 5));
    final events = await _controller.stopTracing();

    print('Collected ${events.length} trace events.');
    await _reportDir.traceFile.writeAsString(json.encode(events));
    print('Saved trace data to ${_reportDir.traceFile.absolute.path}');

    await _controller.stop();
    await _server.stop();
  }

  Future<void> _runProfilePhase() async {
    // --- PHASE 2: PROFILE RUN ---
    print('\n=== Phase 2: Profile Run (--release) ===');

    // Compile unoptimized build first to capture unoptimized disassembly for
    // comparison
    if (_target == CompileTarget.wasm) {
      print('Building unoptimized app in $_appDir for comparison (-O 0)...');
      final unoptBuildArgs = [
        'build',
        'web',
        '--release',
        '--source-maps',
        '-O',
        '0',
        '--wasm',
      ];
      await _runFlutterBuild(unoptBuildArgs);

      print('Extracting unoptimized Wasm disassembly...');
      final unoptWatFile = _reportDir.unoptimizedWatFile;
      final dumpUnopt = await Process.run('wasm-tools', [
        'print',
        '$_buildPath/main.dart.wasm',
        '-o',
        unoptWatFile.path,
      ]);
      if (dumpUnopt.exitCode != 0) {
        print('Failed to dump unoptimized WAT: ${dumpUnopt.stderr}');
      }
    }

    print('Building fully optimized app in $_appDir (--release)...');
    final profileBuildArgs = ['build', 'web', '--release', '--source-maps'];
    if (_target == CompileTarget.wasm) profileBuildArgs.add('--wasm');
    await _runFlutterBuild(profileBuildArgs);

    final port = await _server.start(_buildPath);
    final url = 'http://localhost:$port';
    await _controller.start(url, enableDebugger: false);
    print('Chrome started and navigated to $url');

    await _controller.startProfiling(intervalUs: _samplingIntervalUs);
    await _controller.startHeapAllocationProfiling();
    await Future<void>.delayed(const Duration(seconds: 5));
    final profile = await _controller.stopProfiling();
    final allocations = await _controller.stopHeapAllocationProfiling();

    await _reportDir.profileFile.writeAsString(json.encode(profile));
    print('Saved profile data to ${_reportDir.profileFile.absolute.path}');
    await _reportDir.allocationsFile.writeAsString(json.encode(allocations));
    print(
      'Saved heap allocation data to '
      '${_reportDir.allocationsFile.absolute.path}',
    );

    await _controller.stop();
    await _server.stop();
  }

  Future<void> _runAnalysisPhase() async {
    // --- ANALYSIS ---
    print('\n=== Phase 3: Analysis ===');
    final mapPath = _target == CompileTarget.wasm
        ? '$_buildPath/main.dart.wasm.map'
        : '$_buildPath/main.dart.js.map';

    final analyzer = TraceAnalyzer(
      _reportDir.traceFile.path,
      sourceMapPath: mapPath,
    );

    final symbolicatedProfile = await symbolicateProfile(
      profilePath: _reportDir.profileFile.path,
      sourceMapPath: mapPath,
    );

    final symbolicatedFile = _reportDir.symbolicatedProfileFile;
    await symbolicatedFile.writeAsString(json.encode(symbolicatedProfile));
    print('Saved symbolicated profile to ${symbolicatedFile.absolute.path}');

    final report = await analyzer.generateReport(
      profilePath: symbolicatedFile.path,
    );

    // Parse and attribute dynamic memory allocations from Heap Sampler
    if (_reportDir.allocationsFile.existsSync()) {
      _attributeAllocations(report);
    }

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
      print('${cat.label}: ${dur.toStringAsFixed(2)} ms');
    });

    await _printHotspotsAndSources(report, flutterSha, localFlutterRepo);

    if (_target == CompileTarget.wasm) {
      await _runWasmDeepDive(report, localFlutterRepo);
    }

    // Generate HTML report (after populating wasmInstructions).
    final htmlReporter = HtmlReporter();
    await htmlReporter.saveReport(report, _reportDir.reportHtmlFile.path);
  }

  void _attributeAllocations(PerformanceReport report) {
    try {
      final heapContent = _reportDir.allocationsFile.readAsStringSync();
      final heapData = json.decode(heapContent) as Map<String, dynamic>;
      final head = heapData['head'] as Map<String, dynamic>?;
      if (head != null) {
        final allocationsByFunction = <String, num>{};
        final allocationsByWasmIndex = <int, num>{};

        var totalAllocatedBytes = 0;

        void accumulate(Map<String, dynamic> node) {
          final callFrame = node['callFrame'] as Map<String, dynamic>?;
          final selfSize = node['selfSize'] as num? ?? 0;
          if (selfSize > 0) {
            totalAllocatedBytes += selfSize.toInt();
            final functionName = callFrame?['functionName'] as String? ?? '';
            final wasmMatch = RegExp(
              r'wasm-function\[(\d+)\]',
            ).firstMatch(functionName);
            if (wasmMatch != null) {
              final index = int.parse(wasmMatch.group(1)!);
              allocationsByWasmIndex[index] =
                  (allocationsByWasmIndex[index] ?? 0) + selfSize;
            } else {
              allocationsByFunction[functionName] =
                  (allocationsByFunction[functionName] ?? 0) + selfSize;
            }
          }

          final children = node['children'] as List?;
          if (children != null) {
            for (final child in children) {
              if (child is Map<String, dynamic>) {
                accumulate(child);
              }
            }
          }
        }

        accumulate(head);
        report.frameHealth.totalAllocatedBytes = totalAllocatedBytes;

        // Attribute to HotFunction list
        for (final f in report.hotFunctions) {
          num? allocatedBytes;
          if (f.wasmFunctionIndex != null) {
            allocatedBytes = allocationsByWasmIndex[f.wasmFunctionIndex!];
          }
          allocatedBytes ??= allocationsByFunction[f.name];

          if (allocatedBytes != null) {
            f.allocationsBytes = allocatedBytes.toInt();
          }
        }
      }
    } catch (e) {
      print('Warning: Failed to parse allocations profile: $e');
    }
  }

  Future<void> _printHotspotsAndSources(
    PerformanceReport report,
    String? flutterSha,
    String localFlutterRepo,
  ) async {
    print('\n=== Top 10 Hot Functions ===');
    for (var i = 0; i < report.hotFunctions.length; i++) {
      final f = report.hotFunctions[i];
      final wasmLabel = f.wasmFunctionIndex != null
          ? ' (Wasm Index: ${f.wasmFunctionIndex})'
          : '';
      print('${i + 1}. ${f.name}$wasmLabel: ${f.samples} samples');

      // Source-Aware Hotspot Analysis!
      if (f.lineNumber != null) {
        try {
          final localFilePath = resolveLocalFilePath(
            f.url,
            localFlutterRepo: localFlutterRepo,
            appDir: _appDir,
          );

          if (localFilePath != null) {
            final sourceFile = File(localFilePath);
            if (await sourceFile.exists()) {
              final className = resolveClassForMethod(
                localFilePath,
                f.lineNumber!,
                f.name,
              );
              int? displayLine;
              if (className != null) {
                displayLine = findMethodDeclarationLine(
                  localFilePath,
                  className,
                  f.name,
                );
              }
              final displayLineNumber = displayLine ?? f.lineNumber!;

              // Generate GitHub URL generically for framework sources
              if (localFilePath.contains('/packages/flutter/lib/')) {
                final suffix = localFilePath
                    .split('/packages/flutter/lib/')
                    .last;
                if (flutterSha != null) {
                  f.githubUrl =
                      'https://github.com/flutter/flutter/blob/$flutterSha/'
                      'packages/flutter/lib/$suffix#L$displayLineNumber';
                }
              }

              final lines = await sourceFile.readAsLines();
              final centerLineIdx = (displayLineNumber - 1).clamp(
                0,
                lines.isNotEmpty ? lines.length - 1 : 0,
              );
              final startLineIdx = (centerLineIdx - 2).clamp(
                0,
                lines.isNotEmpty ? lines.length - 1 : 0,
              );
              final endLineIdx = (centerLineIdx + 3).clamp(0, lines.length);

              print('    📍 ${sourceFile.path}:$displayLineNumber');
              print('    ╭────────────────────────────────────────');
              for (
                var lineIdx = startLineIdx;
                lineIdx < endLineIdx;
                lineIdx++
              ) {
                final prefix = lineIdx == centerLineIdx
                    ? '    │ > '
                    : '    │   ';
                print('$prefix${lines[lineIdx]}');
              }
              print('    ╰────────────────────────────────────────');
            }
          }
        } catch (_) {
          // Ignore source reading errors quietly to not break the report
        }
      }
    }
  }

  Future<void> _runWasmDeepDive(
    PerformanceReport report,
    String localFlutterRepo,
  ) async {
    print('\n=== Deep Dive Analysis: Extracting Wasm Disassembly ===');
    final watFile = _reportDir.mainWatFile;

    // 1. Dump the entire Wasm module to WAT once (it's fast with wasm-tools)
    final dumpResult = await Process.run('wasm-tools', [
      'print',
      '$_buildPath/main.dart.wasm',
      '-o',
      watFile.path,
    ]);

    if (dumpResult.exitCode == 0) {
      // 2. Identify all identifiers (names or indices) we want to extract
      final identifiers = report.hotFunctions
          .map((f) => f.wasmFunctionIndex?.toString() ?? f.name)
          .where((id) => id.isNotEmpty)
          .toList();

      // 3. Extract optimized disassemblies
      final instructionsMap = extractWasmFunctions(watFile.path, identifiers);

      // 4. Extract unoptimized disassemblies by prepending resolved enclosing
      // class/mixin names
      final unoptWatFile = _reportDir.unoptimizedWatFile;
      if (unoptWatFile.existsSync()) {
        final unoptIdentifiers = <String>[];
        final functionToUnoptId = <HotFunction, String>{};

        for (final f in report.hotFunctions) {
          String? unoptId;

          final localFilePath = resolveLocalFilePath(
            f.url,
            localFlutterRepo: localFlutterRepo,
            appDir: _appDir,
          );

          if (localFilePath != null && f.lineNumber != null) {
            try {
              final className = resolveClassForMethod(
                localFilePath,
                f.lineNumber!,
                f.name,
              );
              if (className != null) {
                unoptId = '$className.${f.name}';
              }
            } catch (_) {}
          }

          unoptId ??= f.name;
          unoptIdentifiers.add(unoptId);
          functionToUnoptId[f] = unoptId;
        }

        final extracted = extractWasmFunctions(
          unoptWatFile.path,
          unoptIdentifiers,
        );

        // 5. Populate the report model
        for (final f in report.hotFunctions) {
          final id = f.wasmFunctionIndex?.toString() ?? f.name;
          f.wasmInstructions = instructionsMap[id];
          f.wasmAnalysis = analyzeWasmInstructions(f.wasmInstructions);

          final unoptId = functionToUnoptId[f]!;
          f.wasmInstructionsUnoptimized = extracted[unoptId];
          f.wasmAnalysisUnoptimized = analyzeWasmInstructions(
            f.wasmInstructionsUnoptimized,
          );
        }
      } else {
        // 5. Populate the report model (optimized only)
        for (final f in report.hotFunctions) {
          final id = f.wasmFunctionIndex?.toString() ?? f.name;
          f.wasmInstructions = instructionsMap[id];
          f.wasmAnalysis = analyzeWasmInstructions(f.wasmInstructions);
        }
      }

      print(
        'Successfully extracted disassembly for '
        '${instructionsMap.length} hot functions (optimized & unoptimized).',
      );

      // Keep the console output logic for the specific rank requested
      if (_analyzeHotspotRank != null) {
        if (_analyzeHotspotRank >= 1 &&
            _analyzeHotspotRank <= report.hotFunctions.length) {
          final targetFunc = report.hotFunctions[_analyzeHotspotRank - 1];
          if (targetFunc.wasmInstructions != null) {
            print(
              '\nDeep Dive Analysis for #$_analyzeHotspotRank: '
              '${targetFunc.name}\n',
            );
            print(targetFunc.wasmInstructions);
          } else {
            print(
              '\nError: Could not find instructions for '
              '"${targetFunc.name}".',
            );
          }
        } else {
          print(
            '\nError: --analyze-hotspot rank $_analyzeHotspotRank '
            'is out of bounds.',
          );
        }
      }
    } else {
      print('Failed to dump WAT: ${dumpResult.stderr}');
    }
  }
}
