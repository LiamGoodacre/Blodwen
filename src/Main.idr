module Main

import Core.Binary
import Core.TT
import Core.Normalise
import Core.Typecheck
import Core.Unify
import Core.Context
import Core.ProcessTT
import Core.RawContext
import Core.Directory
import Core.Options

import TTImp.Elab
import TTImp.ProcessTTImp
import TTImp.TTImp
import TTImp.REPL

import Parser.RawImp

usageMsg : Core () ()
usageMsg = coreLift $ putStrLn "Usage: blodwen [source file]"

stMain : Core () ()
stMain 
    = do c <- newRef Ctxt initCtxt
         [_, fname] <- coreLift getArgs | _ => usageMsg
         coreLift $ putStrLn $ "Loading " ++ fname
         u <- newRef UST initUState
         case span (/= '.') fname of
              (_, ".tt") => do coreLift $ putStrLn "Processing as TT"
                               ProcessTT.process fname
                               writeToTTI (getTTIFileName fname)
              (_, ".tti") => do coreLift $ putStrLn "Processing as TTI"
                                readFromTTI fname
              _ => do coreLift $ putStrLn "Processing as TTImp"
                      ProcessTTImp.process fname
                      writeToTTI (getTTIFileName fname)
         repl {c} {u}

main : IO ()
main = do putStrLn "Welcome to Blodwen. Good luck."
          coreRun stMain
               (\err : Error () => putStrLn ("Uncaught error: " ++ show err))
               (\res => pure ())
