#
#
#      Wanted asynchronous threaded webserver
#        (c) Copyright 2016 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#
import asyncdispatch, uri, os, net, strtabs, constants

type
  HttpCode* = enum
    Http100 = "100 Continue",
    Http101 = "101 Switching Protocols",
    Http200 = "200 OK",
    Http201 = "201 Created",
    Http202 = "202 Accepted",
    Http203 = "203 Non-Authoritative Information",
    Http204 = "204 No Content",
    Http205 = "205 Reset Content",
    Http206 = "206 Partial Content",
    Http300 = "300 Multiple Choices",
    Http301 = "301 Moved Permanently",
    Http302 = "302 Found",
    Http303 = "303 See Other",
    Http304 = "304 Not Modified",
    Http305 = "305 Use Proxy",
    Http307 = "307 Temporary Redirect",
    Http400 = "400 Bad Request",
    Http401 = "401 Unauthorized",
    Http403 = "403 Forbidden",
    Http404 = "404 Not Found",
    Http405 = "405 Method Not Allowed",
    Http406 = "406 Not Acceptable",
    Http407 = "407 Proxy Authentication Required",
    Http408 = "408 Request Timeout",
    Http409 = "409 Conflict",
    Http410 = "410 Gone",
    Http411 = "411 Length Required",
    Http412 = "412 Precondition Failed",
    Http413 = "413 Request Entity Too Large",
    Http414 = "414 Request-URI Too Long",
    Http415 = "415 Unsupported Media Type",
    Http416 = "416 Requested Range Not Satisfiable",
    Http417 = "417 Expectation Failed",
    Http418 = "418 I'm a teapot",
    Http421 = "421 Misdirected Request",
    Http422 = "422 Unprocessable Entity",
    Http426 = "426 Upgrade Required",
    Http428 = "428 Precondition Required",
    Http429 = "429 Too Many Requests",
    Http431 = "431 Request Header Fields Too Large",
    Http451 = "451 Unavailable For Legal Reasons",
    Http500 = "500 Internal Server Error",
    Http501 = "501 Not Implemented",
    Http502 = "502 Bad Gateway",
    Http503 = "503 Service Unavailable",
    Http504 = "504 Gateway Timeout",
    Http505 = "505 HTTP Version Not Supported"

  HttpVersion* = enum
    HttpVer11,
    HttpVer10,
    HttpVerError

  HttpMethod* = enum
    MethodGet,
    MethodPost,
    MethodHead,
    MethodPut,
    MethodDelete,
    MethodTrace,
    MethodOptions,
    MethodConnect,
    MethodPatch,
    MethodError

  reqStatus* = enum
    InProgress = 0,
    Ok,
    Disconnect,
    SizeError,
    ReqMethodError,
    VersionError,
    HeadersError

  partString = object
    index: int32
    length: int32

  ReqHelperImpl* = object
    buffer*: array[MaxHttpRequestSize, char]
    parts*: array[4, partString]
    size*: int
    offset*: int
    index*: int
    hcount*: int
    status*: reqStatus
  ReqHelper* = ptr ReqHelperImpl

let methSet = {'A', 'C', 'D', 'E', 'G', 'H', 'I', 'L', 'N', 'O',
               'P', 'R', 'S', 'T', 'U'}
let verSet = {'H', 'T', 'P', '/', '1', '.', '0', '\x0D'}

proc getHeaders*(helper: ReqHelper, tab: StringTableRef): bool =
  result = true
  if helper.hcount > 0:
    var offset = helper.parts[3].index.int
    var i = 0
    var b = helper.buffer
    while i < helper.hcount:
      let s = offset
      var e = offset
      var d = 0
      while b[e] != '\x0D':
        if d == 0 and b[e] == ':':
          d = e
        inc(e)
      if d == 0:
        result = false
        break
      var d1 = d - 1
      var d2 = d + 1
      while (d1 > s) and b[d1] == ' ': dec(d1)
      while (d2 < e) and b[d2] == ' ': inc(d2)
      let hnl = d1 - s + 1
      let hvl = e - d2
      if hnl == 0:
        result = false
        break
      var hn = newString(hnl)
      var hv = newString(hvl)
      copyMem(cast[pointer](addr hn[0]), addr(b[s]), hnl)
      copyMem(cast[pointer](addr hv[0]), addr(b[d2]), hvl)
      tab[hn] = hv
      offset = e + 2
      inc(i)

