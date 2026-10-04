import std/[deques, locks, tables]
import ./relay/bindings/curl
import ./relay/[http_headers, http_query, http_status, retry, curl_wrap, transport_errors]

export http_headers
export http_query
export http_status
export retry
export transport_errors

const
  MultiWaitMaxMs = 250
  DefaultConnectTimeoutMs = 10_000

type
  HttpVerb* = enum
    hvGet = "GET",
    hvPost = "POST",
    hvPut = "PUT",
    hvPatch = "PATCH",
    hvDelete = "DELETE",
    hvHead = "HEAD",
    hvOptions = "OPTIONS",
    hvConnect = "CONNECT",
    hvTrace = "TRACE"

  RequestInfo* = object
    verb*: HttpVerb
    url*: string
    requestId*: int64

  Response* = object
    code*: HttpCode
    url*: string
    headers*: HttpHeaders
    body*: string
    request*: RequestInfo

  RequestSpec* = object
    verb*: HttpVerb
    url*: string
    headers*: HttpHeaders
    body*: string
    requestId*: int64
    timeoutMs*: int

  RequestResult* = tuple[response: Response, error: TransportError]
  RequestResults* = seq[RequestResult]

  RequestBatch* = object
    requests: seq[RequestSpec]

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

  # Synchronization primitives must retain identity during automatic destruction.
  HttpClientObj {.byref.} = object
    lock: Lock
    wakeCond: Cond
    resultCond: Cond
    thread: Thread[ptr HttpClientObj] # break cycle
    initialized, globalInitialized, threadStarted: bool
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
    readyResults: Deque[RequestResult]
  HttpClient* = ref HttpClientObj
    ## HTTP request worker with shared lifetime and completion-order results.
  Relay* = HttpClient
    ## Compatibility name for HttpClient.

proc shutdown(client: ptr HttpClientObj; aborting: bool) {.raises: [].}

proc `=destroy`(client: HttpClientObj) =
  let owner = cast[ptr HttpClientObj](addr client)
  if client.initialized:
    owner.shutdown(true)
    deinitCond(owner.resultCond)
    deinitCond(owner.wakeCond)
    deinitLock(owner.lock)
  `=destroy`(owner.multi)
  `=destroy`(owner.availableEasy)
  `=destroy`(owner.queue)
  `=destroy`(owner.inFlight)
  `=destroy`(owner.readyResults)

proc isRetryable*(kind: TransportErrorKind): bool {.inline.} =
  ## Returns true for timeouts, network, DNS, TLS, and internal errors.
  case kind
  of teTimeout, teNetwork, teDns, teTls, teInternal:
    result = true
  of teNone, teCanceled, teProtocol:
    result = false

proc noTransportError(): TransportError {.inline.} =
  TransportError(kind: teNone, message: "", curlCode: 0)

proc newTransportError(kind: TransportErrorKind; message: sink string;
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
    code: HttpCode(0),
    url: request.url,
    headers: @[],
    body: "",
    request: RequestInfo(
      verb: request.verb,
      url: move request.url,
      requestId: request.requestId
    )
  )

proc storeCompletionLocked(client: ptr HttpClientObj; item: sink RequestResult) =
  client.readyResults.addLast(item)
  broadcast(client.resultCond)

proc configureEasy(client: ptr HttpClientObj; request: RequestWrap; easy: var Easy) =
  easy.reset()
  easy.setUrl(request.url)
  easy.setHttpVersion2Tls()

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
    removeError: sink string): RequestResult =
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
      result.response.code = HttpCode(request.easy.responseCode())
      let effective = request.easy.effectiveUrl()
      if effective.len > 0:
        result.response.url = effective
      result.response.headers = parseHeaders(request.responseHeadersRaw)
      result.response.body = move request.responseBody
      result.error = noTransportError()
    except CatchableError:
      result.error = newTransportError(teInternal, getCurrentExceptionMsg())

