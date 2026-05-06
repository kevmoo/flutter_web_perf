# Project Architecture & Technical Learnings

This document outlines the software engineering designs, core components, and critical technical learnings established for the `flutter_web_perf` profiling tool.

---

## 🚀 Project Overview
`flutter_web_perf` is a command-line tool designed to automate building, serving, and profiling Flutter Web applications. It supports both JavaScript (`js`) and WebAssembly (`wasm`) compile targets, automates Chrome via the Chrome DevTools Protocol (CDP), symbolicates profiling data using Wasm source maps, and compiles the results into a premium visual HTML report.

---

## 🛠 Architecture & Key Components

### 1. Orchestration & CLI Concerns Separation
*   [flutter_web_perf.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/bin/flutter_web_perf.dart): The console executable entry point. It encapsulates all `ArgParser` definitions, parameter mappings, and CLI type conversions.
*   [entry_point.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/entry_point.dart): Completely decoupled from `package:args`! Exposes a strongly-typed, named `runApp` API signature for clean library execution.
*   [chrome_controller.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/chrome_controller.dart): Launches a hermetic instance of headless Chrome. It leverages dynamic remote debugger port allocation (`0`) and hooks into the CDP `Profiler` and `Tracing` domains to extract V8 traces and high-resolution CPU profiles.

### 2. Wasm Multithreading Support
*   [server.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/server.dart): Features a Shelf Pipeline middleware injecting **COOP (`Cross-Origin-Opener-Policy: same-origin`)** and **COEP (`Cross-Origin-Embedder-Policy: require-corp`)** headers. These are strictly required by modern browsers to enable `SharedArrayBuffer`. Serving them allows SkWasm to spawn a dedicated multithreaded Web Worker thread (`DedicatedWorker thread`) under the hood, shifting heavy rendering tasks off the main thread!

### 3. Centralized Type-Safe Category Domain Model
*   [performance_report.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/performance_report.dart): Defines the **`PerformanceCategory`** enum using required named constructor parameters. Centralizes the human-readable `label`, Perfetto database `sqlPatterns`, and a domain-driven `shortLabel` getter:

```dart
enum PerformanceCategory {
  flutterBuild(
    label: 'Flutter Build',
    sqlPatterns: ['BUILD', 'Build', 'BuildOwner%'],
  ),
  ...
  const PerformanceCategory({required this.label, required this.sqlPatterns});
}
```
This strongly types the `timeBreakdown` map as `Map<PerformanceCategory, double>` across all components, completely eliminating all hardcoded magic strings and spelling typos.

### 4. Dynamic SQL Case Generation & Advanced Analysis
*   [trace_analyzer.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/trace_analyzer.dart): Connects to Perfetto's `trace_processor_shell`. Instead of hardcoding SQL cases, it **dynamically generates the SQL `CASE WHEN` blocks and `WHERE` filter strings directly from the `PerformanceCategory` enum metadata at runtime!**
*   **Main-Thread Filter & Process Tracks:** Performs a `LEFT JOIN` with `thread_track` and `thread` filtering `(t.name = 'CrRendererMain' OR t.name IS NULL)`. This successfully captures process-level timeline events (like `BUILD` and `LAYOUT`) which lack thread tracks, while cleanly excluding parallel compositor and Web Worker thread slices.

### 5. Premium HTML Visualizer
*   [html_reporter.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/html_reporter.dart): Renders a glowing, dark-mode glassmorphic HTML dashboard.
*   **Nested CPU Subtraction:** To prevent double-counting due to recursive child slices (e.g. nesting layout calls), the visualizer mathematically subtracts child times (`Build`, `Layout`, `Paint`) from the parent `JS Scripting` container, rendering the true, exclusive `'JS Scripting (other)'` platform overhead.
*   **Dynamic 10% Increment Scaling:** Progress bars dynamically scale to the next 10% multiple based on the maximum category value (e.g. scaling up to `30%` bounds), optimizing screen space while keeping mathematically precise labels.
*   **Perfect Grid Alignments:** Utilizes a pixel-perfect 3-column CSS Grid that aligns all category labels, progress tracks, and metric values perfectly.
*   **High-Contrast Badge Overlays:** Overlays a 50% larger, bold, and dark glowing navy text badge inside the bar for high readability, using a `12%` scale threshold to prevent text overflows on tiny progress bars.

---

## 💡 Key Design Decisions & Learnings

> [!NOTE]
> **V8 CPU Profile Main-Thread Constraint**: CDP CPU Profiling is bound directly to the main document context Renderer main thread JS execution target. This guarantees that every single sample listed in the Top 10 Hot Functions list represents actual main thread blocks!

> [!IMPORTANT]
> **Frame Phase Attributions**: Hotspot function phase tags are resolved by recursively traversing the call stack node IDs inside the CPU profile. If a sample's call stack walks through `BuildOwner.buildScope` it is classified as `BUILD`, `RenderObject.layout` is classified as `LAYOUT`, and `RenderObject.paint` is classified as `PAINT`.

---

## 🧪 Testing Suite
Validate and verify updates by running the complete, fully automated, and isolated test suite:
```bash
dart test
```
*   **Isolated E2E temporary Directories**: E2E tests are completely isolated. They allocate a clean system temporary directory before each test and pass `-o tempOutDir.path` to CLI sub-processes, guaranteeing that E2E operations **never** modify or overwrite your local `/out` directory!
