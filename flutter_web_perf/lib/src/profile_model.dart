class CpuProfile {
  final List<CpuProfileNode> nodes;
  final List<int> samples;
  final List<int>? timeDeltas;

  CpuProfile({required this.nodes, required this.samples, this.timeDeltas});

  factory CpuProfile.fromJson(Map<String, dynamic> json) {
    final nodesList = json['nodes'] as List;
    final samplesList = json['samples'] as List;
    final timeDeltasList = json['timeDeltas'] as List?;

    return CpuProfile(
      nodes: nodesList
          .map((e) => CpuProfileNode.fromJson(e as Map<String, dynamic>))
          .toList(),
      samples: samplesList.cast<int>(),
      timeDeltas: timeDeltasList?.cast<int>(),
    );
  }

  Map<String, dynamic> toJson() => {
    'nodes': nodes.map((e) => e.toJson()).toList(),
    'samples': samples,
    if (timeDeltas != null) 'timeDeltas': timeDeltas,
  };
}

class CpuProfileNode {
  final int id;
  final CallFrame callFrame;
  final List<int> children;
  final int hitCount;

  CpuProfileNode({
    required this.id,
    required this.callFrame,
    this.children = const [],
    this.hitCount = 0,
  });

  factory CpuProfileNode.fromJson(Map<String, dynamic> json) {
    return CpuProfileNode(
      id: json['id'] as int,
      callFrame: CallFrame.fromJson(json['callFrame'] as Map<String, dynamic>),
      children: (json['children'] as List?)?.cast<int>() ?? const [],
      hitCount: json['hitCount'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'callFrame': callFrame.toJson(),
    'children': children,
    'hitCount': hitCount,
  };
}

class CallFrame {
  String functionName;
  String url;
  int? lineNumber;
  int? columnNumber;
  int? wasmFunctionIndex;

  CallFrame({
    required this.functionName,
    required this.url,
    this.lineNumber,
    this.columnNumber,
    this.wasmFunctionIndex,
  });

  factory CallFrame.fromJson(Map<String, dynamic> json) {
    final name = json['functionName'] as String? ?? '';
    int? wasmIndex = json['wasmFunctionIndex'] as int?;

    if (wasmIndex == null && name.startsWith('wasm-function[')) {
      final match = RegExp(r'wasm-function\[(\d+)\]').firstMatch(name);
      if (match != null) {
        wasmIndex = int.tryParse(match.group(1)!);
      }
    }

    return CallFrame(
      functionName: name,
      url: json['url'] as String? ?? '',
      lineNumber: json['lineNumber'] as int?,
      columnNumber: json['columnNumber'] as int?,
      wasmFunctionIndex: wasmIndex,
    );
  }

  Map<String, dynamic> toJson() => {
    'functionName': functionName,
    'url': url,
    if (lineNumber != null) 'lineNumber': lineNumber,
    if (columnNumber != null) 'columnNumber': columnNumber,
    if (wasmFunctionIndex != null) 'wasmFunctionIndex': wasmFunctionIndex,
  };
}
