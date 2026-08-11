module Backend.ARMv7.Lower

import Backend.ARMv7.IR
import Compiler.ANF
import Core.Name
import Core.Name.Namespace
import Core.TT.Primitive

%default covering

private
max_locals : Int
max_locals = 256

private
data RepresentationConstraint
  = HasRepresentation Int Representation
  | SameRepresentation Int Int

private
data RawInstruction
  = RawCopy Int Int
  | RawWordConstant Int Int
  | RawLoadFloat32 Int Int Int
  | RawFloatBinary FloatBinaryOperation Int Int Int
  | RawFloatUnary FloatUnaryOperation Int Int

private
record BuildState where
  constructor MkBuildState
  bound_variables : List Int
  variable_slots : List (Int, Int)
  next_slot : Int
  raw_instructions_reversed : List RawInstruction
  constraints : List RepresentationConstraint

private
empty_state : BuildState
empty_state = MkBuildState [] [] 0 [] []

private
is_ascii_letter : Char -> Bool
is_ascii_letter character =
  (character >= 'A' && character <= 'Z') ||
  (character >= 'a' && character <= 'z')

private
is_ascii_digit : Char -> Bool
is_ascii_digit character =
  character >= '0' && character <= '9'

private
is_symbol_start : Char -> Bool
is_symbol_start character =
  is_ascii_letter character || character == '_'

private
is_symbol_rest : Char -> Bool
is_symbol_rest character =
  is_symbol_start character || is_ascii_digit character

||| Validate the deliberately portable subset of C/ELF symbol spelling used by
||| this backend.  In particular, digits and Unicode letters cannot start a
||| symbol even if another assembler happens to accept them.
public export
validate_external_symbol : String -> Either String String
validate_external_symbol symbol =
  case unpack symbol of
    [] => Left "An exported ARM symbol cannot be empty"
    first :: rest =>
      if is_symbol_start first && all is_symbol_rest rest
        then Right symbol
        else Left ("Invalid C-compatible ARM symbol `" ++ symbol ++ "`")

private
renderer_name : String -> Name
renderer_name leaf =
  NS (mkNamespace "RendererPrimitives") (UN (Basic leaf))

private
data RendererPrimitive
  = BufferLoad
  | Binary FloatBinaryOperation
  | Unary FloatUnaryOperation

private
renderer_primitive : Name -> Maybe RendererPrimitive
renderer_primitive name =
  if name == renderer_name "float32_buffer_load"
    then Just BufferLoad
    else if name == renderer_name "float32_add"
      then Just (Binary AddFloat32)
      else if name == renderer_name "float32_subtract"
        then Just (Binary SubtractFloat32)
        else if name == renderer_name "float32_multiply"
          then Just (Binary MultiplyFloat32)
          else if name == renderer_name "float32_divide"
            then Just (Binary DivideFloat32)
            else if name == renderer_name "float32_negate"
              then Just (Unary NegateFloat32)
              else if name == renderer_name "float32_absolute"
                then Just (Unary AbsoluteFloat32)
                else if name == renderer_name "float32_square_root"
                  then Just (Unary SquareRootFloat32)
                  else Nothing

private
add_constraint : RepresentationConstraint -> BuildState -> BuildState
add_constraint constraint
               (MkBuildState bound slots next instructions constraints) =
  MkBuildState bound slots next instructions (constraint :: constraints)

private
add_instruction : RawInstruction -> BuildState -> BuildState
add_instruction instruction
                (MkBuildState bound slots next instructions constraints) =
  MkBuildState bound slots next (instruction :: instructions) constraints

private
bind_variable : String -> Int -> BuildState -> Either String BuildState
bind_variable role variable
              (MkBuildState bound slots next instructions constraints) =
  if elem variable bound
    then
      Left
        (role ++ " v" ++ show variable ++
         " is already defined in this numerical leaf")
    else if next >= max_locals
      then
        Left
          ("The numerical leaf needs more than " ++ show max_locals ++
           " dense four-byte stack homes")
      else
        Right
          (MkBuildState
            (variable :: bound)
            ((variable, next) :: slots)
            (next + 1)
            instructions
            constraints)

private
require_bound : String -> Int -> BuildState -> Either String ()
require_bound role variable state =
  if elem variable state.bound_variables
    then Right ()
    else
      Left
        (role ++ " reads unbound ANF local v" ++ show variable)

