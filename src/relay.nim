import std/[deques, locks, strutils, tables]
import ./relay/http_headers
import ./relay/bindings/curl
import ./relay/curl_wrap

export http_headers

const
  MultiWaitMaxMs = 250
  DefaultConnectTimeoutMs = 10_000

template relayTraceLog(msg: string) =
  when defined(relayTrace):
    echo "[relay] " & msg

type
  HttpVerb* = enum
    hvGet = "GET",
    hvPost = "POST",
    hvPut = "PUT",
    hvPatch = "PATCH",
    hvDelete = "DELETE",
    hvHead = "HEAD"

  TransportErrorKind* = enum
    teNone,
    teTimeout,
    teNetwork,
    teDns,
    teTls,
    teCanceled,
    teProtocol,
    teInternal

  TransportError* = object
    kind*: TransportErrorKind
    message*: string
    curlCode*: int

  RequestInfo* = object
    verb*: HttpVerb
    url*: string
    requestId*: int64

  Response* = object
    code*: int
    url*: string
    headers*: HttpHeaders
    body*: string
    request*: RequestInfo

  BatchRequest* = object
    verb*: HttpVerb
    url*: string
    headers*: HttpHeaders
    body*: string
    requestId*: int64
    timeoutMs*: int

  BatchResult* = tuple[response: Response, error: TransportError]
  ResponseBatch* = seq[BatchResult]

  RequestBatch* = object
    requests: seq[BatchRequest]

  RequestWrap = ref object
    verb: HttpVerb
    url: string
    headers: HttpHeaders
    body: string
    requestId: int64
    timeoutMs: int
    responseBody: string
    responseHeadersRaw: string
    easy: Easy
    curlHeaders: Slist

  RelayObj = object
    lock: Lock
    wakeCond: Cond
    resultCond: Cond
    thread: Thread[ptr RelayObj] # break cycle
    workerRunning: bool
    closeRequested: bool
    abortRequested: bool
    closed: bool
    maxInFlight: int
    defaultTimeoutMs: int
    maxRedirects: int
    multi: Multi
    availableEasy: seq[Easy]
    queue: Deque[RequestWrap]
    inFlight: Table[pointer, RequestWrap]
    readyResults: Deque[BatchResult]
  Relay* = ref RelayObj

proc noTransportError(): TransportError {.inline.} =
  TransportError(kind: teNone, message: "", curlCode: 0)

proc newTransportError(kind: TransportErrorKind; message: string;
    curlCode = 0): TransportError {.inline.} =
  TransportError(kind: kind, message: message, curlCode: curlCode)

proc classifyTransportError(curlCode: CURLcode): TransportErrorKind {.inline.} =
  case curlCode
  of CURLE_OPERATION_TIMEDOUT:
    teTimeout
  of CURLE_COULDNT_RESOLVE_PROXY, CURLE_COULDNT_RESOLVE_HOST:
    teDns
  of CURLE_SSL_CONNECT_ERROR, CURLE_PEER_FAILED_VERIFICATION:
    teTls
  of CURLE_ABORTED_BY_CALLBACK:
    teCanceled
  else:
    teNetwork

proc parseHeaders(raw: string): HttpHeaders =
  result = @[]
  for rawLine in raw.split("\r\n"):
    let line = rawLine.strip()
    if line.len == 0:
      discard
    elif line.startsWith("HTTP/"):
      result.setLen(0)
    else:
      let sep = line.find(':')
      if sep < 0:
        result.add((line, ""))
      elif sep == 0:
        result.add(("", line.substr(1).strip()))
      else:
        let name = line.substr(0, sep - 1).strip()
        let value =
          if sep + 1 >= line.len: ""
          else: line.substr(sep + 1).strip()
        result.add((name, value))

