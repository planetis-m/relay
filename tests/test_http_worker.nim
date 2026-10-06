## Accepted requests stay visible through dispatch, completion and worker failure.
when defined(linux):
  import std/[algorithm, assertions, monotimes, os, times]
  import relay/http

  {.passL: "-Wl,--wrap=curl_multi_add_handle,--wrap=curl_multi_remove_handle,--wrap=curl_multi_perform,--wrap=curl_multi_poll".}
  {.emit: """
#include <curl/curl.h>
#include <stdatomic.h>
#include <unistd.h>

static atomic_int pause_at, entered, proceed, fail_perform, running, empty_polls;
static void set_pause(int site) {
  atomic_store(&entered, 0);
  atomic_store(&proceed, 0);
  atomic_store(&pause_at, site);
}
static int worker_entered(void) { return atomic_load(&entered); }
static void release_worker(void) { atomic_store(&proceed, 1); }
static void fail_worker(void) { atomic_store(&fail_perform, 1); }
static int empty_poll_count(void) { return atomic_load(&empty_polls); }
static void pause_worker(int site) {
  if(atomic_load(&pause_at) != site) return;
  atomic_store(&entered, 1);
  for(int i = 0; !atomic_load(&proceed); ++i) {
    if(i == 3000) return;
    usleep(1000);
  }
}
CURLMcode __real_curl_multi_add_handle(CURLM *multi, CURL *easy);
CURLMcode __real_curl_multi_remove_handle(CURLM *multi, CURL *easy);
CURLMcode __real_curl_multi_perform(CURLM *multi, int *active);
CURLMcode __real_curl_multi_poll(CURLM *multi, struct curl_waitfd *fds,
                                unsigned int count, int timeout, int *ready);
CURLMcode __wrap_curl_multi_add_handle(CURLM *multi, CURL *easy) {
  pause_worker(1);
  return __real_curl_multi_add_handle(multi, easy);
}
CURLMcode __wrap_curl_multi_remove_handle(CURLM *multi, CURL *easy) {
  pause_worker(2);
  return __real_curl_multi_remove_handle(multi, easy);
}
CURLMcode __wrap_curl_multi_perform(CURLM *multi, int *active) {
  if(atomic_load(&fail_perform)) return CURLM_INTERNAL_ERROR;
  CURLMcode code = __real_curl_multi_perform(multi, active);
  atomic_store(&running, *active);
  return code;
}
CURLMcode __wrap_curl_multi_poll(CURLM *multi, struct curl_waitfd *fds,
                                unsigned int count, int timeout, int *ready) {
  if(timeout > 0 && atomic_load(&running) == 0)
    atomic_fetch_add(&empty_polls, 1);
  return __real_curl_multi_poll(multi, fds, count, timeout, ready);
}
""".}

  proc setPause(site: cint) {.importc: "set_pause", nodecl.}
  proc workerEntered(): bool {.importc: "worker_entered", nodecl.}
  proc releaseWorker() {.importc: "release_worker", nodecl.}
  proc failWorker() {.importc: "fail_worker", nodecl.}
  proc emptyPollCount(): cint {.importc: "empty_poll_count", nodecl.}

  proc submit(client: HttpClient) =
    var batch: RequestBatch
    for id in 1..3:
      batch.get("http://127.0.0.1:1", requestId = id)
    client.startRequests(batch)

  for site in [1.cint, 2.cint]:
    setPause(site)
    let client = newHttpClient(maxInFlight = 1, defaultTimeoutMs = 1000)
    try:
      client.submit()
      let deadline = getMonoTime() + initDuration(milliseconds = 1500)
      while not workerEntered() and getMonoTime() < deadline: sleep(1)
      doAssert workerEntered()
      doAssert client.hasRequests() and client.numInFlight() == 1
      doAssert client.queueLen() == 2
      client.clearQueue()
      var item: RequestResult
      for id in [2'i64, 3'i64]:
        doAssert client.waitForResult(item)
        doAssert item.response.request.requestId == id and item.error.kind == teCanceled
      doAssert client.hasRequests() and client.numInFlight() == 1
      releaseWorker()
      doAssert client.waitForResult(item)
      doAssert item.response.request.requestId == 1 and item.error.kind != teNone
      doAssert not client.hasRequests() and client.numInFlight() == 0
    finally:
      releaseWorker()
      client.close()

  setPause(0)
  failWorker()
  let client = newHttpClient(maxInFlight = 1)
  try:
    client.submit()
    var ids: seq[int64]
    var item: RequestResult
    while client.waitForResult(item):
      doAssert item.error.kind == teInternal
      ids.add(item.response.request.requestId)
    ids.sort()
    doAssert ids == @[1'i64, 2'i64, 3'i64]
    doAssert not client.hasRequests() and client.numInFlight() == 0
  finally:
    client.close()

  doAssert emptyPollCount() == 0, "Completed transfers waited in an empty curl poll"