private
bind_arguments :
  List Int ->
  List Representation ->
  BuildState ->
  Either String BuildState
bind_arguments [] [] state = Right state
bind_arguments (argument :: rest) (representation :: representations) state = do
  with_argument <- bind_variable "Argument" argument state
  bind_arguments
    rest
    representations
    (add_constraint (HasRepresentation argument representation) with_argument)
bind_arguments variables representations state =
  Left
    ("Source ABI describes " ++ show (length representations) ++
     " arguments, but ANF contains " ++ show (length variables))

private
add_copy : Int -> Int -> BuildState -> BuildState
add_copy destination source state =
  add_instruction (RawCopy destination source)
    (add_constraint (SameRepresentation destination source) state)

private
add_word_constant : Int -> Int -> BuildState -> BuildState
add_word_constant destination value state =
  add_instruction (RawWordConstant destination value)
    (add_constraint (HasRepresentation destination Word32) state)

private
add_buffer_load : Int -> Int -> Int -> BuildState -> BuildState
add_buffer_load destination buffer index state =
  add_instruction (RawLoadFloat32 destination buffer index)
    (add_constraint (HasRepresentation destination Float32)
      (add_constraint (HasRepresentation buffer Float32Pointer)
        (add_constraint (HasRepresentation index Word32) state)))

private
add_float_binary :
  FloatBinaryOperation ->
  Int ->
  Int ->
  Int ->
  BuildState ->
  BuildState
add_float_binary operation destination left right state =
  add_instruction (RawFloatBinary operation destination left right)
    (add_constraint (HasRepresentation destination Float32)
      (add_constraint (HasRepresentation left Float32)
        (add_constraint (HasRepresentation right Float32) state)))

private
add_float_unary :
  FloatUnaryOperation ->
  Int ->
  Int ->
  BuildState ->
  BuildState
add_float_unary operation destination value state =
  add_instruction (RawFloatUnary operation destination value)
    (add_constraint (HasRepresentation destination Float32)
      (add_constraint (HasRepresentation value Float32) state))

private
lower_external :
  Int ->
  Name ->
  List AVar ->
  BuildState ->
  Either String BuildState
lower_external destination name arguments state =
  case renderer_primitive name of
    Nothing =>
      Left
        ("Unsupported external primitive `" ++ show name ++
         "`; renderer intrinsics are matched by exact fully qualified name")
    Just BufferLoad =>
      case arguments of
        [ALocal buffer, ALocal index] => do
          require_bound "Float32 buffer load" buffer state
          require_bound "Float32 buffer index" index state
          with_destination <- bind_variable "Let destination" destination state
          Right (add_buffer_load destination buffer index with_destination)
        _ =>
          Left
            ("Renderer primitive `" ++ show name ++
             "` requires two local operands, got " ++ show arguments)
    Just (Binary operation) =>
      case arguments of
        [ALocal left, ALocal right] => do
          require_bound (show operation ++ " left operand") left state
          require_bound (show operation ++ " right operand") right state
          with_destination <- bind_variable "Let destination" destination state
          Right
            (add_float_binary
              operation destination left right with_destination)
        _ =>
          Left
            ("Renderer primitive `" ++ show name ++
             "` requires two local operands, got " ++ show arguments)
    Just (Unary operation) =>
      case arguments of
        [ALocal value] => do
          require_bound (show operation ++ " operand") value state
          with_destination <- bind_variable "Let destination" destination state
          Right (add_float_unary operation destination value with_destination)
        _ =>
          Left
            ("Renderer primitive `" ++ show name ++
             "` requires one local operand, got " ++ show arguments)

private
lower_value : Int -> ANF -> BuildState -> Either String BuildState
lower_value destination (AV _ (ALocal source)) state = do
  require_bound "Copy" source state
  with_destination <- bind_variable "Let destination" destination state
  Right (add_copy destination source with_destination)
lower_value destination (APrimVal _ (I32 value)) state = do
  with_destination <- bind_variable "Let destination" destination state
  Right (add_word_constant destination (cast value) with_destination)
lower_value destination (APrimVal _ (I value)) state =
  Left
    ("Idris Int is 64-bit in the pinned compiler; use Int32 in this " ++
     "one-word ARMv7 ABI (got literal " ++ show value ++ ")")
lower_value destination (AExtPrim _ _ name arguments) state =
  lower_external destination name arguments state