proc bodyWriteCb(buffer: ptr char; size, nitems: csize_t; userdata: pointer): csize_t {.cdecl.} =
  let total = int(size * nitems)
  if total <= 0:
    result = 0
  else:
    let body = cast[ptr string](userdata)
    if body.isNil:
      result = csize_t(total)
    else:
      let start = body[].len
      body[].setLen(start + total)
      copyMem(addr body[][start], buffer, total)
      result = csize_t(total)

proc headerWriteCb(buffer: ptr char; size, nitems: csize_t;
    userdata: pointer): csize_t {.cdecl.} =
  let total = int(size * nitems)
  if total <= 0:
    result = 0
  else:
    let headers = cast[ptr string](userdata)
    if headers.isNil:
      result = csize_t(total)
    else:
      let start = headers[].len
      headers[].setLen(start + total)
      copyMem(addr headers[][start], buffer, total)
      result = csize_t(total)

proc newResponse(request: RequestWrap): Response {.inline.} =
  Response(
    code: 0,
    url: request.url,
    headers: @[],
    body: "",
    request: RequestInfo(
      verb: request.verb,
      url: move request.url,
      requestId: request.requestId
    )
  )

proc storeCompletionLocked(client: Relay; item: sink BatchResult) =
  relayTraceLog("storeCompletionLocked id=" & $item.response.request.requestId &
    " err=" & $item.error.kind)
  client.readyResults.addLast(item)
  signal(client.resultCond)

proc configureEasy(client: Relay; request: RequestWrap; easy: var Easy) =
  easy.reset()
  easy.setUrl(request.url)

  easy.setMethod($request.verb)
  easy.setNoBody(request.verb == hvHead)
  if request.body.len > 0:
    easy.setRequestBody(request.body)

  var headerList: Slist
  for header in request.headers:
    headerList.addHeader(header.name & ": " & header.value)
  request.curlHeaders = headerList
  easy.setHeaders(request.curlHeaders)

  easy.setWriteCallback(bodyWriteCb, cast[pointer](addr request.responseBody))
  easy.setHeaderCallback(headerWriteCb, cast[pointer](addr request.responseHeadersRaw))
  easy.setTimeoutMs(if request.timeoutMs > 0: request.timeoutMs else: client.defaultTimeoutMs)
  easy.setConnectTimeoutMs(DefaultConnectTimeoutMs)
  easy.setSslVerify(true, true)
  easy.setAcceptEncoding("gzip, deflate")
  easy.setFollowRedirects(true, client.maxRedirects)

proc completionFromCurl(request: RequestWrap; curlCode: CURLcode;
    removeError: string): BatchResult =
  result.response = newResponse(request)
  if removeError.len > 0:
    result.error = newTransportError(teInternal, removeError)
  elif curlCode != CURLE_OK:
    result.error = newTransportError(
      classifyTransportError(curlCode),
      "curl transfer failed code=" & $int(curlCode),
      int(curlCode)
    )
  else:
    try:
      result.response.code = request.easy.responseCode()
      let effective = request.easy.effectiveUrl()
      if effective.len > 0:
        result.response.url = effective
      result.response.headers = parseHeaders(request.responseHeadersRaw)
      result.response.body = move request.responseBody
      result.error = noTransportError()
    except CatchableError:
      result.error = newTransportError(teInternal, getCurrentExceptionMsg())

proc flushCanceledLocked(client: Relay; message: string) =
  while client.queue.len > 0:
    let queued = client.queue.popFirst()
    client.storeCompletionLocked(
      (newResponse(queued), newTransportError(teCanceled, message)))

  for req in client.inFlight.mvalues:
    try:
      client.multi.removeHandle(req.easy)
    except CatchableError:
      discard
    client.availableEasy.add(req.easy)
    client.storeCompletionLocked(
      (newResponse(req), newTransportError(teCanceled, message)))
  client.inFlight.clear()

