import std/nativesockets
import ./bindings/curl

export CurlMsgType, CURLMsg

type
  Easy* = object
    raw: CURL
    errorBuf: string

  Multi* = object
    raw: CURLM

  Slist* = object
    raw: ptr curl_slist

proc `=destroy`*(easy: Easy) =
  if easy.raw != nil:
    curl_easy_cleanup(easy.raw)
  `=destroy`(easy.errorBuf)

proc `=destroy`*(multi: Multi) =
  if multi.raw != nil:
    discard curl_multi_cleanup(multi.raw)

proc `=destroy`*(list: Slist) =
  if list.raw != nil:
    curl_slist_free_all(list.raw)

proc `=wasMoved`*(easy: var Easy) =
  easy.raw = nil
  `=wasMoved`(easy.errorBuf)

proc `=wasMoved`*(multi: var Multi) =
  multi.raw = nil

proc `=wasMoved`*(list: var Slist) =
  list.raw = nil

proc `=dup`*(src: Easy): Easy {.error.}
proc `=dup`*(src: Multi): Multi {.error.}
proc `=dup`*(src: Slist): Slist {.error.}

proc `=copy`*(dest: var Easy; src: Easy) {.error.}
proc `=copy`*(dest: var Multi; src: Multi) {.error.}
proc `=copy`*(dest: var Slist; src: Slist) {.error.}

proc `=sink`*(dest: var Easy; src: Easy) =
  `=destroy`(dest)
  `=wasMoved`(dest.errorBuf)
  dest.raw = src.raw
  `=sink`(dest.errorBuf, src.errorBuf)

proc `=sink`*(dest: var Multi; src: Multi) =
  `=destroy`(dest)
  dest.raw = src.raw

proc `=sink`*(dest: var Slist; src: Slist) =
  `=destroy`(dest)
  dest.raw = src.raw

proc check*(code: CURLcode; context: string) {.noinline.} =
  ## Raise IOError with curl diagnostic text for a failed easy operation.
  if code != CURLE_OK:
    raise newException(IOError, context & ": " & $curl_easy_strerror(code))

proc check*(code: CURLMcode; context: string) {.noinline.} =
  ## Raise IOError with curl diagnostic text for a failed multi operation.
  if code != CURLM_OK:
    raise newException(IOError, context & ": " & $curl_multi_strerror(code))

proc setOpt*[T](easy: Easy; option: CURLoption; value: T) =
  ## Set a curl option, preserving pointer lifetime requirements of the C API.
  let code = curl_easy_setopt(easy.raw, option, value)
  if code != CURLE_OK:
    check(code, "curl_easy_setopt(" & $cint(option) & ") failed")

proc getInfo*[T](easy: Easy; info: CURLINFO; value: var T) =
  ## Read curl info into storage with the C type required by the info selector.
  let code = curl_easy_getinfo(easy.raw, info, addr value)
  if code != CURLE_OK:
    check(code, "curl_easy_getinfo(" & $cint(info) & ") failed")

proc initEasy*(): Easy =
  var easy = Easy(raw: curl_easy_init(), errorBuf: newString(256))
  if easy.raw == nil:
    raise newException(IOError, "curl_easy_init failed")
  easy.setOpt(CURLOPT_ERRORBUFFER, easy.errorBuf.cstring)
  easy.setOpt(CURLOPT_NOSIGNAL, clong(1))
  result = easy

proc initMulti*(): Multi =
  var multi = Multi(raw: curl_multi_init())
  if multi.raw == nil:
    raise newException(IOError, "curl_multi_init failed")
  check(curl_multi_setopt(multi.raw, CURLMOPT_PIPELINING, CURLPIPE_MULTIPLEX),
    "CURLMOPT_PIPELINING failed")
  result = multi

proc initCurl*() =
  ## Acquire one libcurl initialization reference using the supported thread-safe build.
  check(curl_global_init(CURL_GLOBAL_DEFAULT), "curl_global_init failed")

proc cleanupCurl*() =
  ## Release a matching reference after its handles and workers have stopped.
  curl_global_cleanup()

proc addHandle*(multi: var Multi; easy: Easy) =
  check(curl_multi_add_handle(multi.raw, easy.raw), "curl_multi_add_handle failed")

proc removeHandle*(multi: var Multi; easy: Easy) =
  check(curl_multi_remove_handle(multi.raw, easy.raw), "curl_multi_remove_handle failed")

proc removeHandle*(multi: var Multi; msg: CURLMsg) =
  check(curl_multi_remove_handle(multi.raw, msg.easy_handle),
    "curl_multi_remove_handle failed")

proc perform*(multi: var Multi): int =
  var running: cint
  check(curl_multi_perform(multi.raw, addr running), "curl_multi_perform failed")
  result = int(running)

proc poll*(multi: var Multi; timeoutMs: int; extraFds: var openArray[curl_waitfd]): int =
  var numfds: cint
  let extra = if extraFds.len == 0: nil else: addr extraFds[0]
  check(curl_multi_poll(multi.raw, extra, extraFds.len.cuint, timeoutMs.cint, addr numfds),
    "curl_multi_poll failed")
  result = int(numfds)

proc poll*(multi: var Multi; timeoutMs: int): int =
  var extraFds: array[0, curl_waitfd]
  multi.poll(timeoutMs, extraFds)

