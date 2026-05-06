import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('flutter_web_perf E2E', () {
    late Directory tempOutDir;

    setUp(() async {
      tempOutDir = await Directory.systemTemp.createTemp('e2e_out_');
    });

    tearDown(() async {
      await tempOutDir.delete(recursive: true);
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
          '-o',
          tempOutDir.path,
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

        expect(
          File(p.join(tempOutDir.path, 'trace.json')).existsSync(),
          isTrue,
        );
        expect(
          File(p.join(tempOutDir.path, 'profile.json')).existsSync(),
          isTrue,
        );
        expect(
          File(
            p.join(tempOutDir.path, 'profile_symbolicated.json'),
          ).existsSync(),
          isTrue,
        );
        expect(
          File(p.join(tempOutDir.path, 'report.html')).existsSync(),
          isTrue,
        );

        final reportContent = File(
          p.join(tempOutDir.path, 'report.html'),
        ).readAsStringSync();
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
        '-o',
        tempOutDir.path,
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

      expect(File(p.join(tempOutDir.path, 'trace.json')).existsSync(), isTrue);
      expect(
        File(p.join(tempOutDir.path, 'profile.json')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(tempOutDir.path, 'profile_symbolicated.json')).existsSync(),
        isTrue,
      );
      expect(File(p.join(tempOutDir.path, 'report.html')).existsSync(), isTrue);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
