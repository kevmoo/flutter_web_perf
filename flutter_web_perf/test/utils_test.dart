import 'dart:io';

import 'package:flutter_web_perf/src/utils.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('findEnclosingClass', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('enclosing_class_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('resolves enclosing class from line number', () {
      final file = File(p.join(tempDir.path, 'test_class.dart'));
      file.writeAsStringSync('''
class EnclosingClass {
  void methodOne() {
    // Sample line
  }
}
''');

      expect(findEnclosingClass(file.path, 3), 'EnclosingClass');
    });

    test('resolves abstract, base, sealed, interface, final classes', () {
      final file = File(p.join(tempDir.path, 'test_abstract.dart'));
      file.writeAsStringSync('''
abstract class MyAbstractClass {}
base class MyBaseClass {}
sealed class MySealedClass {}
interface class MyInterfaceClass {}
final class MyFinalClass {}
''');

      expect(findEnclosingClass(file.path, 1), 'MyAbstractClass');
      expect(findEnclosingClass(file.path, 2), 'MyBaseClass');
      expect(findEnclosingClass(file.path, 3), 'MySealedClass');
      expect(findEnclosingClass(file.path, 4), 'MyInterfaceClass');
      expect(findEnclosingClass(file.path, 5), 'MyFinalClass');
    });

    test('resolves mixins and extensions', () {
      final file = File(p.join(tempDir.path, 'test_mixin.dart'));
      file.writeAsStringSync('''
mixin MyMixin {
  void mixinMethod() {}
}

extension MyExtension on String {
  void extMethod() {}
}
''');

      expect(findEnclosingClass(file.path, 2), 'MyMixin');
      expect(findEnclosingClass(file.path, 6), 'MyExtension');
    });

    test('returns null for top-level functions', () {
      final file = File(p.join(tempDir.path, 'test_top_level.dart'));
      file.writeAsStringSync('''
void topLevelFunc() {
  // Line 2
}
''');

      expect(findEnclosingClass(file.path, 2), isNull);
    });

    test('returns null for non-existent file', () {
      expect(
        findEnclosingClass(p.join(tempDir.path, 'non_existent.dart'), 1),
        isNull,
      );
    });
  });

  group('resolvePackageUri', () {
    late Directory tempDir;
    late Directory subPackageDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('package_config_test_');
      subPackageDir = Directory(p.join(tempDir.path, 'sub_package'));
      await subPackageDir.create(recursive: true);

      // Write a dummy workspace-level package_config.json
      final configDir = Directory(p.join(tempDir.path, '.dart_tool'));
      await configDir.create();

      final configFile = File(p.join(configDir.path, 'package_config.json'));
      configFile.writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "mock_framework",
      "rootUri": "file:///mock/framework/sdk",
      "packageUri": "lib/",
      "languageVersion": "3.0"
    },
    {
      "name": "relative_package",
      "rootUri": "../relative_path",
      "packageUri": "lib/",
      "languageVersion": "3.0"
    }
  ]
}
''');

      resetPackageCache();
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
      resetPackageCache();
    });

    test('resolves absolute package URLs recursively searching upwards', () {
      // Search starting from the nested sub_package folder
      final resolved = resolvePackageUri(
        'package:mock_framework/src/animation.dart',
        subPackageDir.path,
      );

      expect(resolved, p.join('/mock/framework/sdk/lib', 'src/animation.dart'));
    });

    test(
      'resolves relative package URLs in config recursively searching upwards',
      () {
        final resolved = resolvePackageUri(
          'package:relative_package/src/utils.dart',
          subPackageDir.path,
        );

        // The relative path "../relative_path" resolved relative to tempDir/
        final expectedRoot = p.normalize(
          p.join(tempDir.path, '../relative_path/lib'),
        );
        expect(resolved, p.join(expectedRoot, 'src/utils.dart'));
      },
    );

    test('returns null for non-package URLs', () {
      final resolved = resolvePackageUri(
        'file:///some/absolute/file.dart',
        subPackageDir.path,
      );
      expect(resolved, isNull);
    });
  });

  group('findMethodDeclarationLine', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('method_line_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('finds exact method declaration line inside class', () {
      final file = File(p.join(tempDir.path, 'test_decl.dart'));
      file.writeAsStringSync('''
class SampleClass {
  // Some fields
  final int value;

  void performLayout() {
    // some implementation
  }
}
''');

      final line = findMethodDeclarationLine(
        file.path,
        'SampleClass',
        'performLayout',
      );
      expect(line, 5);
    });

    test('finds operator declarations correctly', () {
      final file = File(p.join(tempDir.path, 'test_operator.dart'));
      file.writeAsStringSync('''
class Box {
  @override
  bool operator ==(Object other) {
    return true;
  }
}
''');

      final line = findMethodDeclarationLine(file.path, 'Box', '==');
      expect(line, 3);
    });

    test('limits method search to specified enclosing class block', () {
      final file = File(p.join(tempDir.path, 'test_boundary.dart'));
      file.writeAsStringSync('''
class ClassA {
  void methodX() {}
}

class ClassB {
  void methodX() {}
}
''');

      final lineA = findMethodDeclarationLine(file.path, 'ClassA', 'methodX');
      final lineB = findMethodDeclarationLine(file.path, 'ClassB', 'methodX');

      expect(lineA, 2);
      expect(lineB, 6);
    });

    test('returns null if class or method is not found', () {
      final file = File(p.join(tempDir.path, 'test_missing.dart'));
      file.writeAsStringSync('''
class ClassA {
  void methodX() {}
}
''');

      expect(findMethodDeclarationLine(file.path, 'ClassB', 'methodX'), isNull);
      expect(findMethodDeclarationLine(file.path, 'ClassA', 'methodY'), isNull);
    });
  });

  group('resolveClassForMethod', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('resolve_class_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('resolves class directly if method is within boundary', () {
      final file = File(p.join(tempDir.path, 'test_direct.dart'));
      file.writeAsStringSync('''
class ClassA {
  void methodX() {}
}
''');

      final result = resolveClassForMethod(file.path, 2, 'methodX');
      expect(result, 'ClassA');
    });

    test(
      'resolves class from anywhere in file if sampled offset is out of bounds',
      () {
        final file = File(p.join(tempDir.path, 'test_bounds.dart'));
        file.writeAsStringSync('''
class HelperClass {
  // helper fields
}

class MainClass {
  void performLayout() {}
}
''');

        // Sampled offset 2 falls inside HelperClass, but performLayout is
        // inside MainClass!
        final result = resolveClassForMethod(file.path, 2, 'performLayout');
        expect(result, 'MainClass');
      },
    );
  });
}
