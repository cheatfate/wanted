#
#
#      Wanted asynchronous threaded webserver
#        (c) Copyright 2016 Eugene Kabanov
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

type
  SharedArrayList {.unchecked.}[T] = array[0..100, T]
  SharedArray*[T] = ptr SharedArrayList[T]

proc allocSharedArray*[T](nsize: int): SharedArray[T] =
  result = cast[SharedArray[T]](allocShared0(sizeof(T) * (nsize + 1)))

proc deallocSharedArray*[T](sa: SharedArray[T]) =
  deallocShared(cast[pointer](sa))
