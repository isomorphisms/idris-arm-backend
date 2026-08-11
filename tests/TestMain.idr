module TestMain

import Backend.ARMv7.Emit
import Backend.ARMv7.IR
import Backend.ARMv7.Lower
import Compiler.ANF
import Core.FC
import Core.Name
import Core.Name.Namespace
import Core.TT.Primitive
import Core.TT.Term
import Data.String
import System
import System.File

%default covering

private
renderer_primitive : String -> Name
renderer_primitive leaf =
  NS (mkNamespace "RendererPrimitives") (UN (Basic leaf))

private
other_primitive : String -> Name
other_primitive leaf =
  NS (mkNamespace "UnrelatedModule") (UN (Basic leaf))

private
ext2 : String -> Int -> Int -> ANF
ext2 primitive left right =
  AExtPrim
    emptyFC
    Nothing
    (renderer_primitive primitive)
    [ALocal left, ALocal right]

private
ext1 : String -> Int -> ANF
ext1 primitive value =
  AExtPrim
    emptyFC
    Nothing
    (renderer_primitive primitive)
    [ALocal value]

private
lower_float_leaf :
  String ->
  List Representation ->
  ANFDef ->
  Either String LeafFunction
lower_float_leaf symbol arguments =
  lower_leaf symbol arguments Float32

private
quadratic_shape : ANFDef
quadratic_shape =
  MkAFun
    [0, 1]
    (ALet emptyFC 2
      (ALet emptyFC 3 (APrimVal emptyFC (I32 0))
        (ext2 "float32_buffer_load" 0 3))
      (ALet emptyFC 4
        (ALet emptyFC 5 (APrimVal emptyFC (I32 1))
          (ext2 "float32_buffer_load" 0 5))
        (ALet emptyFC 6
          (ALet emptyFC 7 (APrimVal emptyFC (I32 2))
            (ext2 "float32_buffer_load" 0 7))
          (ALet emptyFC 8
            (ALet emptyFC 9 (ext2 "float32_multiply" 2 1)
              (ext2 "float32_add" 9 4))
            (ALet emptyFC 10 (ext2 "float32_multiply" 8 1)
              (ext2 "float32_add" 10 6))))))

private
unary_and_binary_shape : ANFDef
unary_and_binary_shape =
  MkAFun
    [0, 1]
    (ALet emptyFC 2 (ext2 "float32_subtract" 0 1)
      (ALet emptyFC 3 (ext1 "float32_negate" 2)
        (ALet emptyFC 4 (ext1 "float32_absolute" 3)
          (ALet emptyFC 5 (ext1 "float32_square_root" 4)
            (ext2 "float32_divide" 5 1)))))

private
accepted_quadratic_has_typed_ir_and_dense_frame : Bool
accepted_quadratic_has_typed_ir_and_dense_frame =
  case lower_float_leaf
         "evaluate_quadratic"
         [Float32Pointer, Float32]
         quadratic_shape of
    Left _ => False
    Right leaf =>
      case emit_leaf leaf of
        Left _ => False
        Right assembly =>
          leaf.frame_bytes == 48 &&
          isInfixOf "Float32Pointer" (render_ir leaf) &&
          isInfixOf "Word32" (render_ir leaf) &&
          isInfixOf "vldr    s0, [r0]" assembly &&
          isInfixOf "vmul.f32 s0, s0, s1" assembly &&
          isInfixOf "vadd.f32 s0, s0, s1" assembly

private
accepted_renderer_arithmetic_is_emitted : Bool
accepted_renderer_arithmetic_is_emitted =
  case lower_float_leaf
         "renderer_arithmetic"
         [Float32, Float32]
         unary_and_binary_shape of
    Left _ => False
    Right leaf =>
      case emit_leaf leaf of
        Left _ => False
        Right assembly =>
          isInfixOf "vsub.f32" assembly &&
          isInfixOf "vneg.f32" assembly &&
          isInfixOf "vabs.f32" assembly &&
          isInfixOf "vsqrt.f32" assembly &&
          isInfixOf "vdiv.f32" assembly

