#
#
#      Wanted asynchronous threaded webserver
#        (c) Copyright 2016 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

import asyncdispatch, httputils, strtabs, uri

type
  Request* = object
    sock*: AsyncFd
    rmethod*: HttpMethod
    version*: HttpVersion
    url*: Uri
    headers*: StringTableRef
    helper*: ReqHelper

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
