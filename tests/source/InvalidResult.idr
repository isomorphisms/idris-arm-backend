module InvalidResult

import RendererPrimitives

||| The v0.1 C boundary only permits an unboxed Float32 result.
%export "android-armv7:invalid_result"
invalid_result : Float32 → Int32
invalid_result value = 0

main : IO ()
main = pure ()
