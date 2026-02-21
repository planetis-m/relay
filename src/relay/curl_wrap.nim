import ./bindings/curl

export CurlMsgType, CURLMsg

type
  EasyObj = object
    raw: CURL
    postData: string
    errorBuf: array[256, char]
  Easy* = ref EasyObj

  Multi* = object
    raw: CURLM

  Slist* = object
    raw: ptr curl_slist

proc `=destroy`(easy: EasyObj) =
  if pointer(easy.raw) != nil:
    curl_easy_cleanup(easy.raw)
    `=destroy`(easy.postData)

proc `=destroy`*(multi: Multi) =
  if pointer(multi.raw) != nil:
    discard curl_multi_cleanup(multi.raw)

proc `=destroy`*(list: Slist) =
  if pointer(list.raw) != nil:
    curl_slist_free_all(list.raw)

proc `=copy`*(dest: var EasyObj; src: EasyObj) {.error.}
proc `=dup`*(src: EasyObj): EasyObj {.error.}
proc `=sink`*(dest: var EasyObj; src: EasyObj) {.error.}
proc `=wasMoved`*(easy: var EasyObj) {.error.}

proc `=copy`*(dest: var Multi; src: Multi) {.error.}
proc `=copy`*(dest: var Slist; src: Slist) {.error.}

proc `=dup`*(src: Multi): Multi {.error.}
proc `=dup`*(src: Slist): Slist {.error.}

proc `=sink`*(dest: var Multi; src: Multi) =
  `=destroy`(dest)
  dest.raw = src.raw

proc `=sink`*(dest: var Slist; src: Slist) =
  `=destroy`(dest)
  dest.raw = src.raw

proc `=wasMoved`*(multi: var Multi) =
  multi.raw = CURLM(nil)

proc `=wasMoved`*(list: var Slist) =
  list.raw = nil

proc checkCurl(code: CURLcode; context: string) {.noinline.} =
  if code != CURLE_OK:
    raise newException(IOError, context & ": " & $curl_easy_strerror(code))

proc checkMulti(code: CURLMcode; context: string) {.noinline.} =
  if code != CURLM_OK:
    raise newException(IOError, context & ": " & $curl_multi_strerror(code))

proc initEasy*(): Easy =
  result = Easy(raw: curl_easy_init())
  if pointer(result.raw) == nil:
    raise newException(IOError, "curl_easy_init failed")
  discard curl_easy_setopt(result.raw, CURLOPT_ERRORBUFFER, addr result.errorBuf[0])
  discard curl_easy_setopt(result.raw, CURLOPT_NOSIGNAL, clong(1))

proc initMulti*(): Multi =
  result = Multi(raw: curl_multi_init())
  if pointer(result.raw) == nil:
    raise newException(IOError, "curl_multi_init failed")

proc initGlobal*() =
  checkCurl(curl_global_init(culong(3)), "curl_global_init failed")

proc cleanupGlobal*() =
  curl_global_cleanup()

proc addHandle*(multi: var Multi; easy: Easy) =
  checkMulti(curl_multi_add_handle(multi.raw, easy.raw), "curl_multi_add_handle failed")

proc removeHandle*(multi: var Multi; easy: Easy) =
  checkMulti(curl_multi_remove_handle(multi.raw, easy.raw), "curl_multi_remove_handle failed")

proc removeHandle*(multi: var Multi; msg: CURLMsg) =
  checkMulti(curl_multi_remove_handle(multi.raw, msg.easy_handle),
    "curl_multi_remove_handle failed")

proc perform*(multi: var Multi): int =
  var running: cint
  checkMulti(curl_multi_perform(multi.raw, addr running), "curl_multi_perform failed")
  result = int(running)

proc poll*(multi: var Multi; timeoutMs: int): int =
  var numfds: cint
  checkMulti(curl_multi_poll(multi.raw, nil, 0.cuint, timeoutMs.cint, addr numfds),
    "curl_multi_poll failed")
  result = int(numfds)

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
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_URL, url.cstring), "CURLOPT_URL failed")