proc getUrl*(helper: ReqHelper): string =
  let length = helper.parts[1].length
  let i = helper.parts[1].index
  result = newString(length)
  copyMem(addr result[0], addr(helper.buffer[i]), length)

proc getVersion*(helper: ReqHelper): HttpVersion =
  result = HttpVerError
  let i = helper.parts[2].index
  let length = helper.parts[2].length
  let b = helper.buffer
  if length == 8:
    if b[i] == 'H' and b[i + 1] == 'T' and b[i + 2] == 'T' and
       b[i + 3] == 'P' and b[i + 4] == '/' and b[i + 5] == '1' and
       b[i + 6] == '.':
      if b[i + 7] == '0':
        result = HttpVer10
      elif b[i + 7] == '1':
        result = HttpVer11

proc getMethod*(helper: ReqHelper): HttpMethod =
  result = MethodError
  let i = helper.parts[0].index
  let length = helper.parts[0].length
  let b = helper.buffer
  case b[i]
  of 'G':
    if length == 3:
      if b[i + 1] == 'E' and b[i + 2] == 'T':
        result = MethodGet
  of 'P':
    if length == 3:
      if b[i + 1] == 'U' and b[i + 2] == 'T':
        result = MethodPut
      elif length == 4:
        if b[i + 1] == 'O' and b[i + 2] == 'S' and b[i + 3] == 'T':
          result = MethodPost
      elif length == 5:
        if b[i + 1] == 'A' and b[i + 2] == 'T' and b[i + 3] == 'C' and
           b[i + 4] == 'H':
          result = MethodPatch
  of 'D':
    if length == 6:
      if b[i + 1] == 'E' and b[i + 2] == 'L' and b[i + 3] == 'E' and
         b[i + 4] == 'T' and b[i + 5] == 'E':
        result = MethodDelete
  of 'T':
    if length == 5:
      if b[i + 1] == 'R' and b[i + 2] == 'A' and b[i + 3] == 'C' and
         b[i + 4] == 'E':
       result = MethodTrace
  of 'O':
    if length == 7:
      if b[i + 1] == 'P' and b[i + 2] == 'T' and b[i + 3] == 'I' and
         b[i + 4] == 'O' and b[i + 5] == 'N' and b[i + 6] == 'S':
        result = MethodOptions
  of 'C':
    if length == 7:
      if b[i + 1] == 'O' and b[i + 2] == 'N' and b[i + 3] == 'N' and
         b[i + 4] == 'E' and b[i + 5] == 'C' and b[i + 6] == 'T':
        result = MethodConnect
  else:
    discard

