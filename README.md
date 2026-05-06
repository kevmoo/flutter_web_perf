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
flutter pub run bin/flutter_web_perf.dart -t wasm -d /path/to/your/flutter_app
```

### 3. CLI Options & Parameters
* **`-t, --target`**: The compile target for the web app. Allowed: `js`, `wasm` (Defaults to `wasm`).
* **`-d, --app-dir`**: The path to the Flutter application directory to profile (Defaults to `../sample_app`).
* **`--analyze-hotspot`**: Provide the 1-based rank of the hot function to deeply analyze using Wasm disassembly.

---

## 📂 Repository Documentation

* **[Architecture Guide](docs/architecture.md)**: Component design, CDP controls, strongly-typed models, and developer learnings.
* **[Wasm & Performance Findings](docs/findings/)**: Optimization case studies, compiler deep-dives, and research findings:
  * [01. Dart2Wasm Timeline Overhead](docs/findings/01_dart2wasm_timeline_overhead.md)
  * [02. Dart2Wasm getMasqueradedRuntimeType](docs/findings/02_dart2wasm_getmasqueradedruntimetype.md)
  * [03. Dart2Wasm RuntimeType Equality](docs/findings/03_dart2wasm_runtimetype_equality.md)
  * [04. Dart2Wasm math.min/max Boxing](docs/findings/04_dart2wasm_math_min_max_boxing.md)
  * [05. Dart2Wasm double.clamp Boxing](docs/findings/05_dart2wasm_double_clamp_boxing.md)
  * [dart2wasm Boxing Issue Deep Dive](docs/findings/dart2wasm_boxing_issue.md)
  * [Paired Profiling Analysis](docs/findings/paired_profiling_analysis.md)
  * [Wasm Analysis Ideas](docs/findings/wasm_analysis_ideas.md)
