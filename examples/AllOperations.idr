module AllOperations

import RendererPrimitives

||| Exercise every Float32 arithmetic intrinsic through ordinary Idris source.
%export "android-armv7:exercise_operations"
exercise_operations : Float32 → Float32 → Float32
exercise_operations left right =
  let difference = float32_subtract left right
      negated = float32_negate difference
      magnitude = float32_absolute negated
      rooted = float32_square_root magnitude
      denominator = float32_add left right
  in float32_divide rooted denominator

||| A source-typed identity proves that representation comes from the source
||| ABI rather than being guessed from an arithmetic use.
%export "android-armv7:float32_identity"
float32_identity : Float32 → Float32
float32_identity value = value

||| Preserve a source-level two-word C ABI even when one argument is unused.
%export "android-armv7:float32_first"
float32_first : Float32 → Float32 → Float32
float32_first value ignored = value

main : IO ()
main = pure ()
