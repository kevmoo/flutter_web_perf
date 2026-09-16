import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

final _anyClassRegExp = RegExp(
  r'^\s*(?:abstract\s+|base\s+|interface\s+|final\s+|sealed\s+)?class\s+(\w+)',
);
final _anyMixinRegExp = RegExp(r'^\s*mixin\s+(\w+)');
final _anyExtensionRegExp = RegExp(
  r'^\s*extension\s+(?:type\s+)?(?:on\s+)?(\w+)',
);

String? _matchTypeDeclarationName(String line) {
  return _anyClassRegExp.firstMatch(line)?.group(1) ??
      _anyMixinRegExp.firstMatch(line)?.group(1) ??
      _anyExtensionRegExp.firstMatch(line)?.group(1);
}

/// Scans a Dart source file backwards from [lineNumber] to find the enclosing
/// class, mixin, or extension name.
String? findEnclosingClass(String filePath, int lineNumber) {
  try {
    final file = File(filePath);
    if (!file.existsSync()) return null;

    final lines = file.readAsLinesSync();
    if (lines.isEmpty) return null;
    final startIdx = (lineNumber - 1).clamp(0, lines.length - 1);

    for (var i = startIdx; i >= 0; i--) {
      final matched = _matchTypeDeclarationName(lines[i]);
      if (matched != null) return matched;
    }
  } catch (_) {}
  return null;
}

Map<String, String>? _packageMap;

/// Resolves a `package:` URI to its absolute local file path using
/// the `.dart_tool/package_config.json` found by searching upwards from
/// [projectRoot].
String? resolvePackageUri(String packageUrl, String projectRoot) {
  if (!packageUrl.startsWith('package:')) return null;

  _packageMap ??= _loadPackageMap(projectRoot);

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

Map<String, String> _loadPackageMap(String projectRoot) {
  final map = <String, String>{};
  try {
    final configFile = _findPackageConfigFile(Directory(projectRoot));
    if (configFile == null) return map;

    final configDir = configFile.parent.parent;
    final config =
        json.decode(configFile.readAsStringSync()) as Map<String, dynamic>;
    final packages = (config['packages'] as List).cast<Map<String, dynamic>>();
    for (final pkg in packages) {
      final name = pkg['name'] as String;
      final rootUri = _resolveRootUri(pkg['rootUri'] as String, configDir.path);
      final packageUriStr = pkg['packageUri'] as String? ?? 'lib/';
      map[name] = rootUri.resolve(packageUriStr).toFilePath();
    }
  } catch (_) {}
  return map;
}

File? _findPackageConfigFile(Directory startDir) {
  var currentDir = startDir;
  while (true) {
    final candidate = File(
      p.join(currentDir.path, '.dart_tool', 'package_config.json'),
    );
    if (candidate.existsSync()) return candidate;
    final parent = currentDir.parent;
    if (parent.path == currentDir.path) return null;
    currentDir = parent;
  }
}

Uri _resolveRootUri(String rootUriStr, String baseDirPath) {
  var normalized = rootUriStr;
  if (!normalized.startsWith('file://')) {
    final absoluteRoot = p.normalize(p.join(baseDirPath, normalized));
    normalized = Uri.directory(absoluteRoot).toString();
  }
  if (!normalized.endsWith('/')) {
    normalized = '$normalized/';
  }
  return Uri.parse(normalized);
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
    final classLineIdx = _findTypeDeclarationLineIndex(lines, className);
    if (classLineIdx == -1) return null;

    final searchMethodName = methodName == '=='
        ? r'operator\s*=='
        : RegExp.escape(methodName);
    final methodRegExp = RegExp(r'\b' + searchMethodName + r'\s*\(');

    for (var i = classLineIdx; i < lines.length; i++) {
      final line = lines[i];
      if (i > classLineIdx && _matchTypeDeclarationName(line) != null) {
        break;
      }
      if (methodRegExp.hasMatch(line)) {
        return i + 1;
      }
    }
  } catch (_) {}
  return null;
}

int _findTypeDeclarationLineIndex(List<String> lines, String className) {
  for (var i = 0; i < lines.length; i++) {
    if (_matchTypeDeclarationName(lines[i]) == className) {
      return i;
    }
  }
  return -1;
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
  final enclosingClass = findEnclosingClass(filePath, lineNumber);
  if (enclosingClass != null &&
      findMethodDeclarationLine(filePath, enclosingClass, methodName) != null) {
    return enclosingClass;
  }

  try {
    final file = File(filePath);
    if (!file.existsSync()) return null;

    for (final line in file.readAsLinesSync()) {
      final candClass = _matchTypeDeclarationName(line);
      if (candClass != null &&
          findMethodDeclarationLine(filePath, candClass, methodName) != null) {
        return candClass;
      }
    }
  } catch (_) {}
  return null;
}

/// Resolves a URL to a local file path.
String? resolveLocalFilePath(
  String url, {
  required String localFlutterRepo,
  required String appDir,
}) {
  if (url.startsWith('org-dartlang-sdk:///lib/')) {
    return url.replaceFirst(
      'org-dartlang-sdk:///lib/',
      '$localFlutterRepo/engine/src/flutter/lib/web_ui/lib/',
    );
  } else if (url.startsWith('package:')) {
    return resolvePackageUri(url, p.absolute(appDir));
  } else if (url.startsWith('file://')) {
    try {
      return Uri.parse(url).toFilePath();
    } catch (_) {}
  } else if (p.isAbsolute(url)) {
    return url;
  }
  return null;
}
