module Backend.ARMv7.Main

import Backend.ARMv7.Codegen
import Compiler.Common
import Idris.Driver

main : IO ()
main =
  mainWithCodegens
    [(backend_name, android_armv7_codegen)]
