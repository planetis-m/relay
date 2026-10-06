## Worker failure completes accepted connects and releases transport resources.
when defined(linux):
  import std/[assertions, monotimes, os, times]
  import relay/websocket

  {.passL: "-Wl,--wrap=curl_multi_perform,--wrap=curl_easy_init,--wrap=curl_easy_cleanup".}
  {.emit: """
#include <curl/curl.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>

static atomic_int fail_on, calls, entered, proceed, easies;
static void set_failure(int value) {
  atomic_store(&calls, 0);
  atomic_store(&entered, 0);
  atomic_store(&proceed, 0);
  atomic_store(&fail_on, value);
}
static int worker_entered(void) { return atomic_load(&entered); }
static void release_worker(void) { atomic_store(&proceed, 1); }
static int easy_balance(void) { return atomic_load(&easies); }
static int websocket_available(void) {
  const curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);
  if(info->version_num < 0x080e00) return 0; /* CURLWS_NOAUTOPONG */
  int ws = 0, wss = 0;
  for(const char *const *protocol = info->protocols; *protocol; ++protocol) {
    if(strcmp(*protocol, "ws") == 0) ws = 1;
    if(strcmp(*protocol, "wss") == 0) wss = 1;
  }
  return ws && wss;
}

CURLMcode __real_curl_multi_perform(CURLM *multi, int *running);
CURL *__real_curl_easy_init(void);
void __real_curl_easy_cleanup(CURL *easy);

CURLMcode __wrap_curl_multi_perform(CURLM *multi, int *running) {
  int call = atomic_fetch_add(&calls, 1) + 1;
  if(call == 1) {
    atomic_store(&entered, 1);
    for(int i = 0; !atomic_load(&proceed); ++i) {
      if(i == 3000) return CURLM_INTERNAL_ERROR;
      usleep(1000);
    }
  }
  if(call == atomic_load(&fail_on)) return CURLM_INTERNAL_ERROR;
  return __real_curl_multi_perform(multi, running);
}
CURL *__wrap_curl_easy_init(void) {
  CURL *easy = __real_curl_easy_init();
  if(easy) atomic_fetch_add(&easies, 1);
  return easy;
}
void __wrap_curl_easy_cleanup(CURL *easy) {
  atomic_fetch_sub(&easies, 1);
  __real_curl_easy_cleanup(easy);
}
""".}

  proc setFailure(call: cint) {.importc: "set_failure", nodecl.}
  proc workerEntered(): cint {.importc: "worker_entered", nodecl.}
  proc releaseWorker() {.importc: "release_worker", nodecl.}
  proc easyBalance(): cint {.importc: "easy_balance", nodecl.}
  proc websocketAvailable(): bool {.importc: "websocket_available", nodecl.}

  for call in [1.cint, 2.cint]:
    if call == 2 and not websocketAvailable():
      echo "Skipping active-handle failure: requires WebSocket-enabled libcurl 8.14+"
      continue
    setFailure(call)
    let client = newWebSocketClient(maxConnections = 2, maxCommands = 2, bypassProxy = true)
    try:
      let deadline = getMonoTime() + initDuration(milliseconds = 1500)
      while workerEntered() == 0 and getMonoTime() < deadline:
        sleep(1)
      doAssert workerEntered() != 0
      let first = client.startConnect("ws://127.0.0.1:1")
      let second = client.startConnect("ws://127.0.0.1:1")
      releaseWorker()
      # Fail before dispatch, or after both native handles have been created.
      for ids in [first, second]:
        var completion: WebSocketResult
        doAssert client.waitForResult(completion)
        doAssert completion.connectionId == ids.connectionId
        doAssert completion.operationId == ids.operationId
        doAssert completion.error.kind == teInternal,
          $completion.error.kind & ": " & completion.error.message
        var event: WebSocketEvent
        doAssert client.waitForEvent(ids.connectionId, event)
        doAssert event.kind == weClosed and event.error.kind == teInternal
      var extra: WebSocketResult
      doAssert not client.waitForResult(extra)
      doAssert easyBalance() == 0
    finally:
      releaseWorker()
      client.close()

  echo "WebSocket worker failure ownership contracts passed"
