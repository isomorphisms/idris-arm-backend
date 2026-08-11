module Quadratic

import RendererPrimitives

||| Evaluate ax^2 + bx + c in Horner form.  All three coefficients are read
||| from caller-owned unboxed memory, and every arithmetic operation is one of
||| the exact renderer intrinsics understood by the restricted backend.
%export "android-armv7:evaluate_quadratic"
evaluate_quadratic : Float32Buffer -> Float32 -> Float32
evaluate_quadratic coefficients x =
  let a = float32_buffer_load coefficients 0
      b = float32_buffer_load coefficients 1
      c = float32_buffer_load coefficients 2
      ax_plus_b =
        float32_add (float32_multiply a x) b
  in float32_add (float32_multiply ax_plus_b x) c

main : IO ()
main = pure ()
