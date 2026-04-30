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
}
