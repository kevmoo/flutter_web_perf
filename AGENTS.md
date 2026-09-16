# Agent & Workflow Guide for `flutter_web_perf`

`flutter_web_perf` automates compiling, serving, and profiling Flutter Web
applications (`wasm` and `js` targets) using hermetic headless Chrome (CDP),
Perfetto SQL trace analysis (`trace_processor_shell`), Wasm source-map
symbolication, and WebAssembly Text (`wasm2wat`) disassembly.

## End-to-End Profiling Workflow

All commands below run from the `flutter_web_perf/` package directory
(`cd flutter_web_perf`).

### Step 1: Capture a Baseline Profile (`~45–90s`)

Point `-d` (`--app-dir`) at any Flutter web application directory, specify
`-t wasm` (default) or `-t js`, pass optional URL query parameters via `-q`
(`--query`), and write artifacts to a dedicated `-o` (`--output-dir`) folder:

```bash
dart bin/flutter_web_perf.dart \
  -t wasm \
  -d /path/to/flutter_app \
  -q "mode=skwasm&stress=heavy" \
  -o out/run_1
```

What this step executes automatically:

1. **Build**: Runs
   `flutter build web --wasm --profile --no-strip-wasm --source-maps` (or
   `flutter build web --profile -O2 --no-minify --source-maps` for `js`) in the
   target `--app-dir`, plus an unoptimized build (`-O0`) cached as
   `main.unopt.wasm` for side-by-side WAT comparison.
2. **Serve with COOP/COEP**: Starts a local Shelf HTTP server with
   `Cross-Origin-Opener-Policy: same-origin` and
   `Cross-Origin-Embedder-Policy: require-corp` headers so `SharedArrayBuffer`
   and multi-threaded `skwasm` Web Workers work out of the box.
3. **Hermetic CDP Capture**: Launches headless Chrome, navigates to
   `http://127.0.0.1:<port>/?<query>`, waits for engine warmup, and captures a
   5-second Perfetto trace (`trace.json`), V8 CPU profile (`profile.json`), and
   heap allocation profile (`allocations.json`).
4. **Symbolication & Report Generation**: Produces `profile_symbolicated.json`
   and `report.html` in `--output-dir`, plus terminal tables of frame health,
   main-thread phase breakdown, and the Top 10 Hot Functions.

### Step 2: Fast Offline Re-Analysis & Deep-Dive Loop (`~2s`)

Once `trace.json` and `profile.json` are captured in `out/run_1`, **never re-run
the full build/Chrome capture just to inspect a different hotspot or test
changes to `flutter_web_perf`'s analyzer/reporter**.

Pass `-a` (`--analyze-only`) with `--analyze-hotspot <1-10>` to re-run
symbolication, Perfetto SQL queries, WAT disassembly extraction, and HTML report
generation in ~2 seconds:

```bash
dart bin/flutter_web_perf.dart \
  -t wasm \
  -d /path/to/flutter_app \
  -o out/run_1 \
  -a \
  --analyze-hotspot 1
```

When `--analyze-hotspot <rank>` is passed on a `wasm` target:

- `flutter_web_perf` invokes `wasm2wat` (resolved from PATH or via
  `mise where wabt`) to disassemble `main.dart.wasm` -> `out/run_1/main.wat` and
  `main.unopt.wasm` -> `out/run_1/main.unopt.wat`.
- It extracts the exact `(func ...)` body for the ranked hotspot from both files
  and embeds a side-by-side **Optimized (`-O2` / Binaryen) vs. Unoptimized
  (`-O0`)** WAT viewer into `out/run_1/report.html` (with a one-click "Copy
  Markdown to Clipboard" button for sharing with an agent or issue).

### Step 3: Viewing `report.html`

- **Locally**: Open `out/run_1/report.html` directly in Chrome.
- **On Cloudtop / Remote Workstations**: Serve the output directory over HTTP so
  you can open `http://<hostname>:<port>/report.html`:
  ```bash
  python3 -m http.server 8899 --directory out/run_1
  ```

---

## Tool Architecture & Symbolication Invariants

When maintaining or extending `flutter_web_perf`, keep these core invariants in
mind:

1. **Preserving `--no-strip-wasm` Function Names over Inlined Source-Map Spans**
   ([profile_symbolicator.dart](flutter_web_perf/lib/src/profile_symbolicator.dart)):
   - `flutter build web --wasm --profile --no-strip-wasm` keeps the exact Dart
     method name in the Wasm binary's `name` section, which V8 records in
     `callFrame.functionName`.
   - However, `main.dart.wasm.map` maps each instruction's byte offset to the
     _deepest inlined callee_ at that instruction. Overwriting
     `callFrame.functionName` with `span.text` from the source map would
     misattribute parent methods to inlined leaf helpers (e.g. `List.[]` or
     `LinkedHashSet`).
   - Therefore, `_symbolicateCallFrame` preserves any non-empty Wasm
     `functionName` (`hasWasmSymbol`) and only uses the source map to attach the
     Dart source file URL and line number.
2. **Grouping Cross-File Inlined Spans into Single Hotspot Buckets**
   ([trace_analyzer.dart](flutter_web_perf/lib/src/trace_analyzer.dart)):
   - A single Wasm function often contains instructions inlined from multiple
     libraries (e.g. `package:flutter/...` and `dart:collection`).
   - `_ProfileSampleAggregator` keys Wasm functions with real symbol names by
     `f:$funcName` (anchoring the displayed source file/line to the declaration
     file matching the class/method name) so samples for a single Wasm function
     are never fractured into multiple rows.
3. **Collapsing Unmapped `main.dart.wasm` Internal Trampolines**
   ([trace_analyzer.dart](flutter_web_perf/lib/src/trace_analyzer.dart)):
   - Compiler-generated helpers (such as runtime type checks or WasmGC struct
     allocators) often lack a Dart source-map entry, leaving their URL as
     `http://127.0.0.1:<port>/main.dart.wasm`.
   - `_isUnmappedTrampoline` identifies frames whose URL still contains
     `main.dart.wasm` after symbolication and walks up the CPU profile parent
     chain so those samples are attributed to the nearest mapped Dart caller.
4. **Main-Thread (`CrRendererMain`) vs. Worker Thread Scope**:
   - Both the Perfetto SQL query (`t.name = 'CrRendererMain' OR t.name IS NULL`)
     and the CDP `Profiler` domain measure the renderer main thread.
   - Under `skwasm` with COOP/COEP headers, raster work (`SceneBuilder`, canvas
     drawing, Skia C++/Wasm calls) executes on a `DedicatedWorker` thread in
     `trace.json` rather than `CrRendererMain`.

## Running the Test Suite

```bash
# Fast unit tests (~2s, 31 tests across symbolication, trace tree, WAT parser, and reporter)
dart test --exclude-tags e2e

# Full test suite including E2E Wasm + JS builds on ../sample_app (~90s)
dart test
```
