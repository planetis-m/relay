import relay

proc main =
  # Standard multi-header response
  let h1 = parseHeaders("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 42\r\nX-Custom: hello\r\n\r\n")
  doAssert h1.len == 3
  doAssert h1[0] == ("Content-Type", "text/html")
  doAssert h1[1] == ("Content-Length", "42")
  doAssert h1[2] == ("X-Custom", "hello")

  # Redirect: two HTTP status lines, first set of headers is discarded
  let h2 = parseHeaders("HTTP/1.1 301 Moved\r\nLocation: /new\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n")
  doAssert h2.len == 1
  doAssert h2[0] == ("Content-Type", "text/plain")

  # Empty input -> empty result
  let h3 = parseHeaders("")
  doAssert h3.len == 0

  # Header with no colon (name only)
  let h4 = parseHeaders("NoColon\r\n")
  doAssert h4.len == 1
  doAssert h4[0] == ("NoColon", "")

  # Header with empty name (colon at position 0)
  let h5 = parseHeaders(": somevalue\r\n")
  doAssert h5.len == 1
  doAssert h5[0] == ("", "somevalue")

  # Header value with extra spaces (should be trimmed)
  let h6 = parseHeaders("Content-Type:   text/html   \r\n")
  doAssert h6.len == 1
  doAssert h6[0] == ("Content-Type", "text/html")

  # Header name with leading/trailing spaces
  let h7 = parseHeaders("  X-Header  : value\r\n")
  doAssert h7.len == 1
  doAssert h7[0] == ("X-Header", "value")

when isMainModule:
  main()
