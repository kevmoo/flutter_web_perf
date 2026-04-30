import 'dart:convert';
import 'dart:io';

class TraceAnalyzer {
  final String tracePath;

  TraceAnalyzer(this.tracePath);

  Future<void> analyze() async {
    final file = File(tracePath);
    if (!await file.exists()) {
      print('Trace file not found: $tracePath');
      return;
    }

    final content = await file.readAsString();
    final events = json.decode(content) as List;
    print('Loaded ${events.length} events.');

    // Find frame events
    final frameEvents = events
        .where((e) => e['name'] == 'Scheduler::BeginFrame')
        .toList();
    print('Found ${frameEvents.length} Scheduler::BeginFrame events.');

    // Find slow tasks
    final slowTasks = events.where((e) {
      final dur = e['dur'];
      return dur != null && dur > 16666; // > 16.6ms (approx 60fps)
    }).toList();
    print('Found ${slowTasks.length} tasks slower than 16.6ms.');

    // Sort slow tasks by duration
    slowTasks.sort((a, b) => (b['dur'] as num).compareTo(a['dur'] as num));

    print('\\nTop 5 slowest tasks:');
    for (var i = 0; i < 5 && i < slowTasks.length; i++) {
      final t = slowTasks[i];
      print(
        "Task: ${t['name']}, Duration: ${t['dur']} us, Category: ${t['cat']}",
      );
    }
  }
}
