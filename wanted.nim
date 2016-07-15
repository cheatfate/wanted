#
#
#      Wanted asynchronous threaded webserver
#        (c) Copyright 2016 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

import os, cpucores, asyncdispatch, nativesockets, strutils, net, times
import sharray, asyncpipes, asyncutils, httputils, strtabs
import reqresp, processor

when not compileOption("threads"):
  {.error: "Threads support must be turned on".}

type
  requestHandler* = proc (req: Request): Future[Response]

  workerSetupImpl = object
    pipeFd: AsyncPipe
    ncpu: int
    middlewares: SharedArray[Middleware]
    handler: wrappedHandler
  workerSetup = ptr workerSetupImpl

  acceptSetupImpl = object
    serverFd: AsyncFD
    stopPipe: AsyncPipe
    pipesCount: int
    pipes: SharedArray[tuple[pipe: AsyncPipe, count: int]]
  acceptSetup = ptr acceptSetupImpl

  wantedServer* = ref object of RootRef
    serverFd: AsyncFD
    stopPipe: AsyncPipe
    workers: seq[Thread[pointer]]
    middlewares: SharedArray[Middleware]
    pipes: seq[AsyncPipe]
    handler: wrappedHandler

proc threadAccept(setup: pointer) {.thread.} =
  let setup = cast[acceptSetup](setup)
  let serverFd = setup.serverFd
  let stopFd = setup.stopPipe
  var count = 0
  var index = 0
  var exitFlag = false
  var data = 0
  var cexit = AsyncFD(-1)

  # we need to register handles with our new dispatcher
  register(serverFd)
  register(AsyncFD(stopFd))
  var i = 0
  while i < setup.pipesCount:
    register(setup.pipes[i].pipe.AsyncFD)
    inc(i)

  # main accept loop
  while not exitFlag:
    var stopFut = stopFd.readInto(addr data, sizeof(int))
    var acptFut = serverFd.acceptAddress(regAsync = false)
    while true:
      if stopFut.finished:
        # server.stop() is called
        if not stopFut.failed:
          # graceful shutdown
          var a = stopFut.read
          if a == sizeof(int) and data == 1:
            i = 0
            while i < setup.pipesCount:
              let pipe = setup.pipes[i].pipe
              waitFor pipe.write(cast[pointer](addr cexit), sizeof(AsyncFD))
              unregister(pipe)
              close(pipe)
              inc(i)
            exitFlag = true
            break
      if acptFut.finished:
        # new client accepted
        if not acptFut.failed:
          var a = acptFut.read
          var csocket = a.client
          let item = setup.pipes[index]
          index = ((index + 1) %% setup.pipesCount)
          inc(count)
          let pipe = item.pipe.AsyncFD
          asyncCheck pipe.write(cast[pointer](addr csocket), sizeof(AsyncFD))
          break
      poll()

  unregister(serverFd)
  unregister(stopFd)
  close(stopFd)
  deallocSharedArray(setup.pipes)
  deallocShared(setup)

proc threadWorker(setup: pointer) {.thread.} =
  let setup = cast[workerSetup](setup)
  let pipeFd = setup.pipeFd
  var sock: SocketHandle = 0.SocketHandle
  let psock = cast[pointer](addr sock)
  var exitFlag = false
  # we need to register handles with our new dispatcher
  register(pipeFd)

  # main worker loop
  while not exitFlag:
    var pipeFut = pipeFd.readInto(psock, sizeof(SocketHandle))
    while true:
      if pipeFut.finished:
        if not pipeFut.failed:
          var size = pipeFut.read()
          if size == sizeof(SocketHandle):
            if sock == SocketHandle(-1):
              # graceful shutdown
              # currently processing sockets must be closed too... (todo)
              unregister(pipeFd)
              close(pipeFd)
              deallocShared(setup)
              exitFlag = true
              break
            # we got normal socket, so we can register with our dispatcher
            register(sock.AsyncFD)
            # and now we start processing client
            asyncCheck processClient(sock.AsyncFD, setup.handler,
                                     setup.middlewares)
            break
          else:
            exitFlag = true
            break
        else:
          exitFlag = true
          break
      poll()

proc wrapHandle*(procb: requestHandler): auto =
  proc handler(req: Request): Future[Response] {.async.} =
    try:
      result = await procb(req)
    except:
      discard
  result = handler

