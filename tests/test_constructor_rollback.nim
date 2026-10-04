## Linux linker faults exercise ownership before a worker starts.
when defined(linux):
  import std/assertions
  import relay/[http, websocket]

  {.passL: "-Wl,--wrap=curl_global_init,--wrap=curl_global_cleanup,--wrap=curl_multi_init,--wrap=curl_multi_cleanup,--wrap=curl_multi_setopt,--wrap=curl_easy_init,--wrap=curl_easy_cleanup,--wrap=curl_easy_setopt,--wrap=pthread_create".}
  {.emit: """
#include <curl/curl.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>

static int fault, easy_calls;
static int globals, multis, easies;
static void set_fault(int value) { fault = value; easy_calls = 0; }
static int global_balance(void) { return globals; }
static int multi_balance(void) { return multis; }
static int easy_balance(void) { return easies; }

CURLcode __real_curl_global_init(long flags);
void __real_curl_global_cleanup(void);
CURLM *__real_curl_multi_init(void);
CURLMcode __real_curl_multi_cleanup(CURLM *multi);
CURLMcode __real_curl_multi_setopt(CURLM *multi, CURLMoption option, ...);
CURL *__real_curl_easy_init(void);
void __real_curl_easy_cleanup(CURL *easy);
CURLcode __real_curl_easy_setopt(CURL *easy, CURLoption option, ...);
int __real_pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                         void *(*entry)(void *), void *arg);

CURLcode __wrap_curl_global_init(long flags) {
  if(fault == 1) return CURLE_FAILED_INIT;
  CURLcode code = __real_curl_global_init(flags);
  if(code == CURLE_OK) ++globals;
  return code;
}
void __wrap_curl_global_cleanup(void) {
  --globals;
  __real_curl_global_cleanup();
}
CURLM *__wrap_curl_multi_init(void) {
  if(fault == 2) return NULL;
  CURLM *multi = __real_curl_multi_init();
  if(multi) ++multis;
  return multi;
}
CURLMcode __wrap_curl_multi_cleanup(CURLM *multi) {
  --multis;
  return __real_curl_multi_cleanup(multi);
}
CURLMcode __wrap_curl_multi_setopt(CURLM *multi, CURLMoption option, ...) {
  if(fault == 3) return CURLM_UNKNOWN_OPTION;
  va_list args;
  va_start(args, option);
  long value = va_arg(args, long); /* Constructors set only PIPELINING. */
  va_end(args);
  return __real_curl_multi_setopt(multi, option, value);
}
CURL *__wrap_curl_easy_init(void) {
  if(fault == 4 && ++easy_calls == 2) return NULL;
  CURL *easy = __real_curl_easy_init();
  if(easy) ++easies;
  return easy;
}
void __wrap_curl_easy_cleanup(CURL *easy) {
  --easies;
  __real_curl_easy_cleanup(easy);
}
CURLcode __wrap_curl_easy_setopt(CURL *easy, CURLoption option, ...) {
  if(fault == 5 && option == CURLOPT_NOSIGNAL) return CURLE_UNKNOWN_OPTION;
  va_list args;
  va_start(args, option);
  CURLcode code;
  if(option == CURLOPT_ERRORBUFFER) {
    char *value = va_arg(args, char *);
    code = __real_curl_easy_setopt(easy, option, value);
  } else { /* Constructors otherwise set only NOSIGNAL. */
    long value = va_arg(args, long);
    code = __real_curl_easy_setopt(easy, option, value);
  }
  va_end(args);
  return code;
}
int __wrap_pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                         void *(*entry)(void *), void *arg) {
  if(fault == 6) return EAGAIN;
  return __real_pthread_create(thread, attr, entry, arg);
}
""".}

  type Fault = enum
    noFault, globalInit, multiInit, multiOption, easyInit, easyOption, threadCreate

  proc setFault(value: cint) {.importc: "set_fault", nodecl.}
  proc globalBalance(): cint {.importc: "global_balance", nodecl.}
  proc multiBalance(): cint {.importc: "multi_balance", nodecl.}
  proc easyBalance(): cint {.importc: "easy_balance", nodecl.}

  proc checkReleased() =
    doAssert globalBalance() == 0
    doAssert multiBalance() == 0
    doAssert easyBalance() == 0

  proc main() =
    # Opt in to the known Nim runtime leak on failed pthread_create.
    # Relay's resource balances still pass; ASan reports allocThreadStorage.
    const lastFault = when defined(threadInitFault): threadCreate else: easyOption
    for fault in globalInit..lastFault:
      setFault(fault.cint)
      if fault == threadCreate:
        doAssertRaises ResourceExhaustedError:
          discard newHttpClient(maxInFlight = 2)
      else:
        doAssertRaises IOError:
          discard newHttpClient(maxInFlight = 2)
      checkReleased()

      if fault notin {easyInit, easyOption}:
        if fault == threadCreate:
          doAssertRaises ResourceExhaustedError:
            discard newWebSocketClient(proxy = "http://proxy.invalid", caInfo = "test.pem")
        else:
          doAssertRaises IOError:
            discard newWebSocketClient(proxy = "http://proxy.invalid", caInfo = "test.pem")
        checkReleased()

    setFault(noFault.cint)
    let http = newHttpClient(maxInFlight = 2)
    http.close()
    http.close()
    let websocket = newWebSocketClient()
    websocket.abort()
    websocket.close()
    checkReleased()
    echo "Constructor rollback contracts passed"

  main()
