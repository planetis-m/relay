## HTTP request worker, batching and completion-order results.
import std/[deques, locks, tables]
import ./bindings/curl
import ./[http_headers, http_query, http_status, retry, curl_wrap, transport_errors]

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
    spec: RequestSpec
    responseBody: string
    responseHeadersRaw: string
    easy: Easy
    curlHeaders: Slist

  ClientState = enum
    csRunning, csStopping, csAborting, csStopped

  HttpClientObj = object
    lock: Lock
    wakeCond: Cond
    resultCond: Cond
    thread: Thread[ptr HttpClientObj] # break cycle
    state: ClientState
    closed: bool # Owner-only: worker joined and synchronization released.
    defaultTimeoutMs: int
    maxRedirects: int
    multi: Multi
    availableEasy: seq[Easy]
    queue: Deque[RequestWrap]
    inFlight: Table[pointer, RequestWrap]
    readyResults: Deque[RequestResult]
    outstanding: int # Accepted requests, including results awaiting consumption.
  HttpClient* = ref HttpClientObj
    ## HTTP request worker with shared lifetime and completion-order results.

proc appendWriteCb(buffer: ptr char; size, nitems: csize_t; userdata: pointer): csize_t {.cdecl.} =
  let total = int(size * nitems)
  if total <= 0:
    result = 0
  else:
    let destination = cast[ptr string](userdata)
    let start = destination[].len
    destination[].setLen(start + total)
    copyMem(addr destination[][start], buffer, total)
    result = csize_t(total)

proc newResponse(request: RequestWrap): Response {.inline.} =
  Response(
    code: HttpCode(0),
    url: request.spec.url,
    headers: @[],
    body: "",
    request: RequestInfo(
      verb: request.spec.verb,
      url: move request.spec.url,
      requestId: request.spec.requestId
    )
  )

proc storeCompletionLocked(client: var HttpClientObj; item: sink RequestResult) =
  client.readyResults.addLast(item)
  signal(client.resultCond)

proc configureEasy(client: HttpClientObj; request: RequestWrap; easy: var Easy) =
  easy.reset()
  easy.setUrl(request.spec.url)
  easy.setHttpVersion2Tls()

  easy.setMethod($request.spec.verb)
  easy.setNoBody(request.spec.verb == hvHead)
  if request.spec.body.len > 0:
    easy.setRequestBody(request.spec.body)

  var headerList = Slist()
  for header in request.spec.headers:
    headerList.addHeader(header.name & ": " & header.value)
  request.curlHeaders = headerList
  easy.setHeaders(request.curlHeaders)

  easy.setWriteCallback(appendWriteCb, cast[pointer](addr request.responseBody))
  easy.setHeaderCallback(appendWriteCb, cast[pointer](addr request.responseHeadersRaw))
  easy.setTimeoutMs(if request.spec.timeoutMs > 0: request.spec.timeoutMs
    else: client.defaultTimeoutMs)
  easy.setConnectTimeoutMs(DefaultConnectTimeoutMs)
  easy.setSslVerify(true, true)
  easy.setAcceptEncoding("gzip, deflate")
  easy.setFollowRedirects(true, client.maxRedirects)

proc completionFromCurl(client: var HttpClientObj; request: RequestWrap;
    curlCode: CURLcode): RequestResult =
  result = (newResponse(request), noTransportError())
  try:
    client.multi.removeHandle(request.easy)
    if curlCode != CURLE_OK:
      result.error = newTransportError(classifyTransportError(curlCode),
        "curl transfer failed code=" & $int(curlCode), int(curlCode))
    else:
      result.response.code = HttpCode(request.easy.responseCode())
      let effective = request.easy.effectiveUrl()
      if effective.len > 0:
        result.response.url = effective
      result.response.headers = parseHeaders(request.responseHeadersRaw)
      result.response.body = move request.responseBody
  except CatchableError:
    result.error = newTransportError(teInternal, getCurrentExceptionMsg())