lower_value destination expression state =
  Left
    ("Unsupported ANF value in the runtime-free numerical subset: " ++
     show expression)

||| ANF may place administrative lets inside the right-hand side of another
||| let.  Flatten that sequencing while keeping the outer destination out of
||| scope until the nested value has been produced.
private
lower_assignment : Int -> ANF -> BuildState -> Either String BuildState
lower_assignment destination (ALet _ nested_destination nested_value body) state = do
  after_nested <-
    lower_assignment nested_destination nested_value state
  lower_assignment destination body after_nested
lower_assignment destination value state =
  lower_value destination value state

private
fresh_variable_from : Int -> List Int -> Int
fresh_variable_from candidate used =
  if elem candidate used
    then fresh_variable_from (candidate + 1) used
    else candidate

private
collect_tail : ANF -> BuildState -> Either String (BuildState, Int)
collect_tail (ALet _ destination value body) state = do
  after_value <- lower_assignment destination value state
  collect_tail body after_value
collect_tail (AV _ (ALocal result)) state = do
  require_bound "Return" result state
  Right (state, result)
collect_tail expression state = do
  let result = fresh_variable_from 0 state.bound_variables
  after_value <- lower_value result expression state
  Right (after_value, result)

private
relations :
  Int ->
  List RepresentationConstraint ->
  (List Int, List Representation)
relations variable [] = ([], [])
relations variable (HasRepresentation constrained representation :: rest) =
  let (neighbours, representations) = relations variable rest in
    if variable == constrained
      then (neighbours, representation :: representations)
      else (neighbours, representations)
relations variable (SameRepresentation left right :: rest) =
  let (neighbours, representations) = relations variable rest in
    if variable == left
      then (right :: neighbours, representations)
      else if variable == right
        then (left :: neighbours, representations)
        else (neighbours, representations)

private
insert_representation :
  Representation ->
  List Representation ->
  List Representation
insert_representation representation representations =
  if elem representation representations
    then representations
    else representation :: representations

private
insert_representations :
  List Representation ->
  List Representation ->
  List Representation
insert_representations [] accumulated = accumulated
insert_representations (representation :: rest) accumulated =
  insert_representations rest
    (insert_representation representation accumulated)

private
walk_constraints :
  List RepresentationConstraint ->
  List Int ->
  List Int ->
  List Representation ->
  List Representation
walk_constraints constraints [] visited found = found
walk_constraints constraints (variable :: pending) visited found =
  if elem variable visited
    then walk_constraints constraints pending visited found
    else
      let (neighbours, direct) = relations variable constraints
          found_now = insert_representations direct found
      in walk_constraints
           constraints
           (neighbours ++ pending)
           (variable :: visited)
           found_now

private
infer_representation :
  List RepresentationConstraint ->
  Int ->
  Either String Representation
infer_representation constraints variable =
  case walk_constraints constraints [variable] [] [] of
    [] =>
      Left
        ("No unboxed representation can be inferred for ANF local v" ++
         show variable)
    [representation] => Right representation
    representations =>
      Left
        ("ANF local v" ++ show variable ++
         " has conflicting representations: " ++ show representations)

private
find_slot : Int -> List (Int, Int) -> Either String Int
find_slot variable [] =
  Left ("Internal error: no dense frame slot for v" ++ show variable)
find_slot variable ((candidate, slot) :: rest) =
  if variable == candidate
    then Right slot
    else find_slot variable rest

private
resolve_local :
  List (Int, Int) ->
  List RepresentationConstraint ->
  Int ->
  Either String Local
resolve_local slots constraints variable = do
  slot <- find_slot variable slots
  representation <- infer_representation constraints variable
  Right (MkLocal variable slot representation)

private
expect_representation :
  String ->
  Representation ->
  Local ->
  Either String ()
expect_representation role expected local =
  if local.representation == expected
    then Right ()
    else
      Left
        (role ++ " expected " ++ show expected ++
         ", but " ++ show local ++ " has " ++ show local.representation)

private
resolve_instruction :
  List (Int, Int) ->
  List RepresentationConstraint ->
  RawInstruction ->
  Either String Instruction
resolve_instruction slots constraints (RawCopy destination source) = do
  destination_local <- resolve_local slots constraints destination
  source_local <- resolve_local slots constraints source
  if destination_local.representation == source_local.representation
    then Right (Copy destination_local source_local)
    else Left "Internal error: copy representation constraint was not solved"