proc flushCanceledLocked(client: ptr HttpClientObj; message: string) =
  while client.queue.len > 0:
    let queued = client.queue.popFirst()
    client.storeCompletionLocked(
      (newResponse(queued), newTransportError(teCanceled, message)))

  for req in values(client.inFlight):
    try:
      client.multi.removeHandle(req.easy)
    except CatchableError:
      discard
    client.availableEasy.add(move req.easy)
    client.storeCompletionLocked(
      (newResponse(req), newTransportError(teCanceled, message)))
  client.inFlight.clear()

proc runEasyLoop(client: ptr HttpClientObj): bool =
  result = true
  try:
    discard client.multi.perform()
    discard client.multi.poll(MultiWaitMaxMs)
  except CatchableError:
    let loopError = getCurrentExceptionMsg()
    acquire(client.lock)
    while client.queue.len > 0:
      let queued = client.queue.popFirst()
      client.storeCompletionLocked(
        (newResponse(queued), newTransportError(teInternal, loopError)))
    for req in values(client.inFlight):
      try:
        client.multi.removeHandle(req.easy)
      except CatchableError:
        discard
      client.availableEasy.add(move req.easy)
      client.storeCompletionLocked(
        (newResponse(req), newTransportError(teInternal, loopError)))
    client.inFlight.clear()
    client.abortRequested = true
    signal(client.wakeCond)
    release(client.lock)
    result = false

proc processDoneMessages(client: ptr HttpClientObj) =
  var msg: CURLMsg
  var msgsInQueue = 0
  while client.multi.tryInfoRead(msg, msgsInQueue):
    if msg.msg == CURLMSG_DONE:
      var request: RequestWrap
      let key = handleKey(msg)
      acquire(client.lock)
      discard client.inFlight.pop(key, request)
      release(client.lock)

      if request != nil:
        var removeError = ""
        try:
          client.multi.removeHandle(msg)
        except CatchableError:
          removeError = getCurrentExceptionMsg()

        let completion = completionFromCurl(request, msg.data.result, removeError)
        acquire(client.lock)
        client.availableEasy.add(move request.easy)
        client.storeCompletionLocked(completion)
        release(client.lock)

proc dispatchQueuedRequests(client: ptr HttpClientObj) =
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
        request.easy = move easy
        configureEasy(client, request, request.easy)
        client.multi.addHandle(request.easy)
      except CatchableError:
        dispatched = false
        dispatchError = getCurrentExceptionMsg()

      acquire(client.lock)
      if dispatched:
        client.inFlight[handleKey(request.easy)] = request
      else:
        client.availableEasy.add(move request.easy)
        client.storeCompletionLocked(
          (newResponse(request), newTransportError(teInternal, dispatchError)))
      release(client.lock)

proc waitForWorkOrClose(client: ptr HttpClientObj): bool =
  result = true
  acquire(client.lock)
  while not client.abortRequested and not client.closeRequested and
      client.queue.len == 0 and client.inFlight.len == 0:
    wait(client.wakeCond, client.lock)

  if client.abortRequested:
    result = false
  elif client.closeRequested and client.queue.len == 0 and client.inFlight.len == 0:
    result = false
  release(client.lock)

proc workerMain(clientPtr: ptr HttpClientObj) {.thread, raises: [].} =
  let client = clientPtr
  while true:
    dispatchQueuedRequests(client)

    acquire(client.lock)
    let hasInflight = client.inFlight.len > 0
    let shouldAbort = client.abortRequested
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
  broadcast(client.resultCond)
  release(client.lock)

proc newHttpClient*(maxInFlight = 16; defaultTimeoutMs = 60_000;
    maxRedirects = 10): HttpClient =
  let client = HttpClient(maxInFlight: max(1, maxInFlight),
    defaultTimeoutMs: max(1, defaultTimeoutMs), maxRedirects: max(0, maxRedirects))
  initLock(client.lock)
  initCond(client.wakeCond)
  initCond(client.resultCond)
  client.initialized = true
  initGlobal()
  client.globalInitialized = true
  client.multi = initMulti()
  for _ in 0..<client.maxInFlight:
    client.availableEasy.add(initEasy())
  client.workerRunning = true
  createThread(client.thread, workerMain, cast[ptr HttpClientObj](client))
  client.threadStarted = true
  result = client

