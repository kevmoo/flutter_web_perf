# 🔮 flutter_web_perf Advanced Diagnostics Backlog

This document details the strategic roadmap for introducing automated, generic diagnostic scanners into `flutter_web_perf`. The goal is to dynamically identify Wasm compilation pitfalls—such as unboxed primitive boxing, generic parameter allocations, and dynamic casting loops—without hardcoding framework gotchas.

---

## 1. ⚙️ Static WAT Assembly Scanner (Dynamic Allocation Churn Detector)

Analyze Wasm disassemblies statically to flag functions that are generating massive heap allocation pressure or dynamic cast loops, even if their direct CPU footprint appears small.

### 🛠️ Implementation Blueprint
1. **Isolate Target Blocks**: The tool already extracts and isolates Wasm disassemblies for the top 10 hot functions inside `extractWasmFunctions` in [wasm_parser.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/wasm_parser.dart).
2. **Token-Count Parser**: Add a static parsing pass inside `wasm_parser.dart` to scan the extracted WAT text block for specific instruction signatures:
   * **Heap Primitives**: Match `struct.new $BoxedDouble` or `struct.new $BoxedInt` (under standard `dart2wasm` boxing models).
   * **Type Verification**: Match `ref.cast`, `ref.test`, or `br_on_cast` instructions.
3. **HTML Visualization**: Display a dashboard badge/warning next to each hotspot in `report.html` showing an **Instruction Histogram**:
   ```text
   ⚠️ Allocation Churn Warning:
   This function spent only 1.2% CPU direct time, but contains 2 heap allocations (struct.new $BoxedInt) 
   and 3 dynamic type checks (ref.cast) in its Wasm instruction flow.
   ```

---

## 2. 🗺️ The "Rosetta Stone" Call-Stack Diff (Paired O4/O0 Analysis)

Compare optimized production profiles (`-O4`) against unoptimized profiles (`-O0`) to recover the architectural identity of inlined primitive helpers (like `.abs()`, `math.max()`, `math.min()`, and `.clamp()`).

### 🛠️ Implementation Blueprint
1. **Coordinate Dual Runs**: Execute both unoptimized (`-O0`) and optimized (`-O4`) compilation and profiling runs.
2. **Tree Diffing Pass**: Write a comparison analyzer in `trace_analyzer.dart`:
   * Locate each hotspot function in the optimized CPU profile.
   * Find the corresponding execution node in the unoptimized `-O0` CPU profile.
   * Identify child frames present in `-O0` that were **completely inlined** (flattened) in the optimized run.
3. **Symbolic Attribution**: Display a virtual **Inlining Breakdown** in the final `report.html`:
   ```text
   🔍 Inlining Breakdown (mapped via unoptimized trace):
   In production, `Priority.+` took 120ms. The O0 Rosetta diff reveals that the following inlined helpers drove this cost:
   - int.abs(): ~65% of unoptimized time
   - int.>: ~25% of unoptimized time
   ```

---

## 📈 3. Dynamic Allocation Sampler via Chrome CDP

Automate the Chrome DevTools Protocol (CDP) to capture allocation footprints and track down which functions are allocating the highest quantities of boxed primitive wrappers.

### 🛠️ Implementation Blueprint
1. **Leverage CDP Heap Profiling**:
   * In [chrome_controller.dart](file:///Users/kevmoo/github/kevmoo/flutter_web_perf/flutter_web_perf/lib/src/chrome_controller.dart), initiate a heap sampling session alongside the CPU tracer:
     ```json
     {"method": "HeapProfiler.startSampling", "params": {"samplingInterval": 32768}}
     ```
   * Stop the session at the end of the trace and serialize the output `heap_profile.json`.
2. **Allocation Attribution**:
   * Parse the resulting allocation nodes. Identify functions allocating the largest numbers of `$BoxedDouble` and `$BoxedInt` structs.
3. **Actionable GC Metrics**:
   * Print a dedicated **Allocation Churn Leaderboard** in `report.html` detailing the exact byte volume and count of primitive boxes spawned per frame:
     ```text
     🏆 Top GC Churn Generators:
     1. Priority.+: 45,000 allocations ($BoxedInt) / 1.2 MB total.
     2. _areaOfUnion: 32,000 allocations ($BoxedDouble) / 800 KB total.
     ```
