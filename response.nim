#
#
#      Wanted asynchronous threaded webserver
#        (c) Copyright 2016 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

import asyncdispatch, strtabs, httputils
import request

type
  Response* = ref object of RootRef
    req*: Request
    headers*: StringTableRef
    status: HttpCode

proc newResponse*(req: Request, status: HttpCode): Response =
  result = Response(req: req)
  result.headers = newStringTable(modeCaseInsensitive)

proc prepare*(resp: Response): Future[void] {.async.} =
  discard

proc write*(resp: Response, data: pointer, size: int): Future[void] {.async.} =
  discard

proc setCookie*(resp: Response, name, value: string,
                expires = 0, domain = "", max_age = 0, path = "",
                secure = 0, httponly = 0, version = 1) =
  discard

proc delCookie*(resp: Response, name: string) =
  discard

proc writeEof*(resp: Response): Future[void] {.async, inline.} =
  result = resp.write(nil, 0)