proc newRelay*(maxInFlight = 16; defaultTimeoutMs = 60_000;
    maxRedirects = 10): HttpClient {.inline.} =
  ## Compatibility constructor; prefer newHttpClient for new code.
  newHttpClient(maxInFlight, defaultTimeoutMs, maxRedirects)

proc shutdown(client: ptr HttpClientObj; aborting: bool) =
  acquire(client.lock)
  let join = not client.closed
  if join:
    client.closeRequested = true
    client.abortRequested = aborting
    signal(client.wakeCond)
    client.multi.wakeup()
  release(client.lock)
  if join:
    if client.threadStarted: joinThread(client.thread)
    acquire(client.lock)
    client.closed = true
    client.availableEasy.reset()
    client.queue.clear()
    client.inFlight.clear()
    client.readyResults.clear()
    reset(client.multi)
    broadcast(client.resultCond)
    release(client.lock)
    if client.globalInitialized:
      cleanupGlobal()
      client.globalInitialized = false

proc close*(client: HttpClient) =
  if client != nil: cast[ptr HttpClientObj](client).shutdown(false)

proc abort*(client: HttpClient) =
  if client != nil: cast[ptr HttpClientObj](client).shutdown(true)

proc hasRequests*(client: HttpClient): bool =
  acquire(client.lock)
  result = client.queue.len > 0 or client.inFlight.len > 0
  release(client.lock)

proc numInFlight*(client: HttpClient): int =
  acquire(client.lock)
  result = client.inFlight.len
  release(client.lock)

proc queueLen*(client: HttpClient): int =
  acquire(client.lock)
  result = client.queue.len
  release(client.lock)

proc clearQueue*(client: HttpClient) =
  acquire(client.lock)
  while client.queue.len > 0:
    let queued = client.queue.popFirst()
    cast[ptr HttpClientObj](client).storeCompletionLocked(
      (newResponse(queued), newTransportError(teCanceled, "Canceled in clearQueue")))
  release(client.lock)

proc clientIsBusy(client: HttpClient): bool =
  acquire(client.lock)
  result =
    client.queue.len > 0 or
    client.inFlight.len > 0 or
    client.readyResults.len > 0
  release(client.lock)

proc wrapRequest(request: sink RequestSpec): RequestWrap {.inline.} =
  RequestWrap(
    verb: request.verb,
    url: move request.url,
    headers: move request.headers,
    body: move request.body,
    requestId: request.requestId,
    timeoutMs: request.timeoutMs,
    responseBody: "",
    responseHeadersRaw: "",
    easy: default(Easy)
  )

proc startRequests*(client: HttpClient; batch: var RequestBatch) =
  acquire(client.lock)
  if client.closed or client.closeRequested:
    release(client.lock)
    raise newException(IOError, "client is closed")
  
  for request in batch.requests.mitems:
    client.queue.addLast(wrapRequest(move request))
  batch.requests.setLen(0)
  
  signal(client.wakeCond)
  client.multi.wakeup()
  release(client.lock)

proc startRequest*(client: HttpClient; request: sink RequestSpec) =
  acquire(client.lock)
  if client.closed or client.closeRequested:
    release(client.lock)
    raise newException(IOError, "client is closed")
  
  client.queue.addLast(wrapRequest(request))
  
  signal(client.wakeCond)
  client.multi.wakeup()
  release(client.lock)

proc waitForResult*(client: HttpClient; outResult: var RequestResult): bool =
  acquire(client.lock)
  while client.readyResults.len == 0 and client.workerRunning:
    wait(client.resultCond, client.lock)

  if client.readyResults.len > 0:
    outResult = client.readyResults.popFirst()
    result = true
  else:
    result = false
  release(client.lock)

proc pollForResult*(client: HttpClient; outResult: var RequestResult): bool =
  acquire(client.lock)
  if client.readyResults.len > 0:
    outResult = client.readyResults.popFirst()
    result = true
  else:
    result = false
  release(client.lock)

