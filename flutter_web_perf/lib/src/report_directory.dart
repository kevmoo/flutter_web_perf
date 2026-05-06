import 'dart:io';
import 'package:path/path.dart' as p;

/// Manages the output directory for `flutter_web_perf` profiling artifacts.
///
/// Scaffolds the target directory recursively and exposes strongly typed file
/// hooks.
class PerformanceReportDirectory {
  final String path;

  PerformanceReportDirectory(this.path) {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
  }

  File get traceFile => File(p.join(path, 'trace.json'));
  File get profileFile => File(p.join(path, 'profile.json'));
  File get symbolicatedProfileFile =>
      File(p.join(path, 'profile_symbolicated.json'));
  File get allocationsFile => File(p.join(path, 'allocations.json'));
  File get reportHtmlFile => File(p.join(path, 'report.html'));
  File get mainWatFile => File(p.join(path, 'main.wat'));
  File get unoptimizedWatFile => File(p.join(path, 'main_unoptimized.wat'));
}
