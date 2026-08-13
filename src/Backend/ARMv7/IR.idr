module Backend.ARMv7.IR

import Data.String

%default total

||| The three unboxed 32-bit representations admitted by the first backend
||| milestone.  This is deliberately smaller than Idris's source type system.
public export
data Representation
  = Word32
  | Float32
  | Float32Pointer

public export
Eq Representation where
  Word32 == Word32 = True
  Float32 == Float32 = True
  Float32Pointer == Float32Pointer = True
  _ == _ = False

public export
Show Representation where
  show Word32 = "Word32"
  show Float32 = "Float32"
  show Float32Pointer = "Float32Pointer"

||| A validated ANF local and its dense four-byte stack home.
public export
record Local where
  constructor MkLocal
  anf_variable : Int
  frame_slot : Int
  representation : Representation

public export
Show Local where
  show local =
    "v" ++ show local.anf_variable ++
    ":" ++ show local.representation ++
    "@" ++ show local.frame_slot

public export
data FloatBinaryOperation
  = AddFloat32
  | SubtractFloat32
  | MultiplyFloat32
  | DivideFloat32

public export
Show FloatBinaryOperation where
  show AddFloat32 = "add"
  show SubtractFloat32 = "subtract"
  show MultiplyFloat32 = "multiply"
  show DivideFloat32 = "divide"

public export
data FloatUnaryOperation
  = NegateFloat32
  | AbsoluteFloat32
  | SquareRootFloat32

public export
Show FloatUnaryOperation where
  show NegateFloat32 = "negate"
  show AbsoluteFloat32 = "absolute"
  show SquareRootFloat32 = "square-root"

||| The validated, straight-line renderer leaf IR.  Each constructor fixes the
||| representation of its operands; `Lower` checks those contracts before an
||| instruction can reach the ARM emitter.
public export
data Instruction
  = Copy Local Local
  | WordConstant Local Int
  | LoadFloat32 Local Local Local
  | FloatBinary FloatBinaryOperation Local Local Local
  | FloatUnary FloatUnaryOperation Local Local

public export
Show Instruction where
  show (Copy destination source) =
    show destination ++ " = copy " ++ show source
  show (WordConstant destination value) =
    show destination ++ " = word " ++ show value
  show (LoadFloat32 destination buffer index) =
    show destination ++ " = load " ++ show buffer ++ "[" ++ show index ++ "]"
  show (FloatBinary operation destination left right) =
    show destination ++ " = " ++ show operation ++
    " " ++ show left ++ " " ++ show right
  show (FloatUnary operation destination value) =
    show destination ++ " = " ++ show operation ++ " " ++ show value

||| A runtime-free, C-callable numerical leaf after ANF validation.
public export
record LeafFunction where
  constructor MkLeafFunction
  external_symbol : String
  arguments : List Local
  instructions : List Instruction
  result : Local
  frame_bytes : Int

public export
render_ir : LeafFunction → String
render_ir function =
  unlines
    ([ "function " ++ function.external_symbol
     , "arguments: " ++ show function.arguments
     ] ++
     map (\instruction ⇒ "  " ++ show instruction) function.instructions ++
     [ "return " ++ show function.result
     , "frame-bytes: " ++ show function.frame_bytes
     ])
