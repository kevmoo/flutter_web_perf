import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'chrome_controller.dart';
import 'server.dart';
import 'trace_analyzer.dart';

Future<void> runApp(List<String> arguments) async {
  final parser = ArgParser();
  // Add options here later

  final results = parser.parse(arguments);
  print('Hello from flutter_web_perf tool!');

  final server = DevServer();
  final controller = ChromeController();

  try {
    // TODO: Use path from arguments or default to sample_app
    final buildPath = '../sample_app/build/web';
    final port = await server.start(buildPath);
    final url = 'http://localhost:$port';

    await controller.start(url);
    print('Chrome started and navigated to $url');

    await controller.startTracing();

    // Wait a bit to collect data
    await Future.delayed(const Duration(seconds: 5));

    final events = await controller.stopTracing();
    print('Collected ${events.length} trace events.');

    final file = File('trace.json');
    await file.writeAsString(json.encode(events));
    print('Saved trace data to ${file.absolute.path}');

    final analyzer = TraceAnalyzer(file.path);
    await analyzer.analyze();
  } catch (e) {
    print('Error: $e');
  } finally {
    await controller.stop();
    await server.stop();
    print('Stopped server and Chrome.');
  }
}
