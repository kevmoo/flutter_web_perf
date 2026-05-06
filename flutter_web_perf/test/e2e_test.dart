import 'dart:io';
import 'package:test/test.dart';

void main() {
  group('flutter_web_perf E2E', () {
    setUp(() {
      // Clean up previous runs
      final outDir = Directory('out');
      if (outDir.existsSync()) {
        outDir.deleteSync(recursive: true);
      }
    });

    test(
      'runs wasm target and extracts hotspot',
      () async {
        print(
          'Starting Wasm E2E run (this will take a while as it builds '
          'Flutter Web)...',
        );
        final process = await Process.run(Platform.resolvedExecutable, [
          'run',
          'bin/flutter_web_perf.dart',
          '-t',
          'wasm',
          '--analyze-hotspot=2',
        ]);

        if (process.exitCode != 0) {
          print('stdout: ${process.stdout}');
          print('stderr: ${process.stderr}');
        }

        expect(
          process.exitCode,
          0,
          reason: 'Process failed with: ${process.stderr}',
        );

        final stdout = process.stdout as String;
        expect(stdout, contains('Target: wasm'));
        expect(stdout, contains('Build successful.'));
        expect(stdout, contains('=== Performance Report Summary ==='));
        expect(stdout, contains('=== Top 10 Hot Functions ==='));

        expect(
          stdout.contains('=== Deep Dive Analysis:') ||
              stdout.contains('Error: Function'),
          isTrue,
          reason:
              'Should either perform analysis or gracefully report a '
              'missing index.',
        );

        expect(File('out/trace.json').existsSync(), isTrue);
        expect(File('out/profile.json').existsSync(), isTrue);
        expect(File('out/profile_symbolicated.json').existsSync(), isTrue);
        expect(File('out/report.html').existsSync(), isTrue);

        final reportContent = File('out/report.html').readAsStringSync();
        expect(reportContent, contains('Top 10 Hot Functions'));
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test('runs js target successfully', () async {
      print(
        'Starting JS E2E run (this will take a while as it builds '
        'Flutter Web)...',
      );
      final process = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/flutter_web_perf.dart',
        '-t',
        'js',
      ]);

      if (process.exitCode != 0) {
        print('stdout: ${process.stdout}');
        print('stderr: ${process.stderr}');
      }

      expect(
        process.exitCode,
        0,
        reason: 'Process failed with: ${process.stderr}',
      );

      final stdout = process.stdout as String;
      expect(stdout, contains('Target: js'));
      expect(stdout, contains('Build successful.'));
      expect(stdout, contains('=== Performance Report Summary ==='));
      expect(stdout, contains('=== Top 10 Hot Functions ==='));

      expect(File('out/trace.json').existsSync(), isTrue);
      expect(File('out/profile.json').existsSync(), isTrue);
      expect(File('out/profile_symbolicated.json').existsSync(), isTrue);
      expect(File('out/report.html').existsSync(), isTrue);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