proc runEasyLoop(client: Relay): bool =
  result = true
  try:
    relayTraceLog("runEasyLoop perform begin")
    let running = client.multi.perform()
    relayTraceLog("runEasyLoop perform end running=" & $running)
    relayTraceLog("runEasyLoop poll begin timeoutMs=" & $MultiWaitMaxMs)
    let numfds = client.multi.poll(MultiWaitMaxMs)
    relayTraceLog("runEasyLoop poll end numfds=" & $numfds)
  except CatchableError:
    let loopError = getCurrentExceptionMsg()
    relayTraceLog("runEasyLoop error: " & loopError)
    acquire(client.lock)
    while client.queue.len > 0:
      let queued = client.queue.popFirst()
      client.storeCompletionLocked(
        (newResponse(queued), newTransportError(teInternal, loopError)))
    for req in client.inFlight.mvalues:
      client.storeCompletionLocked(
        (newResponse(req), newTransportError(teInternal, loopError)))
    client.inFlight.clear()
    client.abortRequested = true
    signal(client.wakeCond)
    release(client.lock)
    result = false

proc processDoneMessages(client: Relay) =
  var msg: CURLMsg
  var msgsInQueue = 0
  relayTraceLog("processDoneMessages enter")
  while client.multi.tryInfoRead(msg, msgsInQueue):
    relayTraceLog("processDoneMessages msg=" & $msg.msg &
      " msgsInQueue=" & $msgsInQueue)
    if msg.msg == CURLMSG_DONE:
      var request: RequestWrap
      let key = handleKey(msg)
      var found = false
      acquire(client.lock)
      found = client.inFlight.pop(key, request)
      release(client.lock)

      relayTraceLog("done msg key=" & $cast[uint](key) & " found=" & $found)

      if found and request != nil:
        relayTraceLog("processing done id=" & $request.requestId &
          " curlCode=" & $int(msg.data.result))
        var removeError = ""
        try:
          client.multi.removeHandle(msg)
        except CatchableError:
          removeError = getCurrentExceptionMsg()

        let completion = completionFromCurl(request, msg.data.result, removeError)
        acquire(client.lock)
        if request.easy != nil:
          client.availableEasy.add(request.easy)
        client.storeCompletionLocked(completion)
        release(client.lock)
      elif not found:
        relayTraceLog("done msg missing inFlight entry; requesting abort")
        acquire(client.lock)
        # Avoid hanging callers if a completion cannot be matched to inFlight.
        client.abortRequested = true
        signal(client.wakeCond)
        release(client.lock)
    else:
      relayTraceLog("processDoneMessages skipping non-DONE msg=" & $msg.msg)
  relayTraceLog("processDoneMessages exit")

proc dispatchQueuedRequests(client: Relay) =
  var done = false
  while not done:
    var request: RequestWrap
    var easy: Easy
    acquire(client.lock)
    if client.abortRequested or client.availableEasy.len == 0 or client.queue.len == 0:
      done = true
    else:
      request = client.queue.popFirst()
      easy = client.availableEasy.pop()
    release(client.lock)

    if not done:
      var dispatched = true
      var dispatchError = ""
      try:
        request.easy = easy
        configureEasy(client, request, easy)
        client.multi.addHandle(easy)
      except CatchableError:
        dispatched = false
        dispatchError = getCurrentExceptionMsg()

      acquire(client.lock)
      if dispatched:
        relayTraceLog("dispatched id=" & $request.requestId &
          " key=" & $cast[uint](handleKey(easy)))
        client.inFlight[handleKey(easy)] = request
      else:
        relayTraceLog("dispatch failed id=" & $request.requestId &
          " err=" & dispatchError)
        client.availableEasy.add(easy)
        client.storeCompletionLocked(
          (newResponse(request), newTransportError(teInternal, dispatchError)))
      release(client.lock)

