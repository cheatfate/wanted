#
#
#      Wanted asynchronous threaded webserver
# (c) Copyright 2016 Dominik Picheta, Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

import asyncdispatch, nativesockets, net, os

when defined(windows):
  import winlean

  var acceptEx*: WSAPROC_ACCEPTEX
  var getAcceptExSockAddrs*: WSAPROC_GETACCEPTEXSOCKADDRS

  proc initPointer(s: SocketHandle, fun: var pointer, guid: var GUID): bool =
    var bytesRet = 0.Dword
    fun = nil
    result = WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER, addr guid,
                      sizeof(GUID).Dword, addr fun, sizeof(pointer).Dword,
                      addr bytesRet, nil, nil) == 0

  proc initAll() =
    let dummySock = newNativeSocket()
    if dummySock == INVALID_SOCKET:
      raiseOSError(osLastError())
    var fun: pointer = nil
    if not initPointer(dummySock, fun, WSAID_ACCEPTEX):
      raiseOSError(osLastError())
    acceptEx = cast[WSAPROC_ACCEPTEX](fun)
    if not initPointer(dummySock, fun, WSAID_GETACCEPTEXSOCKADDRS):
      raiseOSError(osLastError())
    getAcceptExSockAddrs = cast[WSAPROC_GETACCEPTEXSOCKADDRS](fun)
    close(dummySock)

  proc acceptAddress*(socket: AsyncFD, flags = {SocketFlag.SafeDisconn},
                      regAsync = true):
                      Future[tuple[address: string, client: AsyncFD]] =
    var retFuture = newFuture[tuple[address: string,
                                    client: AsyncFD]]("acceptAddress")
    var clientSock = newNativeSocket()
    if clientSock == osInvalidSocket: raiseOSError(osLastError())

    const lpOutputLen = 1024
    var lpOutputBuf = newString(lpOutputLen)
    var dwBytesReceived = 0.Dword
    let dwReceiveDataLength = 0.Dword # We don't want any data to be read.
    let dwLocalAddressLength = Dword(sizeof (Sockaddr_in) + 16)
    let dwRemoteAddressLength = Dword(sizeof(Sockaddr_in) + 16)

    template completeAccept(): stmt {.immediate, dirty.} =
      var listenSock = socket
      let setoptRet = setsockopt(clientSock, SOL_SOCKET,
          SO_UPDATE_ACCEPT_CONTEXT, addr listenSock,
          sizeof(listenSock).SockLen)
      if setoptRet != 0: raiseOSError(osLastError())

      var localSockaddr, remoteSockaddr: ptr SockAddr
      var localLen, remoteLen: int32
      getAcceptExSockaddrs(addr lpOutputBuf[0], dwReceiveDataLength,
                           dwLocalAddressLength, dwRemoteAddressLength,
                           addr localSockaddr, addr localLen,
                           addr remoteSockaddr, addr remoteLen)
      if regAsync:
        register(clientSock.AsyncFD)
      # TODO: IPv6. Check ``sa_family``. http://stackoverflow.com/a/9212542/492186
      retFuture.complete(
        (address: $inet_ntoa(cast[ptr Sockaddr_in](remoteSockAddr).sin_addr),
         client: clientSock.AsyncFD)
      )

    template failAccept(errcode): stmt =
      if flags.isDisconnectionError(errcode):
        var newAcceptFut = acceptAddr(socket, flags)
        newAcceptFut.callback =
          proc () =
            if newAcceptFut.failed:
              retFuture.fail(newAcceptFut.readError)
            else:
              retFuture.complete(newAcceptFut.read)
      else:
        retFuture.fail(newException(OSError, osErrorMsg(errcode)))

    var ol = PCustomOverlapped()
    GC_ref(ol)
    ol.data = CompletionData(fd: socket, cb:
      proc (fd: AsyncFD, bytesCount: Dword, errcode: OSErrorCode) =
        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            completeAccept()
          else:
            failAccept(errcode)
    )

    # http://msdn.microsoft.com/en-us/library/windows/desktop/ms737524%28v=vs.85%29.aspx
    let ret = acceptEx(socket.SocketHandle, clientSock, addr lpOutputBuf[0],
                       dwReceiveDataLength,
                       dwLocalAddressLength,
                       dwRemoteAddressLength,
                       addr dwBytesReceived, cast[POVERLAPPED](ol))

    if not ret:
      let err = osLastError()
      if err.int32 != ERROR_IO_PENDING:
        failAccept(err)
        GC_unref(ol)
    else:
      completeAccept()
      # We don't deallocate ``ol`` here because even though this completed
      # immediately poll will still be notified about its completion and it will
      # free ``ol``.

    return retFuture

  initAll()
else:
  proc acceptAddress*(socket: AsyncFD, flags = {SocketFlag.SafeDisconn},
                      regAsync = true):
                      Future[tuple[address: string, client: AsyncFD]] =
    var retFuture = newFuture[tuple[address: string,
                                    client: AsyncFD]]("acceptAddress")
    proc cb(sock: AsyncFD): bool =
      result = true
      var sockAddress: Sockaddr_storage
      var addrLen = sizeof(sockAddress).Socklen
      var client = accept(sock.SocketHandle,
                          cast[ptr SockAddr](addr(sockAddress)), addr(addrLen))
      if client == osInvalidSocket:
        let lastError = osLastError()
        assert lastError.int32 notin {EWOULDBLOCK, EAGAIN}
        if lastError.int32 == EINTR:
          return false
        else:
          if flags.isDisconnectionError(lastError):
            return false
          else:
            retFuture.fail(newException(OSError, osErrorMsg(lastError)))
      else:
        if regAsync:
          register(client.AsyncFD)
        retFuture.complete((getAddrString(cast[ptr SockAddr](addr sockAddress)),
                            client.AsyncFD))
    addRead(socket, cb)
    return retFuture
