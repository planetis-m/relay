# Minimal libcurl bindings used by Relay.

type
  CURL* = distinct pointer
  CURLM* = distinct pointer
  CURLcode* = cint
  CURLMcode* = cint
  CURLoption* = cint
  CURLINFO* = cint

  curl_slist* {.importc: "struct curl_slist", header: "<curl/curl.h>",
      incompleteStruct.} = object

  CurlMsgType* = enum
    CURLMSG_NONE = 0,
    CURLMSG_DONE = 1,
    CURLMSG_LAST = 2

  CURLMsgData* {.union.} = object
    whatever*: pointer
    result*: CURLcode

  CURLMsg* {.importc: "CURLMsg", header: "<curl/multi.h>", bycopy.} = object
    msg*: CurlMsgType
    easy_handle*: CURL
    data*: CURLMsgData

  curl_write_callback* = proc(buffer: ptr char; size, nitems: csize_t;
      outstream: pointer): csize_t {.cdecl.}

const
  CURLE_OK* = CURLcode(0)
  CURLE_COULDNT_RESOLVE_PROXY* = CURLcode(5)
  CURLE_COULDNT_RESOLVE_HOST* = CURLcode(6)
  CURLE_COULDNT_CONNECT* = CURLcode(7)
  CURLE_OPERATION_TIMEDOUT* = CURLcode(28)
  CURLE_SSL_CONNECT_ERROR* = CURLcode(35)
  CURLE_ABORTED_BY_CALLBACK* = CURLcode(42)
  CURLE_PEER_FAILED_VERIFICATION* = CURLcode(60)

  CURLM_OK* = CURLMcode(0)

  CURLOPTTYPE_LONG* = 0
  CURLOPTTYPE_OBJECTPOINT* = 10000
  CURLOPTTYPE_FUNCTIONPOINT* = 20000

  CURLOPT_WRITEDATA* = CURLoption(CURLOPTTYPE_OBJECTPOINT + 1)
  CURLOPT_URL* = CURLoption(CURLOPTTYPE_OBJECTPOINT + 2)
  CURLOPT_ERRORBUFFER* = CURLoption(CURLOPTTYPE_OBJECTPOINT + 10)
  CURLOPT_WRITEFUNCTION* = CURLoption(CURLOPTTYPE_FUNCTIONPOINT + 11)
  CURLOPT_POSTFIELDS* = CURLoption(CURLOPTTYPE_OBJECTPOINT + 15)
  CURLOPT_HTTPHEADER* = CURLoption(CURLOPTTYPE_OBJECTPOINT + 23)
  CURLOPT_HEADERDATA* = CURLoption(CURLOPTTYPE_OBJECTPOINT + 29)
  CURLOPT_CUSTOMREQUEST* = CURLoption(CURLOPTTYPE_OBJECTPOINT + 36)
  CURLOPT_NOBODY* = CURLoption(CURLOPTTYPE_LONG + 44)
  CURLOPT_POST* = CURLoption(CURLOPTTYPE_LONG + 47)
  CURLOPT_FOLLOWLOCATION* = CURLoption(CURLOPTTYPE_LONG + 52)
  CURLOPT_POSTFIELDSIZE* = CURLoption(CURLOPTTYPE_LONG + 60)
  CURLOPT_SSL_VERIFYPEER* = CURLoption(CURLOPTTYPE_LONG + 64)
  CURLOPT_MAXREDIRS* = CURLoption(CURLOPTTYPE_LONG + 68)
  CURLOPT_HEADERFUNCTION* = CURLoption(CURLOPTTYPE_FUNCTIONPOINT + 79)
  CURLOPT_SSL_VERIFYHOST* = CURLoption(CURLOPTTYPE_LONG + 81)
  CURLOPT_NOSIGNAL* = CURLoption(CURLOPTTYPE_LONG + 99)
  CURLOPT_ACCEPT_ENCODING* = CURLoption(CURLOPTTYPE_OBJECTPOINT + 102)
  CURLOPT_PRIVATE* = CURLoption(CURLOPTTYPE_OBJECTPOINT + 103)
  CURLOPT_TIMEOUT_MS* = CURLoption(CURLOPTTYPE_LONG + 155)
  CURLOPT_CONNECTTIMEOUT_MS* = CURLoption(CURLOPTTYPE_LONG + 156)

  CURLINFO_LONG* = 0x200000
  CURLINFO_STRING* = 0x100000
  CURLINFO_EFFECTIVE_URL* = CURLINFO(CURLINFO_STRING + 1)
  CURLINFO_RESPONSE_CODE* = CURLINFO(CURLINFO_LONG + 2)
  CURLINFO_PRIVATE* = CURLINFO(CURLINFO_STRING + 21)

{.push importc, callconv: cdecl, header: "<curl/curl.h>".}

proc curl_easy_init*(): CURL
proc curl_easy_cleanup*(curl: CURL)
proc curl_easy_reset*(curl: CURL)
proc curl_easy_setopt*(curl: CURL, option: CURLoption): CURLcode {.varargs.}
proc curl_easy_getinfo*(curl: CURL, info: CURLINFO): CURLcode {.varargs.}
proc curl_easy_strerror*(code: CURLcode): cstring

proc curl_slist_append*(list: ptr curl_slist, data: cstring): ptr curl_slist
proc curl_slist_free_all*(list: ptr curl_slist)

proc curl_global_init*(flags: culong): CURLcode
proc curl_global_cleanup*()

{.pop.}

{.push importc, callconv: cdecl, header: "<curl/multi.h>".}

proc curl_multi_init*(): CURLM
proc curl_multi_add_handle*(multiHandle: CURLM; easyHandle: CURL): CURLMcode
proc curl_multi_remove_handle*(multiHandle: CURLM; easyHandle: CURL): CURLMcode
proc curl_multi_perform*(multiHandle: CURLM; runningHandles: ptr cint): CURLMcode
proc curl_multi_poll*(multiHandle: CURLM; extraFds: pointer; extraNfds: cuint;
    timeoutMs: cint; numfds: ptr cint): CURLMcode
proc curl_multi_info_read*(multiHandle: CURLM; msgsInQueue: ptr cint): ptr CURLMsg
proc curl_multi_cleanup*(multiHandle: CURLM): CURLMcode
proc curl_multi_strerror*(code: CURLMcode): cstring

{.pop.}