proc waitForWorkOrClose(client: Relay): bool =
  relayTraceLog("waitForWorkOrClose enter")
  result = true
  acquire(client.lock)
  relayTraceLog("waitForWorkOrClose state queue=" & $client.queue.len &
    " inFlight=" & $client.inFlight.len &
    " abort=" & $client.abortRequested &
    " close=" & $client.closeRequested)
  while not client.abortRequested and not client.closeRequested and
      client.queue.len == 0 and client.inFlight.len == 0:
    relayTraceLog("waitForWorkOrClose sleeping")
    wait(client.wakeCond, client.lock)

  if client.abortRequested:
    result = false
  elif client.closeRequested and client.queue.len == 0 and client.inFlight.len == 0:
    result = false
  release(client.lock)
  relayTraceLog("waitForWorkOrClose exit result=" & $result)

proc workerMain(clientPtr: ptr RelayObj) {.thread, raises: [].} =
  let client = cast[Relay](clientPtr)
  var iter = 0
  while true:
    inc iter
    relayTraceLog("worker iter=" & $iter & " dispatchQueuedRequests")
    dispatchQueuedRequests(client)

    acquire(client.lock)
    let hasInflight = client.inFlight.len > 0
    let shouldAbort = client.abortRequested
    relayTraceLog("worker iter=" & $iter &
      " after-dispatch queue=" & $client.queue.len &
      " inFlight=" & $client.inFlight.len &
      " hasInflight=" & $hasInflight &
      " abort=" & $shouldAbort)
    release(client.lock)

    if shouldAbort:
      acquire(client.lock)
      flushCanceledLocked(client, "Canceled in abort")
      release(client.lock)
      break

    if hasInflight:
      if not runEasyLoop(client):
        break
      processDoneMessages(client)
    elif not waitForWorkOrClose(client):
      break

  acquire(client.lock)
  client.workerRunning = false
  signal(client.resultCond)
  release(client.lock)

proc newRelay*(maxInFlight = 16; defaultTimeoutMs = 60_000;
    maxRedirects = 10): Relay =
  initGlobal()

  new(result)
  initLock(result.lock)
  initCond(result.wakeCond)
  initCond(result.resultCond)
  result.maxInFlight = max(1, maxInFlight)
  result.defaultTimeoutMs = max(1, defaultTimeoutMs)
  result.maxRedirects = max(0, maxRedirects)
  result.workerRunning = true
  result.closeRequested = false
  result.abortRequested = false
  result.closed = false
  result.multi = initMulti()
  result.queue = initDeque[RequestWrap]()
  result.readyResults = initDeque[BatchResult]()
  result.inFlight = initTable[pointer, RequestWrap]()
  for _ in 0..<result.maxInFlight:
    result.availableEasy.add(initEasy())

  createThread(result.thread, workerMain, cast[ptr RelayObj](result))

proc close*(client: Relay) =
  if client.isNil:
    return

  acquire(client.lock)
  if client.closed:
    release(client.lock)
    return
  client.closeRequested = true
  signal(client.wakeCond)
  release(client.lock)

  joinThread(client.thread)

  acquire(client.lock)
  client.closed = true
  client.availableEasy.setLen(0)
  client.queue.clear()
  client.inFlight.clear()
  client.readyResults.clear()
  release(client.lock)

  deinitCond(client.resultCond)
  deinitCond(client.wakeCond)
  deinitLock(client.lock)
  cleanupGlobal()

proc abort*(client: Relay) =
  if client.isNil:
    return

  acquire(client.lock)
  if client.closed:
    release(client.lock)
  else:
    client.abortRequested = true
    client.closeRequested = true
    signal(client.wakeCond)
    release(client.lock)
    joinThread(client.thread)

    acquire(client.lock)
    client.closed = true
    client.availableEasy.setLen(0)
    client.queue.clear()
    client.inFlight.clear()
    client.readyResults.clear()
    release(client.lock)

    deinitCond(client.resultCond)
    deinitCond(client.wakeCond)
    deinitLock(client.lock)
    cleanupGlobal()

proc hasRequests*(client: Relay): bool =
  acquire(client.lock)
  result = client.queue.len > 0 or client.inFlight.len > 0
  release(client.lock)

proc numInFlight*(client: Relay): int =
  acquire(client.lock)
  result = client.inFlight.len
  release(client.lock)