proc flushFailedLocked(client: var HttpClientObj; error: TransportError) =
  while client.queue.len > 0:
    let queued = client.queue.popFirst()
    client.storeCompletionLocked((newResponse(queued), error))

  for req in values(client.inFlight):
    try:
      client.multi.removeHandle(req.easy)
    except IOError:
      discard
    client.availableEasy.add(move req.easy)
    client.storeCompletionLocked((newResponse(req), error))
  client.inFlight.clear()

proc processDoneMessages(client: var HttpClientObj) =
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
        let completion = completionFromCurl(client, request, msg.data.result)
        acquire(client.lock)
        client.availableEasy.add(move request.easy)
        client.storeCompletionLocked(completion)
        release(client.lock)

proc dispatchQueuedRequests(client: var HttpClientObj) =
  var done = false
  while not done:
    var request: RequestWrap
    var easy: Easy
    acquire(client.lock)
    if client.state == csAborting or client.availableEasy.len == 0 or
        client.queue.len == 0:
      done = true
    else:
      request = client.queue.popFirst()
      easy = client.availableEasy.pop()
    release(client.lock)

    if not done:
      request.easy = move easy
      var error: TransportError
      try:
        configureEasy(client, request, request.easy)
        client.multi.addHandle(request.easy)
      except CatchableError:
        error = newTransportError(teInternal, getCurrentExceptionMsg())

      acquire(client.lock)
      if error.kind == teNone:
        client.inFlight[handleKey(request.easy)] = request
      else:
        client.availableEasy.add(move request.easy)
        client.storeCompletionLocked((newResponse(request), error))
      release(client.lock)

proc waitForWorkOrClose(client: var HttpClientObj): bool =
  result = true
  acquire(client.lock)
  while client.state == csRunning and
      client.queue.len == 0 and client.inFlight.len == 0:
    wait(client.wakeCond, client.lock)

  if client.state == csAborting:
    result = false
  elif client.state == csStopping and client.queue.len == 0 and client.inFlight.len == 0:
    result = false
  release(client.lock)

proc workerMain(client: ptr HttpClientObj) {.thread, raises: [].} =
  try:
    while true:
      dispatchQueuedRequests(client[])

      acquire(client.lock)
      let hasInflight = client.inFlight.len > 0
      let shouldAbort = client.state == csAborting
      release(client.lock)

      if shouldAbort:
        acquire(client.lock)
        client[].flushFailedLocked(newTransportError(teCanceled, "Canceled in abort"))
        release(client.lock)
        break

      if hasInflight:
        let running = client.multi.perform()
        processDoneMessages(client[])
        acquire(client.lock)
        let shouldPoll = running > 0 and client.state != csAborting and
          (client.queue.len == 0 or client.availableEasy.len == 0)
        release(client.lock)
        if shouldPoll: discard client.multi.poll(MultiWaitMaxMs)
      elif not waitForWorkOrClose(client[]):
        break
  except IOError:
    let error = newTransportError(teInternal, getCurrentExceptionMsg())
    acquire(client.lock)
    client.state = csAborting
    client[].flushFailedLocked(error)
    release(client.lock)

  acquire(client.lock)
  client.state = csStopped
  broadcast(client.resultCond)
  release(client.lock)

proc newHttpClient*(maxInFlight = 16; defaultTimeoutMs = 60_000;
    maxRedirects = 10): HttpClient =
  ## Call close or abort before releasing the client.
  let client = HttpClient(defaultTimeoutMs: max(1, defaultTimeoutMs),
    maxRedirects: max(0, maxRedirects), outstanding: 0)
  initCurl()
  initLock(client.lock)
  initCond(client.wakeCond)
  initCond(client.resultCond)
  try:
    client.multi = initMulti()
    for _ in 0..<max(1, maxInFlight):
      client.availableEasy.add(initEasy())
    createThread(client.thread, workerMain, addr client[])
  except Exception:
    reset(client.availableEasy)
    reset(client.multi)
    cleanupCurl()
    deinitCond(client.resultCond)
    deinitCond(client.wakeCond)
    deinitLock(client.lock)
    raise
  result = client

