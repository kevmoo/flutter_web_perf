# Flutter Web Performance Profiler (`flutter_web_perf`)

`flutter_web_perf` is an easy-to-use command-line tool designed to automate compiling, serving, and profiling Flutter Web applications. By bridging the gap between high-level Flutter source code, Perfetto CPU traces, and raw WebAssembly Text (WAT) execution data, it symbolicates hotspots with 100% precision and generates a premium, side-by-side optimized vs unoptimized disassembly visualization report.

---

## ✨ Key Features

* **⚡ Dynamic Tracing & Profiling**: Automates hermetic Chrome DevTools Protocol (CDP) interaction to capture high-resolution traces and CPU profiles.
* **🎯 Precise Method Symbolication**: Resolves source map inline offset deviations dynamically to locate exact class/mixin method header signatures in your code.
* **🔍 Side-by-Side Wasm Comparative Analysis**: Extracts and displays the raw Wasm instructions for hotspots before and after Binaryen optimization passes.
* **📋 clipboard Integration**: Copy precise comparative markdown code blocks with a single click directly to another agent or tool.
* **📊 Beautiful HTML Visualizer**: Renders a dark-mode glassmorphic performance dashboard detailing Frame Health, time breakdowns, and hot functions.

---

## 🚀 Quickstart Guide

### 1. Installation
Clone the repository and ensure that your local Flutter SDK is in your path:
```bash
git clone https://github.com/kevmoo/flutter_web_perf.git
cd flutter_web_perf/flutter_web_perf
flutter pub get
```

### 2. Profiling an Application
Run the profiler by pointing it to your Flutter web application directory (`-d` / `--app-dir` option):

```bash
dart bin/flutter_web_perf.dart -t wasm -d /path/to/your/flutter_app
```

### 3. CLI Options & Parameters
* **`-t, --target`**: The compile target for the web app. Allowed: `js`, `wasm` (Defaults to `wasm`).
* **`-d, --app-dir`**: The path to the Flutter application directory to profile (Defaults to `../sample_app`).
* **`-q, --query`**: Optional URL query string to append when loading the app in Chrome (e.g. `mode=skwasm&stress=heavy`).
* **`-o, --output-dir`**: Output directory for `trace.json`, `profile.json`, `main.wat`, and `report.html` (Defaults to `out`).
* **`-a, --analyze-only`**: Skip building and running Chrome; re-analyze existing `trace.json` and `profile.json` in `--output-dir` in ~2 seconds.
* **`--analyze-hotspot`**: Provide the 1-based rank of the hot function to deeply analyze using side-by-side Wasm disassembly (`main.wat` vs `main.unopt.wat`).

---

## 📂 Repository Documentation

* **[Agent & Workflow Guide](AGENTS.md)**: Step-by-step profiling workflow, fast 2-second offline `-a` re-analysis loop, side-by-side WAT disassembly (`--analyze-hotspot`), and symbolication invariants.
* **[Architecture Guide](docs/architecture.md)**: Component design, CDP controls, strongly-typed models, and developer learnings.
