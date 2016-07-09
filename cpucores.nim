#
#
#      Wanted asynchronous threaded webserver
#        (c) Copyright 2016 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

import os

when defined(macosx) or defined(freebsd):
  proc sysctl(name: ptr cint, namelen: cuint, oldp: pointer, oldplen: ptr int,
              newp: pointer, newplen: int): cint
       {.importc: "sysctl", header: """#include <sys/types.h>
                                       #include <sys/sysctl.h>"""}
  const CTL_HW = 6
  when defined(macosx):
    const HW_NCPU = 25 # HW_AVAILCPU
  else:
    const HW_NCPU = 3 
    
  proc getCoresNumber*(): int =
    var coresNumber = 0.cint
    var size = sizeof(cint)
    var namearr = [CTL_HW.cint, HW_NCPU.cint]
    if sysctl(addr(namearr[0]), 2, cast[pointer](addr coresNumber), addr size,
              nil, 0) != 0:
      raiseOsError(osLastError())
    result = int(coresNumber)

elif defined(netbsd) or defined(openbsd):
  proc sysctl(name: ptr cint, namelen: cuint, oldp: pointer, oldplen: ptr int,
              newp: pointer, newplen: int): cint
       {.importc: "sysctl", header: """#include <sys/param.h>
                                       #include <sys/sysctl.h>"""}
  const
    HW_NCPU = 3
    CTL_HW = 6

  proc getCoresNumber*(): int =
    var coresNumber = 0.cint
    var size = sizeof(cint)
    var namearr = [CTL_HW.cint, HW_NCPU.cint]
    if sysctl(addr(namearr[0]), 2, cast[pointer](addr coresNumber), addr size,
              nil, 0) != 0:
      raiseOsError(osLastError())
    result = int(coresNumber)

elif defined(linux) or defined(solaris):
  var SC_NPROCESSORS_ONLN {.importc: "_SC_NPROCESSORS_ONLN",
                            header: "unistd.h".} : cint

  proc sysconf(name: cint): clong
       {.importc: "sysconf", header: "unistd.h".}

  proc getCoresNumber*(): int =
    result = sysconf(SC_NPROCESSORS_ONLN).int

elif defined(windows):
  type
    SYSTEM_INFO {.final, pure.} = object
      wProcessorArchitecture: int16
      wReserved: int16
      dwPageSize: int32
      lpMinimumApplicationAddress: pointer
      lpMaximumApplicationAddress: pointer
      dwActiveProcessorMask: ptr int32
      dwNumberOfProcessors: int32
      dwProcessorType: int32
      dwAllocationGranularity: int32
      wProcessorLevel: int16
      wProcessorRevision: int16

  proc getSystemInfo(lpSystemInfo: ptr SYSTEM_INFO): void
       {.stdcall, dynlib: "kernel32", importc: "GetSystemInfo".}

  proc getCoresNumber*(): int =
    var s = SYSTEM_INFO()
    getSystemInfo(addr s)
    result = s.dwNumberOfProcessors
else:
  {.error: "Unsupported architecture".}
