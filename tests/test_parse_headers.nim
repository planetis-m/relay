import relay/http_headers, std/strutils

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
  
  # No trailing \r\n on the last header
  let h8 = parseHeaders("Content-Type: text/html")
  doAssert h8.len == 1
  doAssert h8[0] == ("Content-Type", "text/html")

  # Value containing colons
  let h9 = parseHeaders("Location: http://example.com:8080/path\r\n")
  doAssert h9.len == 1
  doAssert h9[0] == ("Location", "http://example.com:8080/path")

  # Empty value after colon
  let h10 = parseHeaders("X-Empty:\r\n")
  doAssert h10.len == 1
  doAssert h10[0] == ("X-Empty", "")

  # Duplicate header names
  let h11 = parseHeaders("Set-Cookie: a=1\r\nSet-Cookie: b=2\r\n")
  doAssert h11.len == 2
  doAssert h11[0] == ("Set-Cookie", "a=1")
  doAssert h11[1] == ("Set-Cookie", "b=2")

  # Only a status line (no headers)
  let h12 = parseHeaders("HTTP/1.1 204 No Content\r\n\r\n")
  doAssert h12.len == 0

  # Bare \n line endings (no \r) — strict \r\n parsing, treated as single header
  let h13 = parseHeaders("Content-Type: text/html\nX-Other: val\n")
  doAssert h13.len == 1
  doAssert h13[0] == ("Content-Type", "text/html\nX-Other: val")

  # Blank lines between headers (malformed input) — blank line is skipped, both headers parsed
  let h14 = parseHeaders("A: 1\r\n\r\nB: 2\r\n")
  doAssert h14.len == 2
  doAssert h14[0] == ("A", "1")
  doAssert h14[1] == ("B", "2")

  # Very long header value
  let longVal = 'x'.repeat(8192)
  let h15 = parseHeaders("X-Long: " & longVal & "\r\n")
  doAssert h15.len == 1
  doAssert h15[0] == ("X-Long", longVal)

when isMainModule:
  main()
