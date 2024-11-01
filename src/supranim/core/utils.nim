when defined linux:
  proc malloc_trim*(size: csize_t): cint {.importc, varargs, header: "malloc.h".}

template freemem*(x: untyped) =
  {.gcsafe.}:
    when defined linux:
      discard malloc_trim(sizeof(x).csize_t)
    else:
      discard