private
suffix_spoof_is_rejected : Bool
suffix_spoof_is_rejected =
  let spoof =
        MkAFun
          [0, 1]
          (AExtPrim
            emptyFC
            Nothing
            (other_primitive "float32_add")
            [ALocal 0, ALocal 1])
  in
    case lower_float_leaf "suffix_spoof" [Float32, Float32] spoof of
      Left _ => True
      Right _ => False

private
unbound_local_is_rejected : Bool
unbound_local_is_rejected =
  let malformed = MkAFun [0] (ext2 "float32_add" 0 99) in
    case lower_float_leaf "unbound" [Float32] malformed of
      Left _ => True
      Right _ => False

private
representation_conflict_is_rejected : Bool
representation_conflict_is_rejected =
  let malformed =
        MkAFun
          [0]
          (ALet emptyFC 1 (APrimVal emptyFC (I32 0))
            (ALet emptyFC 2 (ext2 "float32_buffer_load" 0 1)
              (ext2 "float32_add" 0 2)))
  in
    case lower_float_leaf
           "conflicting_representation"
           [Float32Pointer]
           malformed of
      Left _ => True
      Right _ => False

private
duplicate_definition_is_rejected : Bool
duplicate_definition_is_rejected =
  let malformed =
        MkAFun
          [0]
          (ALet emptyFC 0 (AV emptyFC (ALocal 0))
            (AV emptyFC (ALocal 0)))
  in
    case lower_float_leaf "duplicate_definition" [Float32] malformed of
      Left _ => True
      Right _ => False

private
typed_unused_argument_is_accepted : Bool
typed_unused_argument_is_accepted =
  let identity = MkAFun [0, 1] (AV emptyFC (ALocal 0)) in
    case lower_float_leaf "typed_unused" [Float32, Word32] identity of
      Left _ => False
      Right _ => True

private
source_anf_arity_mismatch_is_rejected : Bool
source_anf_arity_mismatch_is_rejected =
  let identity = MkAFun [0, 1] (AV emptyFC (ALocal 0)) in
    case lower_float_leaf "arity_mismatch" [Float32] identity of
      Left _ => True
      Right _ => False

private
non_float_result_abi_is_rejected : Bool
non_float_result_abi_is_rejected =
  let identity = MkAFun [0] (AV emptyFC (ALocal 0)) in
    case lower_leaf "word_result" [Word32] Word32 identity of
      Left _ => True
      Right _ => False

private
invalid_symbols_are_rejected : Bool
invalid_symbols_are_rejected =
  case ( validate_external_symbol "9starts_with_digit"
       , validate_external_symbol "bad;directive"
       , validate_external_symbol "lambda_λ"
       ) of
    (Left _, Left _, Left _) => True
    _ => False

private
idris_int_literal_is_rejected : Bool
idris_int_literal_is_rejected =
  let malformed = MkAFun [] (APrimVal emptyFC (I 0))
  in
    case lower_float_leaf "idris_int" [] malformed of
      Left _ => True
      Right _ => False

private
word_constants_do_not_need_literal_pools : Bool
word_constants_do_not_need_literal_pools =
  let shape =
        MkAFun
          [0]
          (ALet emptyFC 1 (APrimVal emptyFC (I32 305419896))
            (ext2 "float32_buffer_load" 0 1))
  in
    case lower_float_leaf "large_constant" [Float32Pointer] shape of
      Left _ => False
      Right leaf =>
        case emit_leaf leaf of
          Left _ => False
          Right assembly =>
            isInfixOf "movw    r0, #22136" assembly &&
            isInfixOf "movt    r0, #4660" assembly &&
            not (isInfixOf "ldr     r0, =" assembly)

private
emitter_rejects_invalid_representation_tags : Bool
emitter_rejects_invalid_representation_tags =
  let word_argument = MkLocal 0 0 Word32
      float_result = MkLocal 1 1 Float32
      malformed =
        MkLeafFunction
          "malformed_tags"
          [word_argument]
          [FloatUnary NegateFloat32 float_result word_argument]
          float_result
          8
  in
    case emit_leaf malformed of
      Left _ => True
      Right _ => False

