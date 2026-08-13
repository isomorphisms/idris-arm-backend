module RendererPrimitives

%default total

||| One explicitly unboxed renderer scalar.  This is intentionally local to
||| the renderer ABI instead of changing Idris's global primitive type set.
export
data Float32 : Type where [external]

||| Caller-owned, contiguous Float32 memory.  The backend assumes a non-null,
||| suitably aligned pointer and an in-bounds index at the FFI boundary.
export
data Float32Buffer : Type where [external]

export %extern float32_buffer_load : Float32Buffer → Int32 → Float32

export %extern float32_add : Float32 → Float32 → Float32
export %extern float32_subtract : Float32 → Float32 → Float32
export %extern float32_multiply : Float32 → Float32 → Float32
export %extern float32_divide : Float32 → Float32 → Float32

export %extern float32_negate : Float32 → Float32
export %extern float32_absolute : Float32 → Float32
export %extern float32_square_root : Float32 → Float32
