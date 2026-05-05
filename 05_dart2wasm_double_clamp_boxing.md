## Description
While profiling Flutter Web (`skwasm`), we discovered that the `.clamp()` method on `double` and `int` primitives causes severe performance degradation, massive Wasm code bloat, and `BoxedDouble`/`BoxedInt` GC churn.

## Context
In the Flutter framework, `.clamp()` is used ubiquitously in geometry and layout bounds checking (e.g., `constraints.clamp()`, `Offset.clamp()`). 

To validate how this compiles, we wrote an IR test for `dart2wasm`:
```dart
@pragma('wasm:never-inline')
double testClampDouble(double val, double min, double max) => val.clamp(min, max);
```

When analyzing the generated WebAssembly (WAT), we expected to see native `f64.max` and `f64.min` instructions. Instead, we found a massive block of virtual dispatch and heap allocations:
```wasm
  (func $"testClampDouble <noInline>" (param $var0 f64) (param $var1 f64) (param $var2 f64)
    block $label0 (result f64)
      local.get $var1
      i32.const 61
      local.get $var2
      struct.new $BoxedDouble    ;; HEAP ALLOCATION #1
      call $"BoxedDouble.compareTo (body)"   ;; VIRTUAL DISPATCH #1
      i64.const 0
      i64.gt_s
      if
        ;; ... throws ArgumentError ...
      end
      ;; ... more bitwise checks for NaN and -0.0 ...
      local.get $var0
      i32.const 61
      local.get $var1
      struct.new $BoxedDouble   ;; HEAP ALLOCATION #2
      call $"BoxedDouble.compareTo (body)"  ;; VIRTUAL DISPATCH #2
      i64.const 0
      i64.lt_s
      br_if $label0
      ;; ...
```

This occurs because the Dart SDK implements `clamp` using `.compareTo()` to handle IEEE 754 edge cases (like `-0.0` and `NaN`).

## Impact
Because `dart2wasm` currently honors the Dart patch implementation, every single call to `.clamp()` on a primitive double or int forces the compiler to:
1. Heap-allocate multiple `BoxedDouble` (or `BoxedInt`) structs.
2. Execute heavy virtual method dispatch for `.compareTo()`.
3. Emit massive blocks of bitwise logic for NaN/infinity checking.

In a Flutter layout pass where thousands of widgets are clamping their constraints, this adds up to thousands of useless heap allocations per frame, destroying the performance of tight mathematical loops.

## Expected Behavior
Because `num.clamp` is polymorphic, fixing it natively without breaking backwards compatibility is incredibly difficult. 

The ideal path forward (which also addresses the long-standing semantic debates in [dart-lang/sdk#25217](https://github.com/dart-lang/sdk/issues/25217)) is to introduce a monomorphic, static clamping method directly to the Dart SDK—either in `dart:math` or as a static method on the `double` and `int` classes.

For example, adding:
```dart
static double clampDouble(double x, double min, double max)
```
Since the compiler can statically guarantee all three inputs are `f64` (unboxed doubles), `dart2wasm` can add a `StaticIntrinsic` and peephole-optimize the entire function call down to a single line of WebAssembly:
`f64.max(min, f64.min(val, max))`

(Zero heap allocations, zero virtual dispatch, zero branching).

## Note on Flutter's `clampDouble`
Historically, Flutter introduced their own `clampDouble(double x, double min, double max)` in `dart:ui` specifically because the polymorphic nature of `num.clamp` caused severe performance issues in `dart2js`. 

Because `clampDouble` is currently bound to the Flutter Engine (`dart:ui`), it is treated as an external library by the `dart2wasm` compiler, which makes it extremely difficult to add as a global compiler intrinsic. 

If a fast-path, monomorphic `clampDouble` (or equivalent) is added to the core Dart SDK, `dart2wasm` can instantly intrinsify it. This would allow Flutter to completely deprecate their `dart:ui` workaround, and developers across the entire Dart ecosystem could finally write high-performance clamping logic without massive GC penalties!