private
fifth_argument_is_rejected : Bool
fifth_argument_is_rejected =
  let malformed = MkAFun [0, 1, 2, 3, 4] (AV emptyFC (ALocal 0)) in
    case lower_float_leaf
           "five_arguments"
           [Float32, Float32, Float32, Float32, Float32]
           malformed of
      Left _ => True
      Right _ => False

private
closure_call_is_rejected : Bool
closure_call_is_rejected =
  let malformed =
        MkAFun [0, 1] (AApp emptyFC Nothing (ALocal 0) (ALocal 1))
  in
    case lower_float_leaf "closure_call" [Float32, Float32] malformed of
      Left _ => True
      Right _ => False

private
tests : List (String, Bool)
tests =
  [ ("quadratic tagged IR and dense frame",
     accepted_quadratic_has_typed_ir_and_dense_frame)
  , ("renderer unary and binary arithmetic",
     accepted_renderer_arithmetic_is_emitted)
  , ("exact primitive names", suffix_spoof_is_rejected)
  , ("unbound local rejection", unbound_local_is_rejected)
  , ("representation conflict rejection",
     representation_conflict_is_rejected)
  , ("duplicate definition rejection", duplicate_definition_is_rejected)
  , ("source-typed unused argument", typed_unused_argument_is_accepted)
  , ("source/ANF arity agreement", source_anf_arity_mismatch_is_rejected)
  , ("Float32-only result ABI", non_float_result_abi_is_rejected)
  , ("portable symbol validation", invalid_symbols_are_rejected)
  , ("64-bit Idris Int rejection", idris_int_literal_is_rejected)
  , ("literal-pool-free constants", word_constants_do_not_need_literal_pools)
  , ("emitter representation validation",
     emitter_rejects_invalid_representation_tags)
  , ("softfp argument limit", fifth_argument_is_rejected)
  , ("closure rejection", closure_call_is_rejected)
  ]

private
failed_tests : List (String, Bool) -> List String
failed_tests [] = []
failed_tests ((name, passed) :: rest) =
  if passed
    then failed_tests rest
    else name :: failed_tests rest

private
quadratic_assembly : Either String String
quadratic_assembly = do
  leaf <-
    lower_float_leaf
      "evaluate_quadratic"
      [Float32Pointer, Float32]
      quadratic_shape
  leaf_assembly <- emit_leaf leaf
  Right (assembly_header ++ leaf_assembly ++ assembly_footer)

private
write_quadratic : String -> IO ()
write_quadratic path =
  case quadratic_assembly of
    Left explanation => do
      putStrLn explanation
      exitFailure
    Right assembly =>
      case !(writeFile path assembly) of
        Left error => do
          putStrLn ("Could not write generated assembly: " ++ show error)
          exitFailure
        Right () => putStrLn ("Wrote " ++ path)

private
check_quadratic : String -> IO ()
check_quadratic path =
  case quadratic_assembly of
    Left explanation => do
      putStrLn explanation
      exitFailure
    Right expected =>
      case !(readFile path) of
        Left error => do
          putStrLn ("Could not read assembly golden: " ++ show error)
          exitFailure
        Right actual =>
          if actual == expected
            then putStrLn ("Assembly golden matches " ++ path)
            else do
              putStrLn
                ("Assembly golden is stale: " ++ path ++
                 " (run `make update-golden` intentionally)")
              exitFailure

main : IO ()
main = do
  let failures = failed_tests tests
  if null failures
    then do
      putStrLn (show (length tests) ++ " ARMv7 backend tests passed.")
      case !getArgs of
        [program_name, "--update-golden", output_path] =>
          write_quadratic output_path
        [program_name, golden_path] => check_quadratic golden_path
        _ => pure ()
    else do
      putStrLn ("ARMv7 backend test failures: " ++ show failures)
      exitFailure