proc setWriteCallback*(easy: var Easy; cb: curl_write_callback; userdata: pointer) =
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_WRITEFUNCTION, cb),
    "CURLOPT_WRITEFUNCTION failed")
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_WRITEDATA, userdata),
    "CURLOPT_WRITEDATA failed")

proc setHeaderCallback*(easy: var Easy; cb: curl_write_callback; userdata: pointer) =
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_HEADERFUNCTION, cb),
    "CURLOPT_HEADERFUNCTION failed")
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_HEADERDATA, userdata),
    "CURLOPT_HEADERDATA failed")

proc setRequestBody*(easy: var Easy; data: string) =
  easy.postData = data
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_POSTFIELDS, easy.postData.cstring),
    "CURLOPT_POSTFIELDS failed")
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_POSTFIELDSIZE, clong(easy.postData.len)),
    "CURLOPT_POSTFIELDSIZE failed")

proc setMethod*(easy: var Easy; verb: string) =
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_CUSTOMREQUEST, verb.cstring),
    "CURLOPT_CUSTOMREQUEST failed")

proc setNoBody*(easy: var Easy; enabled: bool) =
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_NOBODY, clong(if enabled: 1 else: 0)),
    "CURLOPT_NOBODY failed")

proc setHeaders*(easy: var Easy; headers: Slist) =
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_HTTPHEADER, headers.raw),
    "CURLOPT_HTTPHEADER failed")

proc setFollowRedirects*(easy: var Easy; follow: bool; maxRedirects: int) =
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_FOLLOWLOCATION, clong(if follow: 1 else: 0)),
    "CURLOPT_FOLLOWLOCATION failed")
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_MAXREDIRS, clong(maxRedirects)),
    "CURLOPT_MAXREDIRS failed")

proc setTimeoutMs*(easy: var Easy; timeoutMs: int) =
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_TIMEOUT_MS, clong(timeoutMs)),
    "CURLOPT_TIMEOUT_MS failed")

proc setConnectTimeoutMs*(easy: var Easy; timeoutMs: int) =
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_CONNECTTIMEOUT_MS, clong(timeoutMs)),
    "CURLOPT_CONNECTTIMEOUT_MS failed")

proc setSslVerify*(easy: var Easy; verifyPeer: bool; verifyHost: bool) =
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_SSL_VERIFYPEER,
    clong(if verifyPeer: 1 else: 0)), "CURLOPT_SSL_VERIFYPEER failed")
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_SSL_VERIFYHOST,
    clong(if verifyHost: 2 else: 0)), "CURLOPT_SSL_VERIFYHOST failed")

proc setAcceptEncoding*(easy: var Easy; encoding: string) =
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_ACCEPT_ENCODING, encoding.cstring),
    "CURLOPT_ACCEPT_ENCODING failed")

proc reset*(easy: var Easy) =
  curl_easy_reset(easy.raw)
  easy.postData.setLen(0)
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_ERRORBUFFER, addr easy.errorBuf[0]),
    "CURLOPT_ERRORBUFFER failed")
  checkCurl(curl_easy_setopt(easy.raw, CURLOPT_NOSIGNAL, clong(1)),
    "CURLOPT_NOSIGNAL failed")

proc responseCode*(easy: Easy): int =
  var code: clong
  checkCurl(curl_easy_getinfo(easy.raw, CURLINFO_RESPONSE_CODE, addr code),
    "CURLINFO_RESPONSE_CODE failed")
  result = int(code)

proc effectiveUrl*(easy: Easy): string =
  var urlPtr: cstring
  checkCurl(curl_easy_getinfo(easy.raw, CURLINFO_EFFECTIVE_URL, addr urlPtr),
    "CURLINFO_EFFECTIVE_URL failed")
  if urlPtr.isNil:
    result = ""
  else:
    result = $urlPtr

proc addHeader*(list: var Slist; headerLine: string) =
  list.raw = curl_slist_append(list.raw, headerLine.cstring)
  if list.raw.isNil:
    raise newException(IOError, "curl_slist_append failed")

proc handleKey*(easy: Easy): pointer =
  cast[pointer](easy.raw)

proc handleKey*(msg: CURLMsg): pointer =
  cast[pointer](msg.easy_handle)
