# Idris ARM backend

This repository contains a small, direct Idris 2 backend for numerical kernels
on 32-bit Android ARM.  It validates selected source signatures, lowers Idris
ANF to a representation-tagged leaf IR, and emits readable Thumb-2/VFP
assembly.  It does not route through C and does not bring the Idris runtime,
garbage collector, or boxed values into a renderer kernel.

The first milestone is intentionally narrow and honest:

```text
ordinary Idris source
  -> Idris 2 type checking and erasure
  -> explicit source ABI validation
  -> Compiler.ANF
  -> validated representation-tagged runtime-free leaf IR
  -> deterministic Thumb-2/VFP .S
  -> Android-target Clang .o
```

`examples/Quadratic.idr` is the proof function.  It evaluates `ax^2 + bx + c`
from a caller-owned Float32 coefficient buffer and exports a C-callable symbol:

```c
float evaluate_quadratic(const float *coefficients, float x);
```

## What works

The backend accepts exported, closure-free, straight-line functions made from:

- at most four explicitly bound, unboxed one-word arguments of source type
  `Float32`, `Float32Buffer`, or `Int32`;
- signed 32-bit index constants and local copies;
- caller-owned `Float32Buffer` loads;
- Float32 add, subtract, multiply, divide, negate, absolute value, and square
  root;
- one Float32 result.

Before assembly emission it validates each source signature, exact primitive
names, source/ANF arity agreement, def-use order, unique definitions,
representation consistency (`Word32`, `Float32`, or `Float32Pointer`), argument
count, and portable C symbol spelling.  The emitter independently rechecks
operand representation tags and frame bounds.  Virtual locals receive dense
four-byte stack homes and the stack frame is calculated and aligned instead of
being a fixed 512-byte block.

`Int` is intentionally rejected: it is a 64-bit source type in the pinned Idris
compiler and cannot be smuggled through this backend's one-register `Int32`
ABI.  Constants use deterministic `movw`/`movt` materialization, so generated
functions do not depend on assembler literal-pool placement.

Everything outside that grammar is rejected with a compiler error.  In
particular, v0.1 does not accept closures, constructors, heap allocation,
general calls, recursion, cases/branches, IO, strings, parsing, JNI, or Android
application lifecycle code.

This is therefore a real ARM backend for a useful numerical leaf subset, not
yet a backend for arbitrary Idris and not yet a complete Surfer port.

## Android ABI

The target is Android `armeabi-v7a`:

- ARMv7-A and Thumb-2;
- scalar VFPv3-D16 instructions;
- Android softfp calling convention: Float32 values cross the C boundary as
  raw words in core registers, while VFP performs arithmetic inside a leaf;
- 8-byte-aligned stack frames;
- no runtime or global mutable state.

The buffer pointer must be non-null and four-byte aligned, and the index must be
in bounds.  Those are explicit FFI preconditions until a safe Idris wrapper and
length-carrying renderer ABI are added.

## Compiler pin

The compiler API and TTC format are commit-sensitive.  This code is pinned to
Idris 2 commit:

```text
f66d2a1802d9e04a57441160f411d46be63d785f
```

Build and self-host that checkout, then install its API package:

```sh
make bootstrap SCHEME=/path/to/threaded/chez/bin/scheme
make install-api
```

Do not substitute an unrelated `0.8.0` installation merely because its version
number matches.  `make check` verifies the short revision printed by the
compiler before it touches the backend modules; the full pin also lives in
`compiler-revision.txt`.

## Build and test

With the pinned self-hosted `idris2` on `PATH`:

```sh
make check
make test
make driver
make integration
```

`make test` runs 15 accepted and rejected ANF fixtures and compares output
byte-for-byte with the immutable assembly golden at
`generated/evaluate_quadratic.S`.  `make update-golden` is the explicit way to
accept an intentional emitter change.  `make integration` exercises the actual
custom-codegen seam from source, including every supported arithmetic
intrinsic, a typed identity, and rejected `Int`/non-`Float32` source ABIs.

To regenerate from ordinary Idris source and assemble both source examples with
Android NDK Clang for API 34:

```sh
make assemble \
  ANDROID_CLANG="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi34-clang"

make verify-object \
  ANDROID_CLANG="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi34-clang"
```

The final acceptance test for a milestone is to link the object into a tiny C
harness on the phone and compare several results against the C implementation.

### Current verification

The checked-in v0.1 source has passed all of the following from a clean
self-host of the pinned compiler:

- production-module and test-module typechecking;
- all 15 accepted/rejected lowering and emitter tests plus immutable-golden
  comparison;
- actual `Quadratic.idr` compilation through `getCompileDataWith` and the
  custom code-generator registration;
- source compilation of every admitted Float32 intrinsic and a typed identity;
- source-level rejection of 64-bit `Int` arguments and non-Float32 results;
- LLVM assembly to an ELF32 ARM EABI5 relocatable object;
- object attributes for ARMv7, Thumb-2, VFPv3-D16, and soft-float ABI;
- freestanding shared-library linking with no runtime dependencies and the
  global `evaluate_quadratic` symbol.

Numerical execution on ARM hardware remains the device-side acceptance check;
this environment did not have the phone or QEMU attached.

## Source map

- `src/Backend/ARMv7/IR.idr` — the small representation-tagged leaf IR;
- `src/Backend/ARMv7/Lower.idr` — ANF subset checking, representation inference,
  and dense frame layout;
- `src/Backend/ARMv7/Emit.idr` — deterministic Thumb-2/VFP text emission;
- `src/Backend/ARMv7/Codegen.idr` — Idris custom-codegen registration and file
  output;
- `src/RendererPrimitives.idr` — the explicit unboxed renderer ABI seam;
- `examples/AllOperations.idr` — real-source coverage of every arithmetic
  intrinsic and the typed identity path;
- `tests/TestMain.idr` — positive and negative lowering tests.

## Next milestones

The next useful compiler increment is structured control flow: comparisons,
Boolean `if`, and one constrained tail loop, sufficient for a dynamic Horner
evaluator.  After that come a bounds-aware buffer ABI and a combined
Horner/bisection kernel.  General Idris runtime features, the Android UI, the
pure Idris renderer, the GLSL backend, and the broader compiler-science project
remain separate workstreams.