proc newWantedServer*(address: string, port: Port, handler: requestHandler,
                      middlewares: varargs[Middleware]): wantedServer =
  let fd = newNativeSocket()
  setBlocking(fd, false)
  setSockOptInt(fd, SOL_SOCKET, SO_REUSEADDR, 1)
  var saddress = ""
  if len(address) == 0:
    saddress = "0.0.0.0"
  else:
    saddress.shallowCopy(address)
  var aiList = getAddrInfo(saddress, port)
  if bindAddr(fd, aiList.ai_addr, aiList.ai_addrlen.Socklen) < 0'i32:
    dealloc(aiList)
    raiseOSError(osLastError())
  dealloc(aiList)
  if listen(fd) != 0:
    raiseOSError(osLastError())
  result = wantedServer()
  result.serverFd = fd.AsyncFD
  if len(middlewares) > 0:
    result.middlewares = allocSharedArray[Middleware](len(middlewares) + 1)
    var i = 0
    for mw in items(middlewares):
      doAssert(mw.factory != nil)
      result.middlewares[i] = mw
      inc(i)
  result.workers = newSeq[Thread[pointer]]()
  result.pipes = newSeq[AsyncPipe]()
  result.handler = wrapHandle(handler)

proc start*(ws: wantedServer) =
  var cores = getCoresNumber()
  if cores == 1:
    # special case when only 1 cpu core is available
    var aset = cast[acceptSetup](allocShared0(sizeof(acceptSetupImpl)))
    var wset = cast[workerSetup](allocShared0(sizeof(workerSetupImpl)))
    var stopipes = asyncPipes(regAsync = false)
    var pipes = asyncPipes(regAsync = false)
    # fill acceptSetup
    aset.pipes = allocSharedArray[tuple[pipe: AsyncPipe, count: int]](1)
    aset.serverFd = ws.serverFd
    aset.pipes[0] = (pipe: pipes.writePipe, count: 0)
    aset.stopPipe = stopipes.readPipe
    # fill workerSetup
    wset.pipeFd = pipes.readPipe
    wset.middlewares = ws.middlewares
    wset.handler = ws.handler
    # update server setup
    ws.workers.setLen(2)
    ws.stopPipe = stopipes.writePipe
    ws.pipes.add(pipes.writePipe)
    createThread(ws.workers[1], threadWorker, cast[pointer](wset))
    createThread(ws.workers[0], threadAccept, cast[pointer](aset))
  else:
    # main case, where > 1 cpu cores available
    let threadsCount = (cores - 1) * 2 + 1
    ws.workers.setLen(threadsCount)
    var aset = cast[acceptSetup](allocShared0(sizeof(acceptSetupImpl)))
    var stopipes = asyncPipes(regAsync = false)
    aset.pipes = allocSharedArray[tuple[pipe: AsyncPipe,
                                        count: int]](threadsCount - 1)
    aset.pipesCount = threadsCount - 1
    aset.serverFd = ws.serverFd
    aset.stopPipe = stopipes.readPipe
    ws.stopPipe = stopipes.writePipe
    var i = 1
    while i < len(ws.workers):
      let ncpu = ((i - 1) div 2) + 1
      var pipes = asyncPipes(regAsync = false)
      var wset = cast[workerSetup](allocShared0(sizeof(workerSetupImpl)))
      # set workerThread parameters
      wset.pipeFd = pipes.readPipe
      wset.ncpu = ncpu
      wset.middlewares = ws.middlewares
      wset.handler = ws.handler
      # set acceptThread parameters
      aset.pipes[i - 1] = (pipe: pipes.writePipe, count: 0)
      ws.pipes.add(pipes.writePipe)
      # starting and pinning thread
      createThread(ws.workers[i], threadWorker, cast[pointer](wset))
      pinToCpu(ws.workers[i], ncpu)
      echo "Started threadWorker with pinned to CPU" & $ncpu
      inc(i)
    # create accept thread
    createThread(ws.workers[0], threadAccept, cast[pointer](aset))
    pinToCpu(ws.workers[0], 0)

proc join*(ws: wantedServer) =
  joinThread(ws.workers[0])

proc stop*(ws: wantedServer): Future[void] {.async.} =
  var data = 1
  await ws.stopPipe.write(addr data, sizeof(int))
  joinThread(ws.workers[0])

proc running*(ws: var wantedServer): bool {.inline.} =
  result = ws.workers[0].running()

when not defined(testing) and isMainModule:
  import middlewares/session
  proc sendTest(req: Request): Future[Response] {.async.} =
    result = newResponse(req, Http200)
    result.headers["Date"] = "Tue, 29 Apr 2014 23:40:08 GMT"
    result.headers["Content-Type"] = "text/plain; charset=utf-8"
    await result.writeText("Hello World!")

  var server = newWantedServer("", Port(5555), sendTest, sessionMiddleware())
  server.start()
  server.join()

