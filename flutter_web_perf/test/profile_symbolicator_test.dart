import 'package:flutter_web_perf/src/exceptions.dart';
import 'package:flutter_web_perf/src/profile_symbolicator.dart';
import 'package:test/test.dart';

void main() {
  group('symbolicateProfile', () {
    test('throws FlutterWebPerfException when profile not found', () async {
      expect(
        () => symbolicateProfile(
          profilePath: 'non_existent.json',
          sourceMapPath: 'map.json',
        ),
        throwsA(isA<FlutterWebPerfException>()),
      );
    });
  });

  group('normalizeLocation', () {
    test('normalizes CanvasKit Wasm URL', () {
      final url =
          'https://www.gstatic.com/flutter-canvaskit/ac260a47e760cf67b4cb82340b38ebf1e23d03b2/chromium/canvaskit.wasm';
      expect(normalizeLocation(url), equals('chromium/canvaskit.wasm'));
    });

    test('normalizes CanvasKit JS URL', () {
      final url =
          'https://www.gstatic.com/flutter-canvaskit/ac260a47e760cf67b4cb82340b38ebf1e23d03b2/chromium/canvaskit.js';
      expect(normalizeLocation(url), equals('chromium/canvaskit.js'));
    });

    test('normalizes SDK URL', () {
      final url =
          'org-dartlang-sdk:///dart-sdk/lib/_internal/js_shared/lib/rti.dart';
      expect(
        normalizeLocation(url),
        equals('dart:_internal/js_shared/lib/rti.dart'),
      );
    });

    test('normalizes Package URL', () {
      final url =
          '../../../../../../flutter/packages/flutter/lib/src/rendering/object.dart';
      expect(
        normalizeLocation(url),
        equals('package:flutter/src/rendering/object.dart'),
      );
    });

    test('leaves normal URL unchanged', () {
      final url = 'http://localhost/main.dart.js';
      expect(normalizeLocation(url), equals(url));
    });
  });
}
