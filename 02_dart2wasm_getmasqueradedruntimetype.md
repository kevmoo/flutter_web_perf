## Description
While profiling a Flutter Web app compiled with `dart2wasm`, we noticed that `_getMasqueradedRuntimeType` is an abnormally hot function, consuming a significant portion of exclusive trace execution time.

## Context
In a 5-second trace of a heavy Flutter layout, `_getMasqueradedRuntimeType` consistently appeared as a Top 5 exclusive CPU hotspot (with roughly the same sample count as core Flutter lifecycle methods like `performLayout`). 

Looking at `sdk/lib/_internal/wasm/lib/type.dart`, this function converts an `Object` to its masqueraded `_Type`. 
When reviewing the generated WebAssembly Text (WAT), this function compiles to a long, linear sequence of `i32.eq`, `i32.lt_u`, and `if-else` branches:

```wasm
  local.get 1
  i32.const 440
  i32.ge_s
  if ;; label = @1
  // ...
  local.get 1
  i32.const 19
  i32.sub
  i32.const 37
  i32.lt_u
  if ;; label = @1
  // ...
```

In Flutter, `.runtimeType` is queried frequently for diagnostics (`toDiagnosticsNode()`), debug assertions, and caching keys. 

## Impact
Because Wasm engines evaluate this linear chain of `if-else` branches sequentially, resolving a simple `.runtimeType` lookup becomes an O(N) operation based on where the class ID falls in the `_getMasqueradedRuntimeType` switch block. In heavy framework loops, the cumulative overhead is immense.

## Expected Behavior
Because `ClassID` values are known at compile time and represent a contiguous (or near-contiguous) range of integers, `dart2wasm` should ideally peephole-optimize or compile `_getMasqueradedRuntimeType` into a jump table using Wasm's `br_table` instruction. Alternatively, looking up the `_Type` struct could be done via an O(1) Wasm array/table lookup based on the class ID, avoiding the linear branching completely.
