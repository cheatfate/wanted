#
#
#      Wanted asynchronous threaded webserver
#        (c) Copyright 2016 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

import asyncdispatch, strtabs, httputils, uri
import constants

type
  RequestData* = ref object of RootObj
    id*: string
    next*: RequestData

  Request* = ref object of RootRef
    sock*: AsyncFd
    rmethod*: HttpMethod
    version*: HttpVersion
    url*: Uri
    headers*: StringTableRef
    helper*: ReqHelper
    data*: RequestData

  Response* = ref object of RootRef
    req*: Request
    headers*: StringTableRef
    status*: HttpCode
    version*: HttpVersion
    sent: bool

  wrappedHandler* = proc (req: Request): Future[Response] {.closure, gcsafe.}

  Middleware* = object
    id*: string
    factory*: proc (handler: wrappedHandler): Future[wrappedHandler] {.
                                                      closure,gcsafe.}

proc newRequest*(fd: AsyncFd): Request =
  result = Request()
  result.sock = fd
  result.helper = newReqHelper()
  result.headers = newStringTable(modeCaseInsensitive)
  result.url = initUri()

proc clear*(r: var Request) =
  clear(r.helper)
  r.headers.clear(modeCaseInsensitive)

proc close*(r: var Request) =
  closeSocket(r.sock)
  free(r.helper)
  r.sock = 0.AsyncFd

proc attach*(req: var Request, m: RequestData) =
  m.next = req.data
  req.data = m

proc extract*[T](req: var Request, id: string): T =
  result = nil
  var s = req.data
  while s.next != nil:
    if s.id == id:
      result = cast[T](s)
      break
    s = s.next

proc detach*(req: var Request, id: string) =
  var s = req.data
  if s != nil:
    if s.id == id:
      req.data = s.next
    else:
      var c = s
      while s.next != nil:
        if s.id != id:
          c.next = s
          c = c.next
          c.next = nil
        s = s.next

proc newResponse*(req: Request, code = Http500): Response =
  result = Response(req: req)
  result.headers = newStringTable(modeCaseInsensitive)
  result.headers["Server"] = ServerIdent
  result.version = HttpVer10
  result.status = code

proc prepare*(resp: Response): Future[void] {.async.} =
  discard

proc write*(resp: Response, data: pointer, size: int): Future[void] {.async.} =
  discard

proc writeText*(resp: Response, content: string): Future[void] {.async.} =
  var message = "HTTP/1."
  case resp.version
  of HttpVer11:
    message = message & "1 " & $resp.status & "\c\L"
  else:
    message = message & "0 " & $resp.status & "\c\L"
  for k, v in resp.headers:
    message.add(k & ": " & v & "\c\L")
  message.add("Content-Length: " & $len(content) & "\c\L\c\L")
  message.add(content)
  await send(resp.req.sock, message)
  resp.sent = true

proc writeError*(resp: Response, code: HttpCode,
                 content: string): Future[void] {.async.} =
  var message = "HTTP/1."
  case resp.version
  of HttpVer11:
    message = message & "1 " & $code & "\c\L"
  else:
    message = message & "0 " & $code & "\c\L"
  for k, v in resp.headers:
    message.add(k & ": " & v & "\c\L")
  message.add("Content-Length: " & $content.len & "\c\L\c\L")
  message.add(content)
  await send(resp.req.sock, message)
  resp.sent = true

proc setCookie*(resp: Response, name, value: string,
                expires = 0, domain = "", max_age = 0, path = "",
                secure = 0, httponly = 0, version = 1) =
  discard

proc delCookie*(resp: Response, name: string) =
  discard

proc writeEof*(resp: Response): Future[void] {.async.} =
  result = resp.write(nil, 0)

proc finished*(resp: Response): bool {.inline.} =
  result = resp.sent