proc shutdown(client: var HttpClientObj; aborting: static[bool]) =
  if not client.closed:
    acquire(client.lock)
    if client.state in {csRunning, csStopping}:
      when aborting:
        client.state = csAborting
      else:
        client.state = csStopping
    signal(client.wakeCond)
    client.multi.wakeup()
    release(client.lock)
    joinThread(client.thread)
    reset(client.availableEasy)
    reset(client.queue)
    reset(client.inFlight)
    reset(client.readyResults)
    client.outstanding = 0
    reset(client.multi)
    cleanupCurl()
    deinitCond(client.resultCond)
    deinitCond(client.wakeCond)
    deinitLock(client.lock)
    client.closed = true

proc close*(client: HttpClient) =
  if client != nil: client[].shutdown(false)

proc abort*(client: HttpClient) =
  if client != nil: client[].shutdown(true)

proc hasRequests*(client: HttpClient): bool =
  acquire(client.lock)
  result = client.outstanding > client.readyResults.len
  release(client.lock)

proc numInFlight*(client: HttpClient): int =
  ## Requests being configured, transferred or finalized; excludes queued work and ready results.
  acquire(client.lock)
  result = client.outstanding - client.readyResults.len - client.queue.len
  release(client.lock)

proc queueLen*(client: HttpClient): int =
  acquire(client.lock)
  result = client.queue.len
  release(client.lock)

proc clearQueue*(client: HttpClient) =
  acquire(client.lock)
  while client.queue.len > 0:
    let queued = client.queue.popFirst()
    client[].storeCompletionLocked(
      (newResponse(queued), newTransportError(teCanceled, "Canceled in clearQueue")))
  release(client.lock)

proc clientIsBusy(client: HttpClient): bool =
  acquire(client.lock)
  result = client.outstanding != 0
  release(client.lock)

proc startRequests*(client: HttpClient; batch: var RequestBatch) =
  assert not client.closed, "HTTP client is closed"
  acquire(client.lock)
  try:
    if client.state != csRunning:
      raise newException(IOError, "HTTP worker stopped")

    for request in batch.requests.mitems:
      client.queue.addLast(RequestWrap(
        spec: move request,
        responseBody: "",
        responseHeadersRaw: "",
        easy: default(Easy)
      ))
      inc client.outstanding
    batch.requests.setLen(0)

    signal(client.wakeCond)
    client.multi.wakeup()
  finally:
    release(client.lock)

proc startRequest*(client: HttpClient; request: sink RequestSpec) =
  assert not client.closed, "HTTP client is closed"
  acquire(client.lock)
  try:
    if client.state != csRunning:
      raise newException(IOError, "HTTP worker stopped")

    client.queue.addLast(RequestWrap(
      spec: request,
      responseBody: "",
      responseHeadersRaw: "",
      easy: default(Easy)
    ))
    inc client.outstanding

    signal(client.wakeCond)
    client.multi.wakeup()
  finally:
    release(client.lock)

proc waitForResult*(client: HttpClient; outResult: var RequestResult): bool =
  acquire(client.lock)
  while client.readyResults.len == 0 and
      client.state in {csRunning, csStopping, csAborting}:
    wait(client.resultCond, client.lock)

  if client.readyResults.len > 0:
    outResult = client.readyResults.popFirst()
    dec client.outstanding
    result = true
  else:
    result = false
  release(client.lock)

proc pollForResult*(client: HttpClient; outResult: var RequestResult): bool =
  acquire(client.lock)
  if client.readyResults.len > 0:
    outResult = client.readyResults.popFirst()
    dec client.outstanding
    result = true
  else:
    result = false
  release(client.lock)

proc makeRequests*(client: HttpClient; batch: var RequestBatch): RequestResults =
  assert not client.closed, "HTTP client is closed"
  assert not client.clientIsBusy(), "makeRequests requires an idle client"

  let expected = batch.requests.len
  client.startRequests(batch)
  result = @[]
  for _ in 0..<expected:
    var item: RequestResult
    if not client.waitForResult(item):
      raise newException(IOError, "client stopped before all responses arrived")
    result.add(item)

proc makeRequest*(client: HttpClient; request: sink RequestSpec): RequestResult =
  result = (Response(), noTransportError())
  assert not client.closed, "HTTP client is closed"
  assert not client.clientIsBusy(), "makeRequest requires an idle client"

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
