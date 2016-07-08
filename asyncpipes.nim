#
#
#      Wanted asynchronous threaded webserver
#        (c) Copyright 2016 Eugene Kabanov
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import asyncdispatch, os

type
  AsyncPipe* = AsyncFD

when defined(windows):
  import winlean

  proc QueryPerformanceCounter(res: var int64)
       {.importc: "QueryPerformanceCounter", stdcall, dynlib: "kernel32".}
  proc connectNamedPipe(hNamedPipe: Handle, lpOverlapped: pointer): WINBOOL
       {.importc: "ConnectNamedPipe", stdcall, dynlib: "kernel32".}
  const
    FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000'i32
    PIPE_WAIT = 0x00000000'i32
    PIPE_TYPE_BYTE = 0x00000000'i32
    ERROR_PIPE_CONNECTED = 535
    ERROR_PIPE_BUSY = 231

  proc asyncPipes*(inSize = 65536'i32,
                   outSize = 65536'i32,
                   regAsync = true): tuple[readPipe, writePipe: AsyncPipe] =
    var number = 0'i64
    var pipeName: WideCString
    var pipeIn: Handle
    var pipeOut: Handle
    var sa: SECURITY_ATTRIBUTES

    sa.nLength = sizeof(SECURITY_ATTRIBUTES).cint
    sa.lpSecurityDescriptor = nil
    sa.bInheritHandle = 1

    while true:
      QueryPerformanceCounter(number)
      let p = r"\\.\pipe\asyncpipe_" & $number
      pipeName = newWideCString(p)
      var openMode = FILE_FLAG_FIRST_PIPE_INSTANCE or FILE_FLAG_OVERLAPPED or
                     PIPE_ACCESS_INBOUND
      var pipeMode = PIPE_TYPE_BYTE or PIPE_WAIT
      pipeIn = createNamedPipe(pipeName, openMode, pipeMode, 1'i32,
                               inSize, outSize,
                               1'i32, addr sa)
      if pipeIn == INVALID_HANDLE_VALUE:
        let err = osLastError()
        if err.int32 != ERROR_PIPE_BUSY:
          raiseOsError(osLastError())
      else:
        break

    pipeOut = createFileW(pipeName, GENERIC_WRITE, 0, addr(sa), OPEN_EXISTING,
                          FILE_FLAG_OVERLAPPED, 0)
    if pipeOut == INVALID_HANDLE_VALUE:
      discard closeHandle(pipeIn)
      raiseOsError(osLastError())

    result = (readPipe: AsyncPipe(pipeIn), writePipe: AsyncPipe(pipeOut))

    var covl = OVERLAPPED()
    let res = connectNamedPipe(pipeIn, cast[pointer](addr covl))
    if res == 0:
      let err = osLastError().int32
      if err == ERROR_PIPE_CONNECTED:
        discard
      elif err == ERROR_IO_PENDING:
        var bytesRead = 0.Dword
        var rovl = OVERLAPPED()
        if getOverlappedResult(pipeIn, addr rovl, bytesRead, 1) == 0:
          discard closeHandle(pipeIn)
          discard closeHandle(pipeOut)
          raiseOsError(osLastError())
      else:
        discard closeHandle(pipeIn)
        discard closeHandle(pipeOut)
        raiseOsError(osLastError())

    if regAsync:
      register(pipeIn.AsyncFD)
      register(pipeOut.AsyncFD)

  proc close*(pipe: AsyncPipe) =
    if closeHandle(pipe.Handle) == 0:
      raiseOsError(osLastError())

  proc write*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[void] =
    var retFuture = newFuture[void]("asyncpipes.write")
    var ol = PCustomOverlapped()
    GC_ref(ol)
    ol.data = CompletionData(fd: pipe.AsyncFD, cb:
      proc (fd: AsyncFD, bytesCount: DWord, errcode: OSErrorCode) =
        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            assert bytesCount == nbytes.int32
            retFuture.complete()
          else:
            retFuture.fail(newException(OSError, osErrorMsg(errcode)))
    )
    let res = writeFile(pipe.Handle, data, nbytes.int32, nil,
                        cast[POVERLAPPED](ol))
    if not res.bool:
      let err = osLastError()
      if err.int32 != ERROR_IO_PENDING:
        GC_unref(ol)
        retFuture.fail(newException(OSError, osErrorMsg(err)))
    else:
      var bytesWritten = 0.Dword
      let ores = getOverlappedResult(pipe.Handle, cast[POVERLAPPED](ol),
                                     bytesWritten, false.WINBOOL)
      if not ores.bool:
        retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
      else:
        assert bytesWritten == nbytes
        retFuture.complete()
    return retFuture

  proc readInto*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[int] =
    var retFuture = newFuture[int]("asyncpipes.readInto")
    var ol = PCustomOverlapped()
    GC_ref(ol)
    ol.data = CompletionData(fd: pipe.AsyncFD, cb:
      proc (fd: AsyncFD, bytesCount: DWord, errcode: OSErrorCode) =
        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            assert (bytesCount > 0 and bytesCount <= nbytes.int32)
            retFuture.complete(bytesCount)
          else:
            retFuture.fail(newException(OSError, osErrorMsg(errcode)))
    )
    let res = readFile(pipe.Handle, data, nbytes.int32, nil,
                       cast[POVERLAPPED](ol))
    if not res.bool:
      let err = osLastError()
      if err.int32 != ERROR_IO_PENDING:
        GC_unref(ol)
        retFuture.fail(newException(OSError, osErrorMsg(err)))
    else:
      var bytesRead = 0.DWord
      let ores = getOverlappedResult(pipe.Handle, cast[POverlapped](ol),
                                     bytesRead, false.WINBOOL)
      if not ores.bool:
        retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
      else:
        assert (bytesRead > 0 and bytesRead <= nbytes)
        retFuture.complete(bytesRead)
    return retFuture
else:
  import posix

  proc setNonBlocking(fd: cint) {.inline.} =
    var x = fcntl(fd, F_GETFL, 0)
    if x == -1:
      raiseOSError(osLastError())
    else:
      var mode = x or O_NONBLOCK
      if fcntl(fd, F_SETFL, mode) == -1:
        raiseOSError(osLastError())

  proc asyncPipes*(regAsync = true): tuple[readPipe, writePipe: AsyncPipe] =
    var fds: array[2, cint]
    if posix.pipe(fds) == -1:
      raiseOSError(osLastError())
    setNonBlocking(fds[0])
    setNonBlocking(fds[1])
    if regAsync:
      register(fds[0].AsyncFD)
      register(fds[1].AsyncFD)
    result = (readPipe: fds[0].AsyncPipe, writePipe: fds[1].AsyncPipe)

  proc close*(pipe: AsyncPipe) =
    if posix.close(pipe.cint) != 0:
      raiseOSError(osLastError())

  proc write*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[void] =
    var retFuture = newFuture[void]("asyncpipes.write")
    var written = 0
    proc cb(fd: AsyncFD): bool =
      result = true
      let reminder = nbytes - written
      let pdata = cast[pointer](cast[uint](data) + written.uint)
      let res = posix.write(pipe.cint, pdata, reminder.cint)
      if res < 0:
        let lastError = osLastError()
        if lastError.int32 != EAGAIN:
          retFuture.fail(newException(OSError, osErrorMsg(lastError)))
        else:
          result = false # We still want this callback to be called.
      else:
        written.inc(res)
        if res != reminder:
          result = false
        else:
          retFuture.complete()
    if not cb(pipe.AsyncFD):
      addWrite(pipe.AsyncFD, cb)
    return retFuture

  proc readInto*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[int] =
    var retFuture = newFuture[int]("asyncpipes.readInto")
    proc cb(fd: AsyncFD): bool =
      result = true
      let res = posix.read(pipe.cint, data, nbytes.cint)
      if res < 0:
        let lastError = osLastError()
        if lastError.int32 != EAGAIN:
          retFuture.fail(newException(OSError, osErrorMsg(lastError)))
        else:
          result = false # We still want this callback to be called.
      elif res == 0:
        retFuture.complete(0)
      else:
        retFuture.complete(res)
    if not cb(pipe.AsyncFD):
      addRead(pipe.AsyncFD, cb)
    return retFuture

when isMainModule:
  var inBuffer = newString(64)
  var outBuffer = "TEST STRING BUFFER"
  var o = asyncPipes()
  waitFor write(o.writePipe, cast[pointer](addr outBuffer[0]),
                outBuffer.len)
  var c = waitFor readInto(o.readPipe, cast[pointer](addr inBuffer[0]),
                           inBuffer.len)
  inBuffer.setLen(c)
  doAssert(inBuffer == outBuffer)
