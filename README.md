# Project Handover & Architecture Notes

Welcome! This document summarizes the engineering work, design decisions, and architecture built for the `flutter_web_perf` profiling tool to help you pick up where the last agent left off.

## 🚀 Project Overview
`flutter_web_perf` is an easy-to-use command-line tool designed to automate building, serving, and profiling Flutter Web applications. It supports both JavaScript (`js`) and WebAssembly (`wasm`) compile targets, automates Chrome via the Chrome DevTools Protocol (CDP), symbolicates profiling data using source maps, and compiles the results into a visually stunning HTML report.

## 🛠 Architecture & Key Components

### 1. Orchestration & Environment
*   [entry_point.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/entry_point.dart): The main CLI orchestrator. It handles automated Flutter builds with necessary profiling flags (`--wasm`, `--source-maps`) and stands up a local `shelf` static server to host the application.
*   [chrome_controller.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/chrome_controller.dart): Launches a hermetic instance of headless Chrome. It leverages dynamic port allocation (`--remote-debugging-port=0`) and hooks into the CDP `Profiler` and `Tracing` domains to extract V8 traces and high-resolution CPU profiles.

### 2. Strongly Typed Models
To strictly adhere to [analysis_options.yaml](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/analysis_options.yaml) (`dart_flutter_team_lints` and `avoid_dynamic_calls`), raw JSON is immediately marshaled into strongly-typed Dart objects:
*   [profile_model.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/profile_model.dart): Models the V8 CPU profile nodes and call frames.
*   [trace_model.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/trace_model.dart): Models core Chrome trace events.
*   [performance_report.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/performance_report.dart): Acts as a bridge between raw analysis logic and the presentation formatters. 

### 3. Advanced Analysis & Symbolication
*   [trace_analyzer.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/trace_analyzer.dart): Instead of writing a fragile Chrome trace parser in Dart, this component relies on a local installation of Perfetto's native `trace_processor_shell`. It writes SQL queries dynamically to extract precise Frame Health and Time Breakdown (Scripting vs Rendering vs GC) metrics.
*   [profile_symbolicator.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/profile_symbolicator.dart): Consumes the mapping provided by `package:source_maps`. Crucially, it provides a standalone, tested `normalizeLocation` function that translates raw SDK paths and complex workspace file URIs into standard `dart:` and `package:` identifiers.

### 4. Premium HTML Reporter & Build Assets
*   [html_reporter.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/html_reporter.dart): Renders a stunning, dark-mode glassmorphic HTML dashboard utilizing `package:mustache_template`.
*   [generate_template.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/tool/generate_template.dart): A small asset builder. To ensure easy zero-dependency standalone distribution of the CLI tool, it base64-encodes [report.mustache](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/resources/report.mustache) and wraps it into 76-character Dart strings to safely respect 80-column lint constraints in [report_template.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/resources/report_template.dart).

## 💡 Key Design Decisions & Learnings

> [!NOTE]
> **Dynamic Remote Ports**: Chrome is explicitly started with port `0`. We await and parse the first line of the `DevToolsActivePort` file dumped inside the user-data directory to accurately resolve the debugger WebSocket URI. This completely prevents port collision issues in parallel test environments.

> [!WARNING]
> **Chrome Process Destruction**: Attempting to recursively delete the Chrome user-data directory immediately following `Process.kill()` will throw a race-condition file lock exception. Always ensure you `await controller.stop()` which internally awaits the process `exitCode` first.

> [!IMPORTANT]
> **Trace Async Event Parsing**: Raw `AnimationFrame` events are async instant markers. They do not carry a `dur` (duration) property natively. Delegating duration calculation via Perfetto's `slice` table is significantly more reliable than manually computing spans between asynchronous event bounds in Dart.

## 🧪 Testing Suite
Coverage is firmly established for crucial logic. You can comfortably validate updates by running:
```bash
dart test test/profile_symbolicator_test.dart
```
It validates `FlutterWebPerfException` boundaries as well as all URI normalization rules (CanvasKit URL pruning, Flutter package mapping, and Dart SDK mapping).

## 🔮 Future Work & Next Steps
*   **CanvasKit Mapping**: Investigate symbolicating `wasm-function[...]` signatures if we are provided with debug-level symbols of CanvasKit.
*   **Exhaustive Trace Breakdown**: Tweak the SQL queries inside [trace_analyzer.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/trace_analyzer.dart) to completely map anomalous Chrome trace categories into the `Scripting`, `Rendering`, and `GC` buckets.
*   **HTML Polish**: Integrate an interactive charting library (e.g., Chart.js) directly into the Mustache HTML template for deeper frame-by-frame data inspection.