proc makeRequests*(client: HttpClient; batch: var RequestBatch): RequestResults =
  if client.clientIsBusy():
    raise newException(IOError, "makeRequests requires an idle client")

  let expected = batch.requests.len
  client.startRequests(batch)
  result = @[]
  for _ in 0..<expected:
    var item: RequestResult
    if not client.waitForResult(item):
      raise newException(IOError, "client stopped before all responses arrived")
    result.add(item)

proc makeRequest*(client: HttpClient; request: sink RequestSpec): RequestResult =
  if client.clientIsBusy():
    raise newException(IOError, "makeRequest requires an idle client")

  client.startRequest(request)
  if not client.waitForResult(result):
    raise newException(IOError, "client stopped before response arrived")

proc makeVerbRequest(client: HttpClient; verb: HttpVerb; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); body: sink string = "";
    requestId = 0'i64; timeoutMs = 0): RequestResult {.inline.} =
  client.makeRequest(RequestSpec(
    verb: verb,
    url: url,
    headers: headers,
    body: body,
    requestId: requestId,
    timeoutMs: timeoutMs
  ))

proc get*(client: HttpClient; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); requestId = 0'i64;
    timeoutMs = 0): RequestResult =
  client.makeVerbRequest(hvGet, url, headers, "", requestId, timeoutMs)

proc post*(client: HttpClient; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); body: sink string = "";
    requestId = 0'i64; timeoutMs = 0): RequestResult =
  client.makeVerbRequest(hvPost, url, headers, body, requestId, timeoutMs)

proc put*(client: HttpClient; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); body: sink string = "";
    requestId = 0'i64; timeoutMs = 0): RequestResult =
  client.makeVerbRequest(hvPut, url, headers, body, requestId, timeoutMs)

proc patch*(client: HttpClient; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); body: sink string = "";
    requestId = 0'i64; timeoutMs = 0): RequestResult =
  client.makeVerbRequest(hvPatch, url, headers, body, requestId, timeoutMs)

proc delete*(client: HttpClient; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); requestId = 0'i64;
    timeoutMs = 0): RequestResult =
  client.makeVerbRequest(hvDelete, url, headers, "", requestId, timeoutMs)

proc head*(client: HttpClient; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); requestId = 0'i64;
    timeoutMs = 0): RequestResult =
  client.makeVerbRequest(hvHead, url, headers, "", requestId, timeoutMs)

proc options*(client: HttpClient; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); requestId = 0'i64;
    timeoutMs = 0): RequestResult =
  client.makeVerbRequest(hvOptions, url, headers, "", requestId, timeoutMs)

proc connect*(client: HttpClient; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); requestId = 0'i64;
    timeoutMs = 0): RequestResult =
  client.makeVerbRequest(hvConnect, url, headers, "", requestId, timeoutMs)

proc trace*(client: HttpClient; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); requestId = 0'i64;
    timeoutMs = 0): RequestResult =
  client.makeVerbRequest(hvTrace, url, headers, "", requestId, timeoutMs)

proc len*(batch: RequestBatch): int {.inline.} =
  batch.requests.len

proc `[]`*(batch: RequestBatch; i: int): lent RequestSpec =
  batch.requests[i]

proc addRequest*(batch: var RequestBatch; verb: HttpVerb; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); body: sink string = "";
    requestId = 0'i64; timeoutMs = 0) {.inline.} =
  batch.requests.add(RequestSpec(
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

proc options*(batch: var RequestBatch; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); requestId = 0'i64;
    timeoutMs = 0) =
  batch.addRequest(hvOptions, url, headers, "", requestId, timeoutMs)

proc connect*(batch: var RequestBatch; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); requestId = 0'i64;
    timeoutMs = 0) =
  batch.addRequest(hvConnect, url, headers, "", requestId, timeoutMs)

proc trace*(batch: var RequestBatch; url: sink string;
    headers: sink HttpHeaders = emptyHttpHeaders(); requestId = 0'i64;
    timeoutMs = 0) =
  batch.addRequest(hvTrace, url, headers, "", requestId, timeoutMs)
