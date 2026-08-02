import relay/http_status

proc main =
  doAssert is1xx(Http103)
  doAssert not is1xx(Http200)
  doAssert is2xx(Http200)
  doAssert is2xx(Http204)
  doAssert not is2xx(HttpCode(199))
  doAssert not is2xx(Http300)
  doAssert is3xx(Http301)
  doAssert is4xx(Http404)
  doAssert not is5xx(HttpCode(499))
  doAssert is5xx(Http503)
  doAssert Http404 == HttpCode(404)
  doAssert Http200 == Http200
  doAssert $Http404 == "404 Not Found"
  doAssert $Http200 == "200 OK"
  doAssert $HttpCode(299) == "299"
  doAssert $Http429 == "429 Too Many Requests"

when isMainModule:
  main()
