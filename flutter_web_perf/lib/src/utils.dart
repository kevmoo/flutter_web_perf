import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Scans a Dart source file backwards from [lineNumber] to find the enclosing
/// class, mixin, or extension name.
String? findEnclosingClass(String filePath, int lineNumber) {
  try {
    final file = File(filePath);
    if (!file.existsSync()) return null;

    final lines = file.readAsLinesSync();
    final startIdx = (lineNumber - 1).clamp(0, lines.length - 1);

    final classRegExp = RegExp(
      r'^\s*(?:abstract\s+|base\s+|interface\s+|final\s+|sealed\s+)?class\s+(\w+)',
    );
    final mixinRegExp = RegExp(r'^\s*mixin\s+(\w+)');
    final extensionRegExp = RegExp(r'^\s*extension\s+(?:on\s+)?(\w+)');

    for (var i = startIdx; i >= 0; i--) {
      final line = lines[i];

      var match = classRegExp.firstMatch(line);
      if (match != null) return match.group(1);

      match = mixinRegExp.firstMatch(line);
      if (match != null) return match.group(1);

      match = extensionRegExp.firstMatch(line);
      if (match != null) return match.group(1);
    }
  } catch (_) {}
  return null;
}

Map<String, String>? _packageMap;

/// Resolves a `package:` URI to its absolute local file path using
/// the `.dart_tool/package_config.json` found by searching upwards from [projectRoot].
String? resolvePackageUri(String packageUrl, String projectRoot) {
  if (!packageUrl.startsWith('package:')) return null;

  if (_packageMap == null) {
    _packageMap = <String, String>{};
    try {
      var currentDir = Directory(projectRoot);
      File? configFile;
      while (true) {
        final candidate = File(
          p.join(currentDir.path, '.dart_tool', 'package_config.json'),
        );
        if (candidate.existsSync()) {
          configFile = candidate;
          break;
        }
        final parent = currentDir.parent;
        if (parent.path == currentDir.path) break;
        currentDir = parent;
      }

      if (configFile != null) {
        final config =
            json.decode(configFile.readAsStringSync()) as Map<String, dynamic>;
        final packages = config['packages'] as List;
        for (final pkg in packages.cast<Map<String, dynamic>>()) {
          final name = pkg['name'] as String;
          var rootUriStr = pkg['rootUri'] as String;
          final packageUriStr = pkg['packageUri'] as String? ?? 'lib/';

          // If it's relative, resolve it relative to the config directory
          if (!rootUriStr.startsWith('file://')) {
            final absoluteRoot = p.normalize(
              p.join(currentDir.path, rootUriStr),
            );
            rootUriStr = Uri.directory(absoluteRoot).toString();
          }

          if (!rootUriStr.endsWith('/')) {
            rootUriStr += '/';
          }

          final packageRoot = Uri.parse(rootUriStr).resolve(packageUriStr);
          _packageMap![name] = packageRoot.toFilePath();
        }
      }
    } catch (_) {}
  }

  try {
    final uri = Uri.parse(packageUrl);
    final packageName = uri.pathSegments.first;
    final relativePath = uri.pathSegments.skip(1).join('/');
    final packagePath = _packageMap![packageName];
    if (packagePath != null) {
      return p.join(packagePath, relativePath);
    }
  } catch (_) {}
  return null;
}

/// Resets the cached package configuration map (useful for testing).
void resetPackageCache() {
  _packageMap = null;
}

/// Scans a Dart source file downwards starting from [className]'s declaration
/// to find the exact line number where [methodName] is declared.
int? findMethodDeclarationLine(
  String filePath,
  String className,
  String methodName,
) {
  try {
    final file = File(filePath);
    if (!file.existsSync()) return null;

    final lines = file.readAsLinesSync();

    // 1. Find the class declaration line first
    final classRegExp = RegExp(
      r'^\s*(?:abstract\s+|base\s+|interface\s+|final\s+|sealed\s+)?class\s+' +
          RegExp.escape(className) +
          r'\b',
    );
    final mixinRegExp = RegExp(
      r'^\s*mixin\s+' + RegExp.escape(className) + r'\b',
    );
    final extensionRegExp = RegExp(
      r'^\s*extension\s+(?:on\s+)?' + RegExp.escape(className) + r'\b',
    );

    var classLineIdx = -1;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (classRegExp.hasMatch(line) ||
          mixinRegExp.hasMatch(line) ||
          extensionRegExp.hasMatch(line)) {
        classLineIdx = i;
        break;
      }
    }

    if (classLineIdx == -1) return null;

    // 2. Search downwards from class declaration line to find method
    // declaration
    final String searchMethodName;
    if (methodName == '==') {
      searchMethodName = r'operator\s*==';
    } else {
      searchMethodName = RegExp.escape(methodName);
    }

    final methodRegExp = RegExp(r'\b' + searchMethodName + r'\s*\(');

    // Boundaries to stop search (any other class/mixin/extension)
    final anyClassRegExp = RegExp(
      r'^\s*(?:abstract\s+|base\s+|interface\s+|final\s+|sealed\s+)?class\s+\w+',
    );
    final anyMixinRegExp = RegExp(r'^\s*mixin\s+\w+');
    final anyExtensionRegExp = RegExp(r'^\s*extension\s+(?:on\s+)?\w+');

    for (var i = classLineIdx; i < lines.length; i++) {
      final line = lines[i];

      // If we hit another class/mixin/extension declaration, stop!
      if (i > classLineIdx &&
          (anyClassRegExp.hasMatch(line) ||
              anyMixinRegExp.hasMatch(line) ||
              anyExtensionRegExp.hasMatch(line))) {
        break;
      }

      if (methodRegExp.hasMatch(line)) {
        return i + 1; // Return 1-based line number!
      }
    }
  } catch (_) {}
  return null;
}

/// Resolves the true enclosing class defining [methodName] in [filePath].
/// If the class enclosing [lineNumber] doesn't define the method (due to source
/// map inline offsets), it scans the entire file to find the correct defining
/// class.
String? resolveClassForMethod(
  String filePath,
  int lineNumber,
  String methodName,
) {
  // 1. Check enclosing class of the sampled line first
  final enclosingClass = findEnclosingClass(filePath, lineNumber);
  if (enclosingClass != null) {
    final line = findMethodDeclarationLine(
      filePath,
      enclosingClass,
      methodName,
    );
    if (line != null) {
      return enclosingClass;
    }
  }

  // 2. Fallback: Scan the entire file for any class/mixin/extension defining it
  try {
    final file = File(filePath);
    if (!file.existsSync()) return null;

    final lines = file.readAsLinesSync();
    final classRegExp = RegExp(
      r'^\s*(?:abstract\s+|base\s+|interface\s+|final\s+|sealed\s+)?class\s+(\w+)',
    );
    final mixinRegExp = RegExp(r'^\s*mixin\s+(\w+)');
    final extensionRegExp = RegExp(r'^\s*extension\s+(?:on\s+)?(\w+)');

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      String? candClass;

      var match = classRegExp.firstMatch(line);
      if (match != null) {
        candClass = match.group(1);
      } else {
        match = mixinRegExp.firstMatch(line);
        if (match != null) {
          candClass = match.group(1);
        } else {
          match = extensionRegExp.firstMatch(line);
          if (match != null) {
            candClass = match.group(1);
          }
        }
      }

      if (candClass != null) {
        final line = findMethodDeclarationLine(filePath, candClass, methodName);
        if (line != null) {
          return candClass;
        }
      }
    }
  } catch (_) {}
  return null;
}
