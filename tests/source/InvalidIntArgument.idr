module InvalidIntArgument

import RendererPrimitives

||| Idris Int is 64-bit in the pinned compiler and cannot occupy one raw ARM
||| core register in this backend's deliberately one-word argument ABI.
%export "android-armv7:invalid_int_argument"
invalid_int_argument : Int -> Float32 -> Float32
invalid_int_argument ignored value = value

main : IO ()
main = pure ()
