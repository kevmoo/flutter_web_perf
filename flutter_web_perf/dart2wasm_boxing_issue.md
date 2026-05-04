# [dart2wasm] Unnecessary `BoxedInt` allocations for `int.abs()` in tight loops (Flutter `Priority.+`)

## Description
While profiling Flutter Web (skwasm) using Perfetto, we identified a severe performance bottleneck and GC churn generator in the `dart2wasm` compiled output. 

The issue stems from how `dart2wasm` lowers the `int.abs()` method when called on an unboxed primitive integer. It appears to aggressively allocate `BoxedInt` structs instead of using primitive Wasm operations, which becomes catastrophic in tight framework loops.

## Steps to Reproduce & Context
The #1 exclusive CPU hotspot (consuming nearly 90% of the trace time in our benchmark) was the `+` operator in Flutter's `Priority` class (`package:flutter/src/scheduler/priority.dart`).

**Dart Source:**
```dart
  Priority operator +(int offset) {
    if (offset.abs() > kMaxOffset) { // <--- The culprit
      // Clamp the input offset.
      offset = kMaxOffset * offset.sign;
    }
    return Priority._(_value + offset);
  }
```

When we extract the WebAssembly Text (WAT) for this specific function, we can see that `offset` is passed in as an unboxed `i64`. However, the call to `.abs()` causes `dart2wasm` to allocate a `$BoxedInt`:

**Wasm Disassembly:**
```wat
(func $Priority.+ (;9923;) (type 4431) (param (ref $Duration) i64) (result (ref $Duration))
  (local (ref $BoxedInt) i64)
  ;; ... 
  local.get 1
  struct.new $BoxedInt       ;; <--- ALLOCATION #1 (Boxing the unboxed i64 parameter)
  local.tee 2
  struct.get $BoxedInt $value
  local.tee 3
  i64.const 0
  i64.lt_s
  if (result (ref $BoxedInt)) ;; label = @1
    i32.const 354
    i64.const 0
    local.get 3
    i64.sub
    struct.new $BoxedInt     ;; <--- ALLOCATION #2 (Allocating a second BoxedInt if < 0)
  else
    local.get 2
  end
  ;; ...
```

*(Note: `dart2wasm` cleverly aliases `Priority` and `Duration` to the same struct due to structural equivalence, hence `(ref $Duration)`).*

## Impact
Because `Priority.+` is heavily used within the Flutter `SchedulerBinding`'s internal sorting and queue management, this small operator is executed millions of times per frame during heavy layout churn. 

By boxing the integer just to calculate the absolute value, the compiler is generating up to 2 useless `BoxedInt` allocations per call. In our 5-second trace, this resulted in ~44,000 CPU samples dedicated entirely to this function and its associated WasmGC overhead.

## Expected Behavior
`dart2wasm` should peephole optimize or inline `int.abs()` on unboxed `i64` primitives using raw Wasm control flow or bitwise operations, avoiding the heap allocation of a `BoxedInt` entirely.

## Workaround
For framework engineers, rewriting the Dart code to avoid `.abs()` completely eliminates the Wasm allocation overhead:
```dart
    if (offset > kMaxOffset) {
      offset = kMaxOffset;
    } else if (offset < -kMaxOffset) {
      offset = -kMaxOffset;
    }
```
However, the compiler should ideally handle `.abs()` without penalizing developers with heap allocations.