proc tryInfoRead*(multi: var Multi; msg: var CURLMsg; msgsInQueue: var int): bool =
  var queue: cint
  let msgPtr = curl_multi_info_read(multi.raw, addr queue)
  msgsInQueue = int(queue)
  if msgPtr.isNil:
    result = false
  else:
    msg = msgPtr[]
    result = true

proc setUrl*(easy: var Easy; url: string) =
  easy.setOpt(CURLOPT_URL, url.cstring)

proc setWriteCallback*(easy: var Easy; cb: curl_write_callback; userdata: pointer) =
  easy.setOpt(CURLOPT_WRITEFUNCTION, cb)
  easy.setOpt(CURLOPT_WRITEDATA, userdata)

proc setHeaderCallback*(easy: var Easy; cb: curl_write_callback; userdata: pointer) =
  easy.setOpt(CURLOPT_HEADERFUNCTION, cb)
  easy.setOpt(CURLOPT_HEADERDATA, userdata)

proc setRequestBody*(easy: var Easy; data: string) =
  # WARNING: CURLOPT_POSTFIELDS does not copy this buffer; caller must keep data
  # alive and unchanged until the transfer is finished or the handle is removed.
  easy.setOpt(CURLOPT_POSTFIELDS, data.cstring)
  easy.setOpt(CURLOPT_POSTFIELDSIZE, clong(data.len))

proc setMethod*(easy: var Easy; verb: string) =
  easy.setOpt(CURLOPT_CUSTOMREQUEST, verb.cstring)

proc setNoBody*(easy: var Easy; enabled: bool) =
  easy.setOpt(CURLOPT_NOBODY, clong(if enabled: 1 else: 0))

proc setHeaders*(easy: var Easy; headers: Slist) =
  easy.setOpt(CURLOPT_HTTPHEADER, headers.raw)

proc setFollowRedirects*(easy: var Easy; follow: bool; maxRedirects: int) =
  easy.setOpt(CURLOPT_FOLLOWLOCATION, clong(if follow: 1 else: 0))
  easy.setOpt(CURLOPT_MAXREDIRS, clong(maxRedirects))

proc setTimeoutMs*(easy: var Easy; timeoutMs: int) =
  easy.setOpt(CURLOPT_TIMEOUT_MS, clong(timeoutMs))

proc setConnectTimeoutMs*(easy: var Easy; timeoutMs: int) =
  easy.setOpt(CURLOPT_CONNECTTIMEOUT_MS, clong(timeoutMs))

proc setSslVerify*(easy: var Easy; verifyPeer: bool; verifyHost: bool) =
  easy.setOpt(CURLOPT_SSL_VERIFYPEER, clong(if verifyPeer: 1 else: 0))
  easy.setOpt(CURLOPT_SSL_VERIFYHOST, clong(if verifyHost: 2 else: 0))

proc setAcceptEncoding*(easy: var Easy; encoding: string) =
  easy.setOpt(CURLOPT_ACCEPT_ENCODING, encoding.cstring)

proc setHttpVersion2Tls*(easy: var Easy) =
  easy.setOpt(CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_2TLS)

proc reset*(easy: var Easy) =
  curl_easy_reset(easy.raw)
  easy.setOpt(CURLOPT_ERRORBUFFER, easy.errorBuf.cstring)
  easy.setOpt(CURLOPT_NOSIGNAL, clong(1))

proc responseCode*(easy: Easy): int =
  var code: clong
  easy.getInfo(CURLINFO_RESPONSE_CODE, code)
  result = int(code)

proc effectiveUrl*(easy: Easy): string =
  var urlPtr: cstring
  easy.getInfo(CURLINFO_EFFECTIVE_URL, urlPtr)
  result = $urlPtr

proc activeSocket*(easy: Easy): SocketHandle =
  easy.getInfo(CURLINFO_ACTIVESOCKET, result)

proc recvFrame*(easy: Easy; buffer: pointer; size: csize_t;
    received: var csize_t; frame: var tuple[flags: cuint, bytesLeft: curl_off_t]): CURLcode =
  ## Return curl's status. Copy metadata on success before another curl call.
  var meta: ptr curl_ws_frame
  result = curl_ws_recv(easy.raw, buffer, size, addr received, addr meta)
  if result == CURLE_OK:
    frame = (meta.flags.cuint, meta.bytesleft)

proc sendFrame*(easy: Easy; buffer: pointer; size: csize_t;
    sent: var csize_t; frameSize: curl_off_t; flags: cuint): CURLcode =
  ## Return curl's status; sent reports any accepted bytes, including on CURLE_AGAIN.
  curl_ws_send(easy.raw, buffer, size, addr sent, frameSize, flags)

proc addHeader*(list: var Slist; headerLine: string) =
  let added = curl_slist_append(list.raw, headerLine.cstring)
  if added.isNil:
    raise newException(IOError, "curl_slist_append failed")
  list.raw = added

proc handleKey*(easy: Easy): pointer {.inline.} =
  easy.raw

proc handleKey*(msg: CURLMsg): pointer {.inline.} =
  msg.easy_handle

proc wakeup*(multi: CURLM) {.raises: [].} =
  ## Best-effort cross-thread wakeup while the caller keeps the handle alive.
  if multi != nil:
    discard curl_multi_wakeup(multi)

proc wakeup*(multi: Multi) {.inline, raises: [].} =
  multi.raw.wakeup()
