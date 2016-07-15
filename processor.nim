#
#
#      Wanted asynchronous threaded webserver
#        (c) Copyright 2016 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

import asyncdispatch, httputils, strutils, strtabs, uri
import sharray, reqresp, constants

proc processClient*(fd: AsyncFd, handler: wrappedHandler,
                    middlewares: SharedArray[Middleware]):
                    Future[void] {.async.} =
  var err = false
  var request = newRequest(fd)
  var response = newResponse(request)
  while true:
    # receiving data from client and sanitizing it
    var helpfut = recvRequestInto(request.sock, request.helper)
    yield helpfut
    if helpfut.failed:
      await response.writeError(Http500, $Http500)
      break

    # processing helper results
    let helper = request.helper
    if helper.status != reqStatus.Ok:
      case helper.status
      of SizeError:
        await response.writeError(Http413, $Http413)
      of ReqMethodError, VersionError, HeadersError:
        await response.writeError(Http400, $Http400)
      of Disconnect:
        discard
      else:
        await response.writeError(Http400, $Http400)
      break

    # processing request method
    request.rmethod = helper.getMethod()
    if request.rmethod == MethodError:
      await response.writeError(Http400, $Http400)
      break
    # processing request version
    request.version = helper.getVersion()
    if request.version == HttpVerError:
      await response.writeError(Http400, $Http400)
      break
    # set response version equal to request version
    response.version = request.version
    # processing request uri
    request.url = initUri()
    let uri = helper.getUrl()
    try:
      parseUri(uri, request.url)
    except:
      err = true
    if err:
      await response.writeError(Http400, $Http400)
      break
    # processing headers
    if not helper.getHeaders(request.headers):
      await response.writeError(Http400, $Http400)
      break

    # processing request
    err = false
    var curHandler = handler
    if middlewares != nil:
      # middlewares present
      var i = 0
      while not err:
        let factoryCb = middlewares[i].factory
        if factoryCb == nil: break
        var handlerFut = factoryCb(curHandler)
        yield handlerFut
        if handlerFut.failed:
          await response.writeError(Http500, $Http500)
          err = true
          break
        else:
          curHandler = handlerFut.read()
        inc(i)
      if err: break

    var respFut = curHandler(request)
    yield respFut
    if respFut.finished:
      if respFut.failed:
        await response.writeError(Http500, $Http500)
        break
      else:
        response = respFut.read()

    # if response is not finished send error
    if not response.finished():
      await response.writeError(Http500, $Http500)
      break

    # processing connection behavior
    if (request.version == HttpVer11 and
       request.headers.getOrDefault("connection").normalize != "close") or
       (request.version == HttpVer10 and
       request.headers.getOrDefault("connection").normalize == "keep-alive"):
      discard
    else:
      break
    clear(request)
  close(request)
