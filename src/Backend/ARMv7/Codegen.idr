module Backend.ARMv7.Codegen

import Backend.ARMv7.Emit
import Backend.ARMv7.IR
import Backend.ARMv7.Lower
import Compiler.ANF
import Compiler.Common
import Core.Context
import Core.Env
import Core.Normalise
import Core.TT
import Data.String
import Idris.Syntax
import Libraries.Utils.Path

%default covering

||| Command-line name registered with Idris 2.
public export
backend_name : String
backend_name = "android-armv7"

private
record ExportABI where
  constructor MkExportABI
  internal_name : Name
  external_symbol : String
  argument_representations : List Representation
  result_representation : Representation

private
renderer_type_name : String -> Name
renderer_type_name leaf =
  NS (mkNamespace "RendererPrimitives") (UN (Basic leaf))

private
classify_abi_type : Term variables -> Either String Representation
classify_abi_type (PrimVal _ (PrT Int32Type)) = Right Word32
classify_abi_type (PrimVal _ (PrT primitive_type)) =
  Left ("unsupported source primitive type `" ++ show primitive_type ++ "`")
classify_abi_type (Ref _ (TyCon 0) name) =
  if name == renderer_type_name "Float32"
    then Right Float32
    else if name == renderer_type_name "Float32Buffer"
      then Right Float32Pointer
      else Left ("unsupported source type `" ++ show name ++ "`")
classify_abi_type type = Left "unsupported source type"

private
parse_source_signature :
  Term variables ->
  Either String (List Representation, Representation)
parse_source_signature
  (Bind _ argument_name (Pi _ multiplicity Explicit argument_type) scope) = do
    if isErased multiplicity
      then
        Left
          ("erased argument `" ++ show argument_name ++
           "` cannot cross the ARM C ABI")
      else do
        argument_representation <- classify_abi_type argument_type
        (more_arguments, result_representation) <- parse_source_signature scope
        Right
          (argument_representation :: more_arguments, result_representation)
parse_source_signature (Bind _ argument_name (Pi _ _ _ argument_type) scope) =
  Left
    ("implicit argument `" ++ show argument_name ++
     "` is not supported by the ARM C ABI")
parse_source_signature result_type = do
  result_representation <- classify_abi_type result_type
  Right ([], result_representation)

private
resolve_export_abi :
  {auto c : Ref Ctxt Defs} ->
  (Name, String) ->
  Core ExportABI
resolve_export_abi (internal_name, external_symbol) = do
  definitions <- get Ctxt
  source_type <-
    case !(lookupTyExact internal_name (gamma definitions)) of
      Nothing =>
        throw
          (UserError
            ("Could not find the source type of exported function `" ++
             show internal_name ++ "`"))
      Just found => pure found
  normalised_type <- normalise definitions Env.empty source_type
  full_type <- toFullNames normalised_type
  case parse_source_signature full_type of
    Left explanation =>
      throw
        (UserError
          ("android-armv7 rejected source ABI for `" ++
           show internal_name ++ "`: " ++ explanation ++
           ". Supported arguments are RendererPrimitives.Float32, " ++
           "RendererPrimitives.Float32Buffer, and Int32; the result must " ++
           "be RendererPrimitives.Float32."))
    Right (arguments, result) =>
      if result /= Float32
        then
          throw
            (UserError
              ("android-armv7 rejected source ABI for `" ++
               show internal_name ++
               "`: result must be RendererPrimitives.Float32, not " ++
               show result ++ "."))
        else
          pure (MkExportABI internal_name external_symbol arguments result)

private
comment_each_line : String -> String
comment_each_line source =
  fastConcat (map (\line => "@   " ++ line ++ "\n") (lines source))

private
lookup_anf_definition :
  Name ->
  List (Name, ANFDef) ->
  Maybe ANFDef
lookup_anf_definition requested [] = Nothing
lookup_anf_definition requested ((name, definition) :: rest) =
  if requested == name
    then Just definition
    else lookup_anf_definition requested rest

