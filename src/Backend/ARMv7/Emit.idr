module Backend.ARMv7.Emit

import Backend.ARMv7.IR
import Backend.ARMv7.Lower
import Data.String

%default total

private
slot_address : Local → String
slot_address local =
  "[sp, #" ++ show (local.frame_slot * 4) ++ "]"

private
load_word : String → Local → List String
load_word register local =
  ["        ldr     " ++ register ++ ", " ++ slot_address local]

private
store_word : String → Local → List String
store_word register local =
  ["        str     " ++ register ++ ", " ++ slot_address local]

private
load_float : String → Local → List String
load_float register local =
  ["        vldr    " ++ register ++ ", " ++ slot_address local]

private
store_float : String → Local → List String
store_float register local =
  ["        vstr    " ++ register ++ ", " ++ slot_address local]

private
materialise_word32 : Int → List String
materialise_word32 value =
  let unsigned_value =
        if value < 0 then value + 4294967296 else value
      low_half = unsigned_value `mod` 65536
      high_half = unsigned_value `div` 65536
  in
    [ "        movw    r0, #" ++ show low_half
    , "        movt    r0, #" ++ show high_half
    ]

private
float_binary_mnemonic : FloatBinaryOperation → String
float_binary_mnemonic AddFloat32 = "vadd.f32"
float_binary_mnemonic SubtractFloat32 = "vsub.f32"
float_binary_mnemonic MultiplyFloat32 = "vmul.f32"
float_binary_mnemonic DivideFloat32 = "vdiv.f32"

private
float_unary_mnemonic : FloatUnaryOperation → String
float_unary_mnemonic NegateFloat32 = "vneg.f32"
float_unary_mnemonic AbsoluteFloat32 = "vabs.f32"
float_unary_mnemonic SquareRootFloat32 = "vsqrt.f32"

private
emit_instruction : Instruction → List String
emit_instruction (Copy destination source) =
  load_word "r0" source ++ store_word "r0" destination
emit_instruction (WordConstant destination value) =
  materialise_word32 value ++
  store_word "r0" destination
emit_instruction (LoadFloat32 destination buffer index) =
  load_word "r0" buffer ++
  load_word "r1" index ++
  [ "        add.w   r0, r0, r1, lsl #2"
  , "        vldr    s0, [r0]"
  ] ++
  store_float "s0" destination
emit_instruction (FloatBinary operation destination left right) =
  load_float "s0" left ++
  load_float "s1" right ++
  [ "        " ++ float_binary_mnemonic operation ++ " s0, s0, s1" ] ++
  store_float "s0" destination
emit_instruction (FloatUnary operation destination value) =
  load_float "s0" value ++
  [ "        " ++ float_unary_mnemonic operation ++ " s0, s0" ] ++
  store_float "s0" destination

private
emit_instructions : List Instruction → List String
emit_instructions [] = []
emit_instructions (instruction :: rest) =
  emit_instruction instruction ++ emit_instructions rest

private
argument_registers : List String
argument_registers = ["r0", "r1", "r2", "r3"]

private
store_arguments : List Local → List String → List String
store_arguments [] registers = []
store_arguments (argument :: rest) (register :: registers) =
  store_word register argument ++ store_arguments rest registers
store_arguments arguments [] = []

private
expect_representation :
  String →
  Representation →
  Local →
  Either String ()
expect_representation role expected local =
  if local.representation == expected
    then Right ()
    else
      Left
        (role ++ " expected " ++ show expected ++
         ", but got " ++ show local)

private
validate_local_home : LeafFunction → Local → Either String ()
validate_local_home function local =
  if local.frame_slot < 0 || local.frame_slot * 4 + 4 > function.frame_bytes
    then
      Left
        ("Local " ++ show local ++ " is outside the " ++
         show function.frame_bytes ++ "-byte frame")
    else Right ()

