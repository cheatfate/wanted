#
#
#      Wanted asynchronous threaded webserver
#        (c) Copyright 2016 Eugene Kabanov
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import os, cpucores, asyncdispatch, nativesockets, strutils
import asyncpipes, asyncutils
import processor

when not compileOption("threads"):
  {.error: "Threads support must be turned on".}

type
  acceptSetupImpl = object
    serverFd: AsyncFD
    pipes: seq[tuple[pipe: AsyncPipe, count: int]]
  acceptSetup = ptr acceptSetupImpl

  workerSetupImpl = object
    pipeFd: AsyncPipe
  workerSetup = ptr workerSetupImpl

proc threadAccept(setup: pointer) {.thread.} =
  let setup = cast[acceptSetup](setup)
  let serverFd = setup.serverFd
  var count = 0
  var index = 0
  # we need to register handles with our new dispatcher
  register(serverFd)
  for item in setup.pipes:
    register(item.pipe.AsyncFD)

  while true:
    var fut = serverFd.acceptAddress(regAsync = false)
    while true:
      if fut.finished:
        if not fut.failed:
          var a = fut.read
          var csocket = a.client
          let item = setup.pipes[index]
          index = ((index + 1) %% len(setup.pipes))
          inc(count)
          let pipe = item.pipe.AsyncFD
          asyncCheck pipe.write(cast[pointer](addr csocket), sizeof(AsyncFD))
          break
      poll()

proc threadWorker(setup: pointer) {.thread.} =
  let setup = cast[workerSetup](setup)
  let pipeFd = setup.pipeFd
  var sock: SocketHandle
  let psock = cast[pointer](addr sock)
  var exitFlag = false

  register(pipeFd)
  while true:
    var pfut = pipeFd.readInto(psock, sizeof(SocketHandle))
    while true:
      if pfut.finished:
        if not pfut.failed:
          var size = pfut.read()
          if size == sizeof(SocketHandle):
            # we got normal socket, so we can register with our dispatcher
            register(sock.AsyncFD)
            # and now we start processing client
            asyncCheck processClient(sock.AsyncFD)
            break
          else:
            exitFlag = true
            break
        else:
          exitFlag = true
          break
      poll()
    if exitFlag:
      break

proc setupServer(address: string, port: Port): AsyncFD =
  let fd = newNativeSocket()
  setSockOptInt(fd, SOL_SOCKET, SO_REUSEADDR, 1)
  var aiList = getAddrInfo(address, port)
  if bindAddr(fd, aiList.ai_addr, aiList.ai_addrlen.Socklen) < 0'i32:
    dealloc(aiList)
    raiseOSError(osLastError())
  dealloc(aiList)
  if listen(fd) != 0:
    raiseOSError(osLastError())
  setBlocking(fd, false)
  result = fd.AsyncFD

var workers: seq[Thread[pointer]]
var serverFd = setupServer("0.0.0.0", Port(5555))
var cores = getCoresNumber()
if cores == 1:
  workers = newSeq[Thread[pointer]](2)
  var aset = cast[acceptSetup](allocShared0(sizeof(acceptSetupImpl)))
  var wset = cast[workerSetup](allocShared0(sizeof(workerSetupImpl)))
  aset.pipes = newSeq[tuple[pipe: AsyncPipe, count: int]]()
  aset.serverFd = serverFd
  var pipes = asyncPipes(regAsync = false)
  aset.pipes.add((pipe: pipes.writePipe, count: 0))
  wset.pipeFd = pipes.readPipe
  createThread(workers[1], threadWorker, cast[pointer](wset))
  createThread(workers[0], threadAccept, cast[pointer](aset))
else:
  workers = newSeq[Thread[pointer]]((cores - 1) * 2 + 1)
  var aset = cast[acceptSetup](allocShared0(sizeof(acceptSetupImpl)))
  aset.pipes = newSeq[tuple[pipe: AsyncPipe, count: int]]()
  aset.serverFd = serverFd
  var i = 1
  while i < len(workers):
    var pipes = asyncPipes(regAsync = false)
    var wset = cast[workerSetup](allocShared0(sizeof(workerSetupImpl)))
    wset.pipeFd = pipes.readPipe
    aset.pipes.add((pipe: pipes.writePipe, count: 0))
    createThread(workers[i], threadWorker, cast[pointer](wset))
    let ncpu = ((i - 1) div 2) + 1
    pinToCpu(workers[i], ncpu)
    echo "Started threadWorker with pinned to CPU" & $ncpu
    inc(i)
  createThread(workers[0], threadAccept, cast[pointer](aset))
  pinToCpu(workers[0], 0)
  echo "Started threadAccept with pinned to CPU0"

joinThreads(workers)
