## Additional libcurl declarations used by relay/websocket.
## Existing handle, option and error types come from Relay's pinned binding.
import std/nativesockets
import ./curl

type
  curl_off_t* {.importc, header: "<curl/curl.h>".} = int64
  curl_version_info_data* {.importc, header: "<curl/curl.h>", incompleteStruct.} = object
    version_num*: cuint
  curl_ws_frame* {.importc: "const struct curl_ws_frame", header: "<curl/curl.h>",
      bycopy.} = object
    age*, flags*: cint
    offset*, bytesleft*: curl_off_t
    len*: csize_t
  curl_waitfd* {.importc: "struct curl_waitfd", header: "<curl/multi.h>",
      bycopy.} = object
    fd*: SocketHandle
    events*, revents*: cshort

const
  CURLE_AGAIN* = CURLcode(81)
  CURLOPT_CAINFO* = CURLoption(CURLOPTTYPE_OBJECTPOINT + 65)
  CURLOPT_PROXY* = CURLoption(CURLOPTTYPE_OBJECTPOINT + 4)
  CURLOPT_CONNECT_ONLY* = CURLoption(CURLOPTTYPE_LONG + 141)
  CURLOPT_WS_OPTIONS* = CURLoption(CURLOPTTYPE_LONG + 320)
  CURLWS_NOAUTOPONG* = 2.clong
  CURLINFO_ACTIVESOCKET* = CURLINFO(0x500000 + 44)
  CURLWS_TEXT* = 1.cuint
  CURLWS_BINARY* = 2.cuint
  CURLWS_CONT* = 4.cuint
  CURLWS_CLOSE* = 8.cuint
  CURLWS_PING* = 16.cuint
  CURLWS_OFFSET* = 32.cuint
  CURLWS_PONG* = 64.cuint
  CURL_WAIT_POLLIN* = 1.cshort
  CURL_WAIT_POLLOUT* = 4.cshort
  CURLVERSION_FIRST* = 0.cint

{.push importc, callconv: cdecl, header: "<curl/curl.h>".}
proc curl_version_info*(age: cint): ptr curl_version_info_data
proc curl_ws_recv*(curl: CURL; buffer: pointer; buflen: csize_t; received: ptr csize_t;
    meta: ptr ptr curl_ws_frame): CURLcode
proc curl_ws_send*(curl: CURL; buffer: pointer; buflen: csize_t; sent: ptr csize_t;
    fragsize: curl_off_t; flags: cuint): CURLcode
{.pop.}

proc curl_multi_wakeup*(multi: CURLM): CURLMcode {.importc, cdecl, header: "<curl/multi.h>".}