private
find_duplicate : List String -> Maybe String
find_duplicate [] = Nothing
find_duplicate (symbol :: rest) =
  if elem symbol rest
    then Just symbol
    else find_duplicate rest

private
validate_exports : List ExportABI -> Either String ()
validate_exports [] =
  Left
    ("No functions were selected. Add " ++
     "%export \"android-armv7:<c_symbol>\" to a numerical leaf.")
validate_exports exports =
  case find_duplicate (map external_symbol exports) of
    Nothing => Right ()
    Just duplicate =>
      Left ("Duplicate exported C symbol `" ++ duplicate ++ "`")

private
render_selected_export : ExportABI -> String
render_selected_export selected =
  "@ " ++ show selected.internal_name ++ " -> " ++
  selected.external_symbol ++ "\n"

private
lower_exported_functions :
  List ExportABI ->
  List (Name, ANFDef) ->
  Either String String
lower_exported_functions [] definitions = Right ""
lower_exported_functions
  (selected :: rest)
  definitions = do
    definition <-
      case lookup_anf_definition selected.internal_name definitions of
        Nothing =>
          Left
            ("No ANF definition was produced for exported function `" ++
             show selected.internal_name ++ "`")
        Just found => Right found
    leaf <-
      lower_leaf
        selected.external_symbol
        selected.argument_representations
        selected.result_representation
        definition
    leaf_assembly <- emit_leaf leaf
    more <- lower_exported_functions rest definitions
    Right
      ("\n@ Validated leaf IR for " ++ selected.external_symbol ++ ":\n" ++
       comment_each_line (render_ir leaf) ++
       leaf_assembly ++
       more)

||| Validate selected exports, lower them through the representation-tagged
||| numerical IR, and render one standalone GNU/Clang-compatible ARM assembly
||| translation unit.
private
render_backend_assembly :
  List ExportABI ->
  List (Name, ANFDef) ->
  Either String String
render_backend_assembly exports definitions = do
  validate_exports exports
  lowered <-
    lower_exported_functions
      exports
      definitions
  Right
    (assembly_header ++
     "\n@ Selected Idris exports:\n" ++
     fastConcat (map render_selected_export exports) ++
     lowered ++
     assembly_footer)

private
fully_qualified_export :
  {auto c : Ref Ctxt Defs} ->
  (Name, String) ->
  Core (Name, String)
fully_qualified_export (internal_name, external_symbol) = do
  qualified_name <- toFullNames internal_name
  pure (qualified_name, external_symbol)

private
compile_android_armv7 :
  Ref Ctxt Defs ->
  Ref Syn SyntaxInfo ->
  (temporary_directory : String) ->
  (output_directory : String) ->
  ClosedTerm ->
  (requested_output_name : String) ->
  Core (Maybe String)
compile_android_armv7 definitions syntax
                      temporary_directory output_directory
                      term requested_output_name = do
  resolved_compile_data <-
    getCompileDataWith [backend_name] False ANF term

  qualified_exports <-
    traverse fully_qualified_export (exported resolved_compile_data)

  export_abis <- traverse resolve_export_abi qualified_exports

  let assembly_file =
        output_directory </>
          (requested_output_name ++ ".android-armv7.S")

  assembly_source <-
    case render_backend_assembly export_abis (anf resolved_compile_data) of
      Left explanation =>
        throw
          (UserError
            ("android-armv7 rejected the reachable program: " ++
             explanation))
      Right source => pure source

  Core.writeFile assembly_file assembly_source
  pure (Just assembly_file)

private
execute_android_armv7 :
  Ref Ctxt Defs ->
  Ref Syn SyntaxInfo ->
  (temporary_directory : String) ->
  ClosedTerm ->
  Core ()
execute_android_armv7 definitions syntax temporary_directory term =
  throw
    (UserError
      ("The android-armv7 backend emits a .S translation unit. " ++
       "Compile it with Android-target Clang; direct execution is not " ++
       "implemented."))

||| Whole-program custom code generator for selected runtime-free exports.
public export
android_armv7_codegen : Codegen
android_armv7_codegen =
  MkCG
    compile_android_armv7
    execute_android_armv7
    Nothing
    Nothing
