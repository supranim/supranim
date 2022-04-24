import osproc

proc cmd*(inputCmd: string, inputArgs: openarray[string]): any {.discardable.} =
    ## Short hand for executing shell commands via execProcess
    result = execProcess(inputCmd, args=inputArgs, options={poStdErrToStdOut, poUsePath})

proc cmdExec*(inputCmd: string): tuple[output: TaintedString, exitCode: int] =
    ## Execute a command
    execCmdEx(inputCmd)