proc processRequest*(helper: ReqHelper, dataReceived: int): bool =
  # we must decrease helper.size and increase helper.index
  result = false
  helper.size = helper.size - dataReceived
  assert(helper.size >= 0)
  let availSize = MaxHttpRequestSize - helper.size

  while true:
    var offset = helper.offset
    var start = helper.parts[helper.index].index.int
    case helper.index
    of 0:
      # request method
      while offset < availSize and helper.buffer[offset] in methSet:
        inc(offset)
      helper.offset = offset
      if offset == availSize:
        result = false
        break
      else:
        if helper.buffer[offset] == ' ':
          helper.parts[0].length = (offset - start).int32
          inc(helper.index)
          inc(helper.offset)
          continue
        else:
          helper.status = reqStatus.ReqMethodError
          result = true
          break
    of 1:
      # uri
      if start == 0:
        helper.parts[1].index = helper.offset.int32
        start = helper.offset
      while offset < availSize and helper.buffer[offset] != ' ':
        inc(offset)
      helper.offset = offset
      if offset == availSize:
        result = false
        break
      else:
        if helper.buffer[offset] == ' ':
          helper.parts[1].length = (offset - start).int32
          inc(helper.index)
          inc(helper.offset)
          continue
    of 2:
      # version
      if start == 0:
        helper.parts[2].index = helper.offset.int32
        start = helper.offset
      while offset < availSize and helper.buffer[offset] in verSet:
        inc(offset)
      helper.offset = offset
      if offset == availSize:
        result = false
        break
      else:
        if helper.buffer[offset] == '\x0A':
          if helper.buffer[offset - 1] == '\x0D':
            helper.parts[2].length = (offset - 1 - start).int32
            inc(helper.index)
            inc(helper.offset)
            continue
          else:
            helper.status = reqStatus.VersionError
            result = true
            break
        else:
          helper.status = reqStatus.VersionError
          result = true
          break
    of 3:
      # headers
      if start == 0:
        helper.parts[3].index = helper.offset.int32
        start = helper.offset
      while offset < availSize and helper.buffer[offset] != '\x0A':
        inc(offset)
      helper.offset = offset
      if offset == availSize:
        result = false
        break
      else:
        if helper.buffer[offset] == '\x0A':
          if helper.buffer[offset - 1] == '\x0D':
            inc(helper.hcount)
            if  helper.buffer[offset - 2] == '\x0A' and
                helper.buffer[offset - 3] == '\x0D':
              dec(helper.hcount)
              inc(helper.index)
              inc(helper.offset)
              helper.parts[3].length = (offset + 1 - start).int32
              helper.status = reqStatus.Ok
              result = true
              break
            else:
              inc(helper.offset)
              continue
          else:
            helper.status = reqStatus.HeadersError
            result = true
            break
        else:
          result = false
          break
    else:
      break

  if not result and helper.offset == MaxHttpRequestSize:
    helper.status = reqStatus.SizeError
    result = true

proc newReqHelper*(): ReqHelper =
  result = cast[ReqHelper](allocShared0(sizeof(ReqHelperImpl)))
  result.size = MaxHttpRequestSize

proc free*(r: ReqHelper) =
  deallocShared(r)

proc clear*(r: ReqHelper) =
  r.offset = 0
  r.index = 0
  r.hcount = 0
  r.parts[0].index = 0
  r.parts[1].index = 0
  r.parts[2].index = 0
  r.parts[3].index = 0
  r.status = InProgress
  r.size = MaxHttpRequestSize

template getPointer*(r: ReqHelper): pointer =
  (addr(r.buffer[r.offset]))

when defined(windows):
  import winlean

  template callRecv() =
    while true:
      let ret = WSARecv(client.SocketHandle, addr dataBuf, 1,
                        addr bytesReceived, addr flagsio,
                        cast[POVERLAPPED](ol), nil)
      if ret == -1:
        let err = osLastError()
        if err.int32 != ERROR_IO_PENDING:
          if dataBuf.buf != nil:
            dataBuf.buf = nil
          GC_unref(ol)
          if flags.isDisconnectionError(err):
            helper.status = reqStatus.Disconnect
            retFuture.complete()
          else:
            retFuture.fail(newException(OSError, osErrorMsg(err)))
        else:
          break
      elif ret == 0:
      # Request completed immediately.
        if bytesReceived != 0:
          assert bytesReceived <= helper.size
          if processRequest(helper, bytesReceived):
            retFuture.complete()
        else:
          if hasOverlappedIoCompleted(cast[POVERLAPPED](ol)):
            helper.status = reqStatus.Disconnect
            retFuture.complete()

  proc recvRequestInto*(client: AsyncFD, helper: ReqHelper,
                    flags = {SocketFlag.SafeDisconn}): Future[void] =
    var retFuture = newFuture[void]("processor.recvRequest")
    var dataBuf = TWSABuf(buf: addr(helper.buffer[0]), len: helper.size.ULONG)
    var bytesReceived = 0.Dword
    var flagsio = flags.toOSFlags().Dword

    var ol = PCustomOverlapped()
    GC_ref(ol)
    ol.data = CompletionData(fd: client, cb:
      proc (fd: AsyncFD, bytesCount: Dword, errcode: OSErrorCode) =
        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            # no error
            if bytesCount == 0:
              helper.status = reqStatus.Disconnect
              retFuture.complete()
            else:
              if processRequest(helper, bytesCount):
                retFuture.complete()
              else:
                GC_ref(ol)
                dataBuf = TWSABuf(buf: cast[cstring](helper.getPointer()),
                                  len: helper.size.ULONG)
                callRecv()
          else:
            # error
            if flags.isDisconnectionError(errcode):
              helper.status = reqStatus.Disconnect
              retFuture.complete()
            else:
              retFuture.fail(newException(OSError, osErrorMsg(errcode)))
    )
    callRecv()
    return retFuture
