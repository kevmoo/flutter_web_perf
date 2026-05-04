## Description
While profiling Flutter Web (`skwasm`) we identified that `math.min` and `math.max` are generating massive GC churn and unnecessary boxing overhead when used with primitive numbers like unboxed `int` or `double`.

## Context
When inspecting the top 10 hot functions in a release mode profile (with timeline events filtered out), we noticed `min` and `max` appearing repeatedly across multiple stack traces. 

These functions are heavily used in critical framework geometry and clipping logic, with our profile showing them being called by functions like:
- `transformRectWithMatrix` (`_engine/engine/util.dart`)
- `_areaOfUnion` (`_engine/engine/occlusion_map.dart`)
- `expandToInclude` (`ui/geometry.dart`)
- `deflate` (`rendering/box.dart`)

Looking at `sdk/lib/_internal/wasm/lib/math_patch.dart`, these functions are implemented as generics:
```dart
@patch
T min<T extends num>(T a, T b) {
  if (a > b) return b;
  if (a < b) return a;
  // ...
```

## Impact
Because `dart2wasm` does not currently intrinsify `math.min` or `math.max` for primitive types (like it does for simple arithmetic operators `+`, `-`, `*`), compiling this generic method forces the compiler to treat `a` and `b` as boxed objects (`BoxedDouble` or `BoxedInt`).

Every time `math.max(1.0, 2.0)` is executed in a tight geometry loop, `dart2wasm` must:
1. Heap-allocate `1.0` into a `BoxedDouble`.
2. Heap-allocate `2.0` into a `BoxedDouble`.
3. Perform a virtual dispatch to compare them.
4. Return the boxed result (which often has to be unboxed again immediately by the caller).

This leads to massive GC pressure and completely ruins the performance of mathematical tight loops. WebAssembly provides native primitive instructions like `f64.min` and `f64.max` that could do this in a single CPU cycle.

## Expected Behavior
The `dart2wasm` compiler should intrinsify `math.min` and `math.max` (as it does for operators in `pkg/dart2wasm/lib/intrinsics.dart`). 

When the arguments are statically known to be unboxed `double` or `int` primitives, the compiler should peephole optimize the generic `math.min` / `math.max` calls directly into native Wasm `f64.min`, `f64.max`, or inline conditional assignments (`i64.lt_s` + `select`), bypassing the generic patch implementation and avoiding `Boxed` struct heap allocations entirely.
