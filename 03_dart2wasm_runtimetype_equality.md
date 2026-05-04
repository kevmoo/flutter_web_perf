## Description
While profiling Flutter Web (`skwasm`) we identified that evaluating `.runtimeType == .runtimeType` causes heavy GC churn and CPU overhead in `dart2wasm` due to the boxing/allocation of `_Type` objects.

## Context
When inspecting the top 10 hot functions in an optimized `--release` build of a heavily-churning Flutter Web app, we noticed `operator ==` (specifically `BoxConstraints.==`, `Size.==`, and `Color.==`) and `Widget.canUpdate` consistently consuming significant trace time.

In the Flutter framework, almost every `operator ==` override begins with:
```dart
if (other.runtimeType != runtimeType) return false;
```

Similarly, the highly-critical `Widget.canUpdate` method evaluates:
```dart
return oldWidget.runtimeType == newWidget.runtimeType && oldWidget.key == newWidget.key;
```

When looking at the generated WebAssembly Text (WAT) for these checks, `dart2wasm` compiles this directly as two independent property accesses and a virtual equals call:
```wasm
  local.get 1
  call 690     ;; calls _getMasqueradedRuntimeType(other), allocating _Type
  local.tee 4
  local.get 2
  call 690     ;; calls _getMasqueradedRuntimeType(this), allocating _Type
  local.get 4
  struct.get 3 0  ;; looks up the virtual dispatch for _Type.==
  i32.const 1
  i32.sub
  call_indirect (type 26) ;; calls _InterfaceType.==
  i32.eqz
```

## Impact
Because `_getMasqueradedRuntimeType` heap-allocates an `_InterfaceType` (or equivalent) struct for each lookup, this means *every single equality check* in the entire Flutter framework forces two heap allocations and a virtual method call.

For an operation executed millions of times per frame during Layout and Build phases, this causes devastating GC pressure and Wasm branching overhead.

## Expected Behavior
The `dart2wasm` compiler should peephole optimize the specific AST pattern `a.runtimeType == b.runtimeType`.

Instead of allocating two `_Type` objects and calling `==`, the compiler could dispatch to a fast-path intrinsic `_runtimeTypesAreEqual(a, b)`:
```dart
@pragma("wasm:prefer-inline")
bool _runtimeTypesAreEqual(Object a, Object b) {
  final WasmI32 classIdA = ClassID.getID(a);
  final WasmI32 classIdB = ClassID.getID(b);
  
  // Fast path: If they are the same non-masqueraded class, we just check if type args match
  if (classIdA == classIdB && 
      ClassID.firstNonMasqueradedInterfaceClassCid <= classIdA) {
    // Avoids allocating _InterfaceType if type args are identical (or empty for non-generics like Widget/BoxConstraints)
    return _typesAreIdentical(Object._getTypeArguments(a), Object._getTypeArguments(b));
  }
  
  // Slow path fallback
  return _getMasqueradedRuntimeType(a) == _getMasqueradedRuntimeType(b);
}
```

For non-generic classes (which the vast majority of Flutter `Widget`s, `RenderObject`s, and layout geometry classes are), this optimization drops the Wasm instructions from two heap allocations and a virtual dispatch down to a few primitive `i32` loads and comparisons.