else:
  import posix, nativesockets

  proc recvRequestInto*(client: AsyncFD, helper: ReqHelper,
                    flags = {SocketFlag.SafeDisconn}): Future[void] =
    var retFuture = newFuture[void]("processor.recvRequest")

    proc cb(sock: AsyncFD): bool =
      result = true
      let res = recv(sock.SocketHandle, helper.getPointer(), helper.size.cint,
                     flags.toOSFlags())
      if res < 0:
        let lastError = osLastError()
        if lastError.int32 notin {EINTR, EWOULDBLOCK, EAGAIN}:
          if flags.isDisconnectionError(lastError):
            helper.status = reqStatus.Disconnect
            retFuture.complete()
          else:
            retFuture.fail(newException(OSError, osErrorMsg(lastError)))
        else:
          result = false # We still want this callback to be called.
      elif res == 0:
        helper.status = reqStatus.Disconnect
        retFuture.complete()
      else:
        if processRequest(helper, res):
          retFuture.complete()
        else:
          result = false # Header is not ready yet.
    addRead(client, cb)
    return retFuture

when isMainModule:
  proc pushData(helper: ReqHelper, data: string): bool =
    var i = 0
    while i < len(data):
      helper.buffer[helper.offset + i] = data[i]
      inc(i)
    echo("processing")
    result = processRequest(helper, len(data))

  block:
    var helper = newReqHelper()
    echo helper.pushData("GET / HTTP/1.1\c\lAccept:*/*\c\lAccept-Encoding:gzip, deflate, br\c\lAccept-Language:en-US,en;q=0.8\c\lConnection:keep-alive\c\lContent-Length:664\c\lContent-Type:application/x-www-form-urlencoded\c\lCookie:yandexuid=427344771463954545; yabs-sid=2570830921463954545; _ym_uid=1464053886625025511; fuid01=575ef1920a9dd817.OigCwP4y_hbpbciPihonY-dodTSnfGEVwsY1VxHhwuaY0ahifGBzVb0fWCRykNiNI-xTaHADRZF1zubrHE5izcdck5MALn4Clqv_Ys176UPNzp_hAcxo-weYwEwnYVlq\c\lHost:mc.yandex.ru\c\lOrigin:http://baibako.tv\c\lReferer:http://baibako.tv/\c\lUser-Agent:Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/51.0.2704.103 Safari/537.36 Vivaldi/1.2.490.43\c\l\c\l")
    echo(repr(helper.parts))
    echo(helper.status)
    echo(getMethod(helper))
    echo(getVersion(helper))
    echo(getUrl(helper))
    var t = newStringTable(modeCaseInsensitive)
    echo("result = " & $getHeaders(helper, t))
    #echo(repr(t))

  block:
    var helper = newReqHelper()
    echo helper.pushData("GET / HTTP/1.1\c\l\c\l")
    echo(repr(helper.parts))
    echo(helper.status)
    echo(helper.hcount)
