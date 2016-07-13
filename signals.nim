#
#
#      Wanted asynchronous threaded webserver
#        (c) Copyright 2016 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

when defined(windows):
  import winlean

  type
    HANDLER_ROUTINE* = proc(ctrlType: Dword): WINBOOL {.stdcall.}

  proc setConsoleCtrlHandler*(handlerRoutine: HANDLER_ROUTINE, add: WINBOOL): WINBOOL
       {.importc: "SetConsoleCtrlHandler", dynlib: "kernel32", stdcall.}
