## Description
While profiling Flutter Web (skwasm) using Perfetto, we identified a severe profiling bottleneck in the `dart2wasm` compiled output stemming from `dart:developer` `Timeline` events.

Because `FlutterTimeline.startSync` and `finishSync` are called continuously by the framework during rendering (for layout, paint, and build scopes in non-release modes), the overhead of tracing actually eclipses the work being traced.

## Context
In our 5-second E2E benchmark of a Flutter Web app, the timeline events alone accounted for the absolute top exclusive CPU hotspots:
1. `_computeWithTimeline` (~18,700 samples)
2. `buildScope` (~14,300 samples)
3. `flushPaint`, `flushLayout`, `flushCompositingBits` (all ~1,800+ samples each)

Upon inspecting the stack and `dart2wasm` compilation, we see these samples are dominated by `dart:_internal/js_runtime/lib/developer_patch.dart` calling `_reportTaskEvent` and utilizing synchronous JS Interop to call `window.performance.mark()`.

The extensive Wasm <-> JS boundary crossings, combined with the Dart string manipulations required to construct the event labels (`_createEventName`, `_postfixWithCount`), take longer than the actual Wasm code doing the Flutter layout. 

## Impact
When developers use `--profile` to understand the performance of their Flutter Web applications, the resulting profile traces are heavily distorted. Over 50% of the recorded CPU time is spent just serializing timeline events over the JS Interop boundary, making it incredibly difficult to isolate actual application bottlenecks.

## Expected Behavior
The `dart:developer` patch for Wasm currently shares the JS implementation (as noted by `TODO(53884): Rewrite without JS interop in _internal/wasm_standalone`). 

To prevent profiling overhead from dominating Wasm execution, `dart2wasm` should ideally implement a Wasm-native timeline recorder. This could involve buffering trace events in a Wasm struct array/linear memory and asynchronously flushing/chunking them to the browser's performance APIs, entirely avoiding synchronous string allocations and JS interop during tight framework loops.