private
validate_instruction : LeafFunction → Instruction → Either String ()
validate_instruction function (Copy destination source) = do
  validate_local_home function destination
  validate_local_home function source
  if destination.representation == source.representation
    then Right ()
    else Left "Copy operands have different representations"
validate_instruction function (WordConstant destination value) = do
  validate_local_home function destination
  expect_representation "Word constant" Word32 destination
  if value >= -2147483648 && value <= 2147483647
    then Right ()
    else Left ("Word constant is outside signed Int32 range: " ++ show value)
validate_instruction function (LoadFloat32 destination buffer index) = do
  validate_local_home function destination
  validate_local_home function buffer
  validate_local_home function index
  expect_representation "Buffer load result" Float32 destination
  expect_representation "Buffer load pointer" Float32Pointer buffer
  expect_representation "Buffer load index" Word32 index
validate_instruction function (FloatBinary operation destination left right) = do
  validate_local_home function destination
  validate_local_home function left
  validate_local_home function right
  expect_representation "Float binary result" Float32 destination
  expect_representation "Float binary left operand" Float32 left
  expect_representation "Float binary right operand" Float32 right
validate_instruction function (FloatUnary operation destination value) = do
  validate_local_home function destination
  validate_local_home function value
  expect_representation "Float unary result" Float32 destination
  expect_representation "Float unary operand" Float32 value

private
validate_instructions : LeafFunction → List Instruction → Either String ()
validate_instructions function [] = Right ()
validate_instructions function (instruction :: rest) = do
  validate_instruction function instruction
  validate_instructions function rest

private
validate_arguments : LeafFunction → List Local → Either String ()
validate_arguments function [] = Right ()
validate_arguments function (argument :: rest) = do
  validate_local_home function argument
  validate_arguments function rest

private
validate_leaf_for_emission : LeafFunction → Either String ()
validate_leaf_for_emission function = do
  _ <- validate_external_symbol function.external_symbol
  if function.frame_bytes <= 0 ||
     function.frame_bytes > 1024 ||
     function.frame_bytes `mod` 8 /= 0
    then
      Left
        ("ARMv7 leaf frame must be 8-byte aligned and between 8 and 1024 " ++
         "bytes, got " ++ show function.frame_bytes)
    else Right ()
  if length function.arguments > 4
    then Left "ARMv7 softfp leaves admit at most four one-word arguments"
    else Right ()
  validate_arguments function function.arguments
  validate_instructions function function.instructions
  validate_local_home function function.result
  expect_representation "Function result" Float32 function.result

||| Emit one validated leaf using the Android armeabi-v7a softfp boundary:
||| every argument enters as one raw 32-bit core-register word and Float32
||| leaves as raw bits in r0.  VFP is used only inside the function.
public export
emit_leaf : LeafFunction → Either String String
emit_leaf function = do
  validate_leaf_for_emission function
  Right (unlines
    ([ ""
     , "        .p2align 2"
     , "        .global " ++ function.external_symbol
     , "        .type " ++ function.external_symbol ++ ", %function"
     , "        .thumb_func"
     , function.external_symbol ++ ":"
     , "        sub.w   sp, sp, #" ++ show function.frame_bytes
     ] ++
     store_arguments function.arguments argument_registers ++
     emit_instructions function.instructions ++
     load_word "r0" function.result ++
     [ "        add.w   sp, sp, #" ++ show function.frame_bytes
     , "        bx      lr"
     , "        .size " ++ function.external_symbol ++
       ", .-" ++ function.external_symbol
     ]))

||| The fixed target header shared by every generated translation unit.
public export
assembly_header : String
assembly_header =
  unlines
    [ ".syntax unified"
    , ".arch armv7-a"
    , ".fpu vfpv3-d16"
    , ".thumb"
    , ".text"
    , ""
    , "@ Runtime-free Idris numerical leaves for Android armeabi-v7a."
    , "@ C ABI: softfp at the boundary, hardware Float32 internally."
    ]

public export
assembly_footer : String
assembly_footer =
  "\n.section .note.GNU-stack,\"\",%progbits\n"
