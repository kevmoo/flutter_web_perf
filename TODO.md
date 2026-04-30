I'd love to go on an adventure with you to build a easy-to-use, powerful tool
for profiling Flutter Web application performance.

Big areas I'd like to help folks address:

- Slot frame times
- Jitter or missed frames (Jank)

Technologies to use to inspect the application:

- Chrome dev protocol

Implementation:

- I'd like the tool to be a command line Dart application.

Flexibility:

- If it's helpful for the user to make changes to their application
  - Adding bits to their HTML
  - Changing how the server is hosted locally
  - ETC - that's all fine

- We'll want the user to build the application for "production" on their local machine
  so we can look at the behavior close to "release" mode.

- I want to support web-assembly and JavaScript profiling
  - If we need them to change their compilation setting - let `--no-strip-wasm`
    or to make sure their are source maps, that's fine

- If it's easier to create our own HTTP server that the user points at their build
  output so we can inject things into the running app, that's fine!

- It's also okay if we take over the compilation of the application.

Pondering the user flow:

- User launches the tool and points it at their Flutter web application root and
  "we" just take over.

## Agent brainstorm

Here are some ideas on how we can approach building this tool, breaking it down into architecture, user flow, and technical challenges.

### 1. Architecture & Components
- **CLI Wrapper (Dart)**: The main entry point. It will handle argument parsing, project validation, and orchestrate the build/serve/profile lifecycle.
- **Custom HTTP Server**: Built with `package:shelf`. This allows us to serve the production build assets while dynamically injecting instrumentation scripts or headers (e.g., for COOP/COEP if needed for Wasm).
- **CDP Controller**: Using `package:webkit_inspection_protocol` (or a similar library) to launch Chrome, navigate to the app, and record performance metrics.

### 2. Refined User Flow
- User runs: `flutter_web_perf run .`
- The tool:
  1. Validates it's a Flutter project.
  2. Prompts for target (Wasm or JS) if not specified.
  3. Runs `flutter build web` with appropriate flags (e.g., `--no-strip-wasm` or enabling source maps).
  4. Starts the local server.
  5. Launches Chrome with remote debugging enabled.
  6. Automates user interactions (optional) or waits for the user to interact.
  7. Collects trace data and outputs a report.

### 3. Profiling Strategies
- **Frame Timing**: We need to identify when a frame starts and ends. If Flutter Web emits `console.timeStamp` or similar markers, we can listen for them via CDP.
- **Jank Detection**: By analyzing the `Tracing` data from Chrome, we can look for long tasks that block the main thread or the raster thread (if applicable in web).
- **Wasm Specifics**: Profiling Wasm requires mapping machine addresses back to source code. We might need to parse the DWARF info or rely on Chrome's built-in Wasm profiling capabilities via CDP.

### 4. Next Steps / Action Items
- [x] Create a reproduction/sample Flutter Web app to test against.
- [x] Scaffold a basic Dart CLI app.
- [x] Experiment with launching Chrome via CDP and capturing basic trace events.
- [x] Investigate what timing signals Flutter Web naturally exposes to the browser (used `AnimationFrame` and `BeginFrame`).

### 5. Future Work & Refinement
- [x] **Dynamic Ports**: Avoid hardcoded port 9222 for Chrome to prevent conflicts in parallel runs.
- [ ] **Advanced Metrics**: Break down frame time into Scripting vs Rendering vs GC.
- [ ] **HTML Reporter**: Create a stunning, interactive HTML report instead of just console output.
- [ ] **CLI Polish**: Add options for profiling duration, output paths, and custom build flags.
- [ ] **CanvasKit Mapping**: Investigate if we can symbolicate `wasm-function[...]` names if we have debug builds of CanvasKit.

## Stats to collect and display

### 1. Frame Health
- **Average Frame Interval**: How often the browser signals a new frame (e.g., target 16.6ms for 60fps).
- **Average Frame Work Duration**: How long the application actually takes to process a frame (Scripting + Rendering).
- **Frame Drop Rate**: Percentage of requested frames that were missed or delayed.
- **Jank Count**: Number of frames that exceeded the 16.6ms threshold.

### 2. Task Breakdown
- **Top Slow Tasks**: List of individual tasks exceeding 16.6ms, sorted by duration.
- **Category Distribution**: Time spent in `Scripting` (V8/Wasm), `Rendering` (Layout, Paint), and `GC` (Garbage Collection).
- **GC Overhead**: Total time spent in Garbage Collection and frequency of GC pauses.

### 3. Symbolication & Attribution
- **Mapped Source Locations**: File and line numbers for slow Dart functions (using source maps).
- **Call Tree / Hotspots**: Identifying which specific operations (e.g., `TimerFire`, `FunctionCall`) are responsible for the most jank.

