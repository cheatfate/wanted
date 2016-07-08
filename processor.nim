#
#
#      Wanted asynchronous threaded webserver
#        (c) Copyright 2016 Eugene Kabanov
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import asyncdispatch, asyncnet, httpcore, parseutils, uri, strutils

type
  Request* = object
    client*: AsyncSocket # TODO: Separate this into a Response object?
    reqMethod*: string
    headers*: HttpHeaders
    protocol*: tuple[orig: string, major, minor: int]
    url*: Uri
    hostname*: string ## The hostname of the client that made the request.
    body*: string

proc addHeaders(msg: var string, headers: HttpHeaders) =
  for k, v in headers:
    msg.add(k & ": " & v & "\c\L")

proc sendHeaders*(req: Request, headers: HttpHeaders): Future[void] =
  ## Sends the specified headers to the requesting client.
  var msg = ""
  addHeaders(msg, headers)
  return req.client.send(msg)

proc respond*(req: Request, code: HttpCode, content: string,
              headers: HttpHeaders = nil): Future[void] =
  ## Responds to the request with the specified ``HttpCode``, headers and
  ## content.
  ##
  ## This procedure will **not** close the client socket.
  var msg = "HTTP/1.1 " & $code & "\c\L"

  if headers != nil:
    msg.addHeaders(headers)
  msg.add("Content-Length: " & $content.len & "\c\L\c\L")
  msg.add(content)
  result = req.client.send(msg)

proc parseProtocol(protocol: string): tuple[orig: string, major, minor: int] =
  var i = protocol.skipIgnoreCase("HTTP/")
  if i != 5:
    raise newException(ValueError, "Invalid request protocol. Got: " &
        protocol)
  result.orig = protocol
  i.inc protocol.parseInt(result.major, i)
  i.inc # Skip .
  i.inc protocol.parseInt(result.minor, i)

proc sendStatus(client: AsyncSocket, status: string): Future[void] =
  client.send("HTTP/1.1 " & status & "\c\L")

proc sendTest(req: Request) {.async.} =
  let headers = {"Date": "Tue, 29 Apr 2014 23:40:08 GMT",
                 "Content-type": "text/plain; charset=utf-8"}
  await req.respond(Http200, "Hello World", headers.newHttpHeaders())

proc processClient*(fd: AsyncFd): Future[void] {.async.} =
  let client = newAsyncSocket(fd)
  var request: Request

  request.url = initUri()
  request.headers = newHttpHeaders()
  var lineFut = newFutureVar[string]("asynchttpserver.processClient")
  lineFut.mget() = newStringOfCap(80)
  var key, value = ""

  while not client.isClosed:
    # GET /path HTTP/1.1
    # Header: val
    # \n
    request.headers.clear()
    request.body = ""
    #request.hostname.shallowCopy(address)
    assert client != nil
    request.client = client

    # First line - GET /path HTTP/1.1
    lineFut.mget().setLen(0)
    lineFut.clean()
    await client.recvLineInto(lineFut) # TODO: Timeouts.
    if lineFut.mget == "":
      client.close()
      return

    var i = 0
    for linePart in lineFut.mget.split(' '):
      case i
      of 0: request.reqMethod.shallowCopy(linePart.normalize)
      of 1: parseUri(linePart, request.url)
      of 2:
        try:
          request.protocol = parseProtocol(linePart)
        except ValueError:
          asyncCheck request.respond(Http400,
            "Invalid request protocol. Got: " & linePart)
          continue
      else:
        await request.respond(Http400, "Invalid request. Got: " & lineFut.mget)
        continue
      inc i

    # Headers
    while true:
      i = 0
      lineFut.mget.setLen(0)
      lineFut.clean()
      await client.recvLineInto(lineFut)

      if lineFut.mget == "":
        client.close(); return
      if lineFut.mget == "\c\L": break
      let (key, value) = parseHeader(lineFut.mget)
      request.headers[key] = value
      # Ensure the client isn't trying to DoS us.
      if request.headers.len > headerLimit:
        await client.sendStatus("400 Bad Request")
        request.client.close()
        return

    if request.reqMethod == "post":
      # Check for Expect header
      if request.headers.hasKey("Expect"):
        if "100-continue" in request.headers["Expect"]:
          await client.sendStatus("100 Continue")
        else:
          await client.sendStatus("417 Expectation Failed")

    # Read the body
    # - Check for Content-length header
    if request.headers.hasKey("Content-Length"):
      var contentLength = 0
      if parseInt(request.headers["Content-Length"],
                  contentLength) == 0:
        await request.respond(Http400, "Bad Request. Invalid Content-Length.")
        continue
      else:
        request.body = await client.recv(contentLength)
        assert request.body.len == contentLength
    elif request.reqMethod == "post":
      await request.respond(Http400, "Bad Request. No Content-Length.")
      continue

    case request.reqMethod
    of "get", "post", "head", "put", "delete", "trace", "options",
       "connect", "patch":
      await sendTest(request)
    else:
      await request.respond(Http400, "Invalid request method. Got: " &
        request.reqMethod)

    if "upgrade" in request.headers.getOrDefault("connection"):
      return

    # Persistent connections
    if (request.protocol == HttpVer11 and
        request.headers.getOrDefault("connection").normalize != "close") or
       (request.protocol == HttpVer10 and
        request.headers.getOrDefault("connection").normalize == "keep-alive"):
      # In HTTP 1.1 we assume that connection is persistent. Unless connection
      # header states otherwise.
      # In HTTP 1.0 we assume that the connection should not be persistent.
      # Unless the connection header states otherwise.
      discard
    else:
      request.client.close()
      break