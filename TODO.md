# `flutter_web_perf` Development Roadmap & Backlog

This document outlines the project roadmap, completed milestones, and the backlog of future features to take `flutter_web_perf` to the next level.

---

## 🏆 Completed Milestones

### 1. Core Profiling Orchestration
- [x] Scaffold standalone executable Dart CLI app.
- [x] Automate Chrome DevTools Protocol (CDP) execution.
- [x] Dynamic remote debugging port resolution (`DevToolsActivePort` parsing).
- [x] Custom Shelf HTTP Server hosting static production web assets.
- [x] hermetic process lifecycle management (process cleanups and lock prevention).

### 2. Trace & Profile Processing
- [x] Strongly typed CPU Profile and Trace models.
- [x] Perfetto trace analysis integration using `trace_processor_shell` SQL queries.
- [x] Time breakdowns category distributions: Scripting, Rendering, and GC times.
- [x] High-resolution Frame Health metrics (Intervals, Jank drops, dropped frame rates).

### 3. Precise Method Symbolication
- [x] Native SDK and package mapping (URI Normalization).
- [x] Support resolving mixins, base classes, abstract classes, and extension definitions.
- [x] Wasm-map symbolic hotspot line attribution.
- [x] **`resolveClassForMethod`**: Robust class/method mapping scan that safely recovers from optimized Wasm compiler inline source map line deviations.

### 4. Premium HTML Visualizer & Features
- [x] Dark-mode, glassmorphic, responsive mustache report dashboard.
- [x] Base64 mustache template embedding builder (`generate_template.dart`).
- [x] Side-by-side comparative Optimized vs Unoptimized WAT disassemblies.
- [x] **Copy Markdown Clipboard Integration**: Modern copy helper with elegant "Copied!" checkmark animated feedback.

---

## 🔮 Future Roadmap Backlog

### 🎯 High Priority
*   **CanvasKit Mapping**: Investigate if we can symbolicate `wasm-function[...]` names inside Skia CanvasKit if we are supplied with CanvasKit debug builds.
*   **Expanded Trace SQL Categorizations**: Map auxiliary Chrome trace events to completely eliminate "Unknown/Other" block categories in the timeline breakdown.
*   **Interactive Charts**: Integrate a lightweight plotting library (e.g., Chart.js) into the HTML template to let users inspect frame intervals and spikes interactively.

### 💡 Research Ideas & Enhancements
*   **Wasm Instruction Breakdown**: Analyze the WAT disassembly and print Wasm instruction type histograms (e.g. 45% `struct.get`, 20% `ref.cast` type-checks) to help developers pinpoint dynamic casting overhead.
*   **JS profiling**: Extend profiling support to JIT compiled JS target profiles.
*   **Continuous Integration (CI) hooks**: Build a Github Action hook to run `flutter_web_perf` on Pull Requests, warning developers if frame drop rate increases.
