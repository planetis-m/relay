type
  HttpCode* = distinct range[0 .. 599]

const
  Http100* = HttpCode(100)
  Http101* = HttpCode(101)
  Http102* = HttpCode(102)
  Http103* = HttpCode(103)
  Http200* = HttpCode(200)
  Http201* = HttpCode(201)
  Http202* = HttpCode(202)
  Http203* = HttpCode(203)
  Http204* = HttpCode(204)
  Http205* = HttpCode(205)
  Http206* = HttpCode(206)
  Http207* = HttpCode(207)
  Http208* = HttpCode(208)
  Http226* = HttpCode(226)
  Http300* = HttpCode(300)
  Http301* = HttpCode(301)
  Http302* = HttpCode(302)
  Http303* = HttpCode(303)
  Http304* = HttpCode(304)
  Http305* = HttpCode(305)
  Http307* = HttpCode(307)
  Http308* = HttpCode(308)
  Http400* = HttpCode(400)
  Http401* = HttpCode(401)
  Http402* = HttpCode(402)
  Http403* = HttpCode(403)
  Http404* = HttpCode(404)
  Http405* = HttpCode(405)
  Http406* = HttpCode(406)
  Http407* = HttpCode(407)
  Http408* = HttpCode(408)
  Http409* = HttpCode(409)
  Http410* = HttpCode(410)
  Http411* = HttpCode(411)
  Http412* = HttpCode(412)
  Http413* = HttpCode(413)
  Http414* = HttpCode(414)
  Http415* = HttpCode(415)
  Http416* = HttpCode(416)
  Http417* = HttpCode(417)
  Http418* = HttpCode(418)
  Http421* = HttpCode(421)
  Http422* = HttpCode(422)
  Http423* = HttpCode(423)
  Http424* = HttpCode(424)
  Http425* = HttpCode(425)
  Http426* = HttpCode(426)
  Http428* = HttpCode(428)
  Http429* = HttpCode(429)
  Http431* = HttpCode(431)
  Http451* = HttpCode(451)
  Http500* = HttpCode(500)
  Http501* = HttpCode(501)
  Http502* = HttpCode(502)
  Http503* = HttpCode(503)
  Http504* = HttpCode(504)
  Http505* = HttpCode(505)
  Http506* = HttpCode(506)
  Http507* = HttpCode(507)
  Http508* = HttpCode(508)
  Http510* = HttpCode(510)
  Http511* = HttpCode(511)

func `==`*(a, b: HttpCode): bool {.borrow.}
func `<`*(a, b: HttpCode): bool {.borrow.}
func `<=`*(a, b: HttpCode): bool {.borrow.}

func is1xx*(code: HttpCode): bool {.inline.} =
  code >= Http100 and code < Http200

func is2xx*(code: HttpCode): bool {.inline.} =
  code >= Http200 and code < Http300

func is3xx*(code: HttpCode): bool {.inline.} =
  code >= Http300 and code < Http400

func is4xx*(code: HttpCode): bool {.inline.} =
  code >= Http400 and code < Http500

func is5xx*(code: HttpCode): bool {.inline.} =
  code >= Http500

func `$`*(code: HttpCode): string =
  ## Returns the code and reason phrase, e.g. "404 Not Found", or the bare
  ## code for unassigned values.
  case code
  of Http100: "100 Continue"
  of Http101: "101 Switching Protocols"
  of Http102: "102 Processing"
  of Http103: "103 Early Hints"
  of Http200: "200 OK"
  of Http201: "201 Created"
  of Http202: "202 Accepted"
  of Http203: "203 Non-Authoritative Information"
  of Http204: "204 No Content"
  of Http205: "205 Reset Content"
  of Http206: "206 Partial Content"
  of Http207: "207 Multi-Status"
  of Http208: "208 Already Reported"
  of Http226: "226 IM Used"
  of Http300: "300 Multiple Choices"
  of Http301: "301 Moved Permanently"
  of Http302: "302 Found"
  of Http303: "303 See Other"
  of Http304: "304 Not Modified"
  of Http305: "305 Use Proxy"
  of Http307: "307 Temporary Redirect"
  of Http308: "308 Permanent Redirect"
  of Http400: "400 Bad Request"
  of Http401: "401 Unauthorized"
  of Http402: "402 Payment Required"
  of Http403: "403 Forbidden"
  of Http404: "404 Not Found"
  of Http405: "405 Method Not Allowed"
  of Http406: "406 Not Acceptable"
  of Http407: "407 Proxy Authentication Required"
  of Http408: "408 Request Timeout"
  of Http409: "409 Conflict"
  of Http410: "410 Gone"
  of Http411: "411 Length Required"
  of Http412: "412 Precondition Failed"
  of Http413: "413 Payload Too Large"
  of Http414: "414 URI Too Long"
  of Http415: "415 Unsupported Media Type"
  of Http416: "416 Range Not Satisfiable"
  of Http417: "417 Expectation Failed"
  of Http418: "418 I'm a Teapot"
  of Http421: "421 Misdirected Request"
  of Http422: "422 Unprocessable Entity"
  of Http423: "423 Locked"
  of Http424: "424 Failed Dependency"
  of Http425: "425 Too Early"
  of Http426: "426 Upgrade Required"
  of Http428: "428 Precondition Required"
  of Http429: "429 Too Many Requests"
  of Http431: "431 Request Header Fields Too Large"
  of Http451: "451 Unavailable For Legal Reasons"
  of Http500: "500 Internal Server Error"
  of Http501: "501 Not Implemented"
  of Http502: "502 Bad Gateway"
  of Http503: "503 Service Unavailable"
  of Http504: "504 Gateway Timeout"
  of Http505: "505 HTTP Version Not Supported"
  of Http506: "506 Variant Also Negotiates"
  of Http507: "507 Insufficient Storage"
  of Http508: "508 Loop Detected"
  of Http510: "510 Not Extended"
  of Http511: "511 Network Authentication Required"
  else:
    $int(code)
