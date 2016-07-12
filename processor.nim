#
#
#      Wanted asynchronous threaded webserver
#        (c) Copyright 2016 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

import asyncdispatch, httputils, strutils, strtabs, uri

type
  Request* = object
    sock*: AsyncFd
    rmethod*: HttpMethod
    version*: HttpVersion
    url*: Uri
    headers*: StringTableRef
    helper: ReqHelper

proc respond*(fd: AsyncFd, version: HttpVersion, code: HttpCode,
              content: string, headers: StringTableRef = nil): Future[void] =
  var msg = "HTTP/1."
  case version
  of HttpVer11:
    msg = msg & "1 " & $code & "\c\L"
  else:
    msg = msg & "0 " & $code & "\c\L"
  if headers != nil:
    for k, v in headers:
      msg.add(k & ": " & v & "\c\L")
  msg.add("Content-Length: " & $content.len & "\c\L\c\L")
  msg.add(content)
  result = send(fd, msg)

proc newHttpHeaders*(kvp: openarray[tuple[key: string,
                                          val: string]]): StringTableRef =
  result = newStringTable(modeCaseInsensitive)
  for pair in kvp:
    result[pair.key] = pair.val

proc respond*(req: Request, code: HttpCode, content: string,
              headers: StringTableRef = nil): Future[void] =
  result = req.sock.respond(req.version, code, content, headers)

proc sendTest(req: Request) {.async.} =
  let headers = {"Date": "Tue, 29 Apr 2014 23:40:08 GMT",
                 "Content-type": "text/plain; charset=utf-8"}
  await req.respond(Http200, "Hello World", headers.newHttpHeaders())

proc newRequest(fd: AsyncFd): Request =
  result = Request()
  result.sock = fd
  result.helper = newReqHelper()
  result.headers = newStringTable(modeCaseInsensitive)

proc clear(r: var Request) =
  clear(r.helper)
  r.headers.clear(modeCaseInsensitive)

proc close(r: var Request) =
  closeSocket(r.sock)
  free(r.helper)
  r.sock = 0.AsyncFd

proc processClient*(fd: AsyncFd): Future[void] {.async.} =
  var err = false
  var request = newRequest(fd)
  while true:
    request.sock = fd
    var helpfut = recvRequestInto(request.sock, request.helper)
    yield helpfut
    if helpfut.failed:
      break

    let helper = request.helper

    if helper.status != reqStatus.Ok:
      case helper.status
      of SizeError:
        await respond(fd, HttpVer10, Http413, $Http413)
      of ReqMethodError, VersionError, HeadersError:
        await respond(fd, HttpVer10, Http400, $Http400)
      of Disconnect:
        discard
      else:
        await respond(fd, HttpVer10, Http400, $Http400)
      break

    # processing request method
    request.rmethod = helper.getMethod()
    if request.rmethod == MethodError:
      await respond(fd, HttpVer10, Http400, $Http400)
      break
    # processing request version
    request.version = helper.getVersion()
    if request.version == HttpVerError:
      await respond(fd, HttpVer10, Http400, $Http400)
      break
    # processing request uri
    request.url = initUri()
    let uri = helper.getUrl()
    try:
      parseUri(uri, request.url)
    except:
      err = true
    if err:
      await respond(fd, request.version, Http400, $Http400)
      break
    # processing headers
    if not helper.getHeaders(request.headers):
      await respond(fd, request.version, Http400, $Http400)
      break

    #
    # processing request here
    #

    await request.sendTest()

    if (request.version == HttpVer11 and
       request.headers.getOrDefault("connection").normalize != "close") or
       (request.version == HttpVer10 and
       request.headers.getOrDefault("connection").normalize == "keep-alive"):
      discard
    else:
      break
    clear(request)
  close(request)
