class TraceEvent {
  final String name;
  final String cat;
  final String ph;
  final int ts;
  final int? dur;
  final Map<String, dynamic>? args;

  TraceEvent({
    required this.name,
    required this.cat,
    required this.ph,
    required this.ts,
    this.dur,
    this.args,
  });

  factory TraceEvent.fromJson(Map<String, dynamic> json) {
    return TraceEvent(
      name: json['name'] as String,
      cat: json['cat'] as String,
      ph: json['ph'] as String,
      ts: json['ts'] as int,
      dur: json['dur'] as int?,
      args: json['args'] as Map<String, dynamic>?,
    );
  }
}