resolve_instruction slots constraints (RawWordConstant destination value) = do
  destination_local <- resolve_local slots constraints destination
  expect_representation "Word constant" Word32 destination_local
  Right (WordConstant destination_local value)
resolve_instruction slots constraints
                    (RawLoadFloat32 destination buffer index) = do
  destination_local <- resolve_local slots constraints destination
  buffer_local <- resolve_local slots constraints buffer
  index_local <- resolve_local slots constraints index
  expect_representation "Buffer load result" Float32 destination_local
  expect_representation "Buffer load pointer" Float32Pointer buffer_local
  expect_representation "Buffer load index" Word32 index_local
  Right (LoadFloat32 destination_local buffer_local index_local)
resolve_instruction slots constraints
                    (RawFloatBinary operation destination left right) = do
  destination_local <- resolve_local slots constraints destination
  left_local <- resolve_local slots constraints left
  right_local <- resolve_local slots constraints right
  expect_representation "Float binary result" Float32 destination_local
  expect_representation "Float binary left operand" Float32 left_local
  expect_representation "Float binary right operand" Float32 right_local
  Right (FloatBinary operation destination_local left_local right_local)
resolve_instruction slots constraints
                    (RawFloatUnary operation destination value) = do
  destination_local <- resolve_local slots constraints destination
  value_local <- resolve_local slots constraints value
  expect_representation "Float unary result" Float32 destination_local
  expect_representation "Float unary operand" Float32 value_local
  Right (FloatUnary operation destination_local value_local)

private
resolve_instructions :
  List (Int, Int) ->
  List RepresentationConstraint ->
  List RawInstruction ->
  Either String (List Instruction)
resolve_instructions slots constraints [] = Right []
resolve_instructions slots constraints (instruction :: rest) = do
  resolved <- resolve_instruction slots constraints instruction
  more <- resolve_instructions slots constraints rest
  Right (resolved :: more)

private
resolve_locals :
  List (Int, Int) ->
  List RepresentationConstraint ->
  List Int ->
  Either String (List Local)
resolve_locals slots constraints [] = Right []
resolve_locals slots constraints (variable :: rest) = do
  local <- resolve_local slots constraints variable
  more <- resolve_locals slots constraints rest
  Right (local :: more)

private
aligned_frame_bytes : Int -> Int
aligned_frame_bytes slots =
  let bytes = slots * 4 in
    if bytes `mod` 8 == 0 then bytes else bytes + 4

private
resolve_function :
  String ->
  List Int ->
  Int ->
  Representation ->
  BuildState ->
  Either String LeafFunction
resolve_function symbol argument_variables result_variable result_representation state = do
  arguments <-
    resolve_locals state.variable_slots state.constraints argument_variables
  instructions <-
    resolve_instructions
      state.variable_slots
      state.constraints
      (reverse state.raw_instructions_reversed)
  result <-
    resolve_local state.variable_slots state.constraints result_variable
  expect_representation "Function result" result_representation result
  Right
    (MkLeafFunction
      symbol
      arguments
      instructions
      result
      (aligned_frame_bytes state.next_slot))

||| Validate and lower one exported ANF function into the representation-tagged
||| leaf IR.
||| Unknown calls, heap values, control flow, ambiguous representations, and
||| malformed def-use chains are rejected before assembly emission.
public export
lower_leaf :
  String ->
  List Representation ->
  Representation ->
  ANFDef ->
  Either String LeafFunction
lower_leaf requested_symbol argument_representations result_representation
           (MkAFun argument_variables body) = do
  symbol <- validate_external_symbol requested_symbol
  if result_representation /= Float32
    then
      Left
        ("Export `" ++ symbol ++
         "` must return RendererPrimitives.Float32, not " ++
         show result_representation)
    else if length argument_variables > 4
    then
      Left
        ("Export `" ++ symbol ++
         "` has more than four 32-bit softfp ABI arguments")
    else do
      with_arguments <-
        bind_arguments
          argument_variables
          argument_representations
          empty_state
      (collected, result_variable) <- collect_tail body with_arguments
      let with_result =
            add_constraint
              (HasRepresentation result_variable result_representation)
              collected
      resolve_function
        symbol
        argument_variables
        result_variable
        result_representation
        with_result
lower_leaf requested_symbol argument_representations result_representation
           definition =
  Left
    ("Export `" ++ requested_symbol ++
     "` is not a runtime-free function: " ++ show definition)