proc queueLen*(client: Relay): int =
  acquire(client.lock)
  result = client.queue.len
  release(client.lock)

proc clearQueue*(client: Relay) =
  acquire(client.lock)
  while client.queue.len > 0:
    let queued = client.queue.popFirst()
    client.storeCompletionLocked(
      (newResponse(queued), newTransportError(teCanceled, "Canceled in clearQueue")))
  release(client.lock)

proc startRequests*(client: Relay; batch: sink RequestBatch) =
  acquire(client.lock)
  if client.closed or client.closeRequested:
    release(client.lock)
    raise newException(IOError, "client is closed")

  for request in batch.requests.mitems:
    let wrapped = RequestWrap(
      verb: request.verb,
      url: move request.url,
      headers: move request.headers,
      body: move request.body,
      requestId: request.requestId,
      timeoutMs: request.timeoutMs,
      responseBody: "",
      responseHeadersRaw: "",
      easy: nil
    )
    client.queue.addLast(wrapped)

  signal(client.wakeCond)
  release(client.lock)

proc waitForResult*(client: Relay; outResult: var BatchResult): bool =
  acquire(client.lock)
  while client.readyResults.len == 0 and client.workerRunning:
    wait(client.resultCond, client.lock)

  if client.readyResults.len > 0:
    outResult = client.readyResults.popFirst()
    result = true
  else:
    result = false
  release(client.lock)

proc pollForResult*(client: Relay; outResult: var BatchResult): bool =
  acquire(client.lock)
  if client.readyResults.len > 0:
    outResult = client.readyResults.popFirst()
    result = true
  else:
    result = false
  release(client.lock)

proc makeRequests*(client: Relay; batch: sink RequestBatch): ResponseBatch =
  acquire(client.lock)
  let busy =
    client.queue.len > 0 or
    client.inFlight.len > 0 or
    client.readyResults.len > 0
  release(client.lock)

  if busy:
    raise newException(IOError, "makeRequests requires an idle client")

  let expected = batch.requests.len
  client.startRequests(batch)
  result = @[]
  for _ in 0..<expected:
    var item: BatchResult
    if not client.waitForResult(item):
      raise newException(IOError, "client stopped before all responses arrived")
    result.add(item)

proc len*(batch: RequestBatch): int =
  batch.requests.len

proc `[]`*(batch: RequestBatch; i: int): lent BatchRequest =
  batch.requests[i]

proc addRequest*(batch: var RequestBatch; verb: HttpVerb; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); body: sink string = "";
    requestId = 0'i64; timeoutMs = 0) =
  batch.requests.add(BatchRequest(
    verb: verb,
    url: url,
    headers: headers,
    body: body,
    requestId: requestId,
    timeoutMs: timeoutMs
  ))

proc get*(batch: var RequestBatch; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); requestId = 0'i64;
    timeoutMs = 0) =
  batch.addRequest(hvGet, url, headers, "", requestId, timeoutMs)

proc post*(batch: var RequestBatch; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); body: sink string = "";
    requestId = 0'i64; timeoutMs = 0) =
  batch.addRequest(hvPost, url, headers, body, requestId, timeoutMs)

proc put*(batch: var RequestBatch; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); body: sink string = "";
    requestId = 0'i64; timeoutMs = 0) =
  batch.addRequest(hvPut, url, headers, body, requestId, timeoutMs)

proc patch*(batch: var RequestBatch; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); body: sink string = "";
    requestId = 0'i64; timeoutMs = 0) =
  batch.addRequest(hvPatch, url, headers, body, requestId, timeoutMs)

proc delete*(batch: var RequestBatch; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); requestId = 0'i64;
    timeoutMs = 0) =
  batch.addRequest(hvDelete, url, headers, "", requestId, timeoutMs)

proc head*(batch: var RequestBatch; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); requestId = 0'i64;
    timeoutMs = 0) =
  batch.addRequest(hvHead, url, headers, "", requestId, timeoutMs)
