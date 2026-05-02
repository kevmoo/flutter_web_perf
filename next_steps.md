# Next Steps: Leveraging flutter_web_perf for Optimization

This document outlines brainstormed strategies for using the `flutter_web_perf` tool as a macro-benchmark runner to improve both the `dart2wasm` compiler and the Flutter framework.

## 1. Improving the `dart2wasm` Compiler
Compiler engineers focus on code size, execution speed, and garbage collection behavior. Since `dart2wasm` relies on the WasmGC proposal and JS-interop, this tool can help hunt for overhead in those specific areas.

*   **Pinpointing JS-Interop Overhead:** Wasm code cannot currently manipulate the DOM directly; it must cross the boundary to JavaScript (e.g., via `package:web`). We can analyze the symbolicated V8 CPU profiles to look for time spent in V8's JS-to-Wasm or Wasm-to-JS trampoline functions. A massive spike here provides the `dart2wasm` team with a reproducible test case to optimize interop thunk generation.
*   **WasmGC vs. JS GC Profiling:** `dart2wasm` uses WasmGC, relying on the browser's native garbage collector. The tool currently uses Perfetto to calculate `GC` time. By running identical benchmarks compiled to `js` and `wasm`, if WasmGC causes longer frame-drop pauses than JS GC, we can provide the exact SQL trace data to the V8 and Dart teams to optimize memory allocation patterns.
*   **A/B Testing SDK Versions:** We could add a feature to compare two different local checkouts of the Dart SDK. A compiler engineer could compile a Flutter app with the `main` branch, apply their optimization PR, re-run, and immediately see an HTML report showing the delta in execution time for specific functions.

## 2. Improving the Flutter Framework
Framework engineers care about the cost of building, laying out, and painting widgets. The `sample_app/lib/src/widget_churn.dart` target is a perfect test case for this.

*   **Isolating "Widget Churn" Overhead:** By running the `widget_churn` app, we can examine the CPU profile to see exactly how much time is spent inside `BuildOwner.buildScope` and `Element.updateChild`. If a framework engineer proposes a new way to cache elements or diff widgets, they can run this tool to prove their PR reduces framework overhead.
*   **Framework vs. Engine Boundary (dart:ui):** We can aggregate the symbolicated profile data by package. By bucketing time spent in `package:flutter/...` vs `dart:ui/...`, we can see if the framework is doing too much work in Dart, or if the bottleneck is actually in the underlying CanvasKit/Skia engine.
*   **Startup Time (Time to First Frame):** Flutter Web startup time is a major focus area. We could extend the `trace_analyzer.dart` Perfetto SQL queries to specifically track the duration between the browser's navigation start event and the first Flutter `Rasterize` or `Paint` event.

## Proposed Action Items

1.  **Exhaustive Trace Breakdown:** Tweak the SQL in `trace_analyzer.dart` to extract more granular Flutter-specific lifecycle events (Build, Layout, Paint) instead of just generic "Scripting vs Rendering". *(Currently active)*
2.  **Add a "Diff" Mode:** Allow the CLI to take two profiles (e.g., `baseline` and `experiment`) and generate a side-by-side HTML report. Essential for proving changes.
3.  **CanvasKit/SKWasm Symbolication:** Map `wasm-function[...]` names to actual C++ CanvasKit functions using DWARF symbols or source maps to better understand engine overhead.
