import std/strutils
import std/parseutils

type
  HttpHeader* = tuple[name: string, value: string]
  HttpHeaders* = seq[HttpHeader]

proc emptyHttpHeaders*(): HttpHeaders =
  @[]

proc parseHeaders*(raw: string): HttpHeaders =
  result = @[]
  var pos = 0
  while pos < raw.len:
    var line = ""
    pos += parseUntil(raw, line, "\r\n", pos)
    pos += skip(raw, "\r\n", pos)
    var lp = 0
    lp += skipWhitespace(line, lp)
    var ep = line.len
    while ep > lp and line[ep - 1] in Whitespace:
      dec ep
    if lp >= ep:
      discard
    elif line.startsWith("HTTP/"):
      result.setLen(0)
    else:
      let colonPos = line.find(':', lp)
      if colonPos < 0 or colonPos >= ep:
        # No colon found in the trimmed range — whole thing is the name
        result.add((line.substr(lp, ep - 1), ""))
      elif colonPos == lp:
        # Colon at start — no name, value is everything after colon
        var vp = colonPos + 1
        vp += skipWhitespace(line, vp)
        var ve = ep
        while ve > vp and line[ve - 1] in Whitespace:
          dec ve
        result.add(("", if vp >= ve: "" else: line.substr(vp, ve - 1)))
      else:
        var ne = colonPos
        while ne > lp and line[ne - 1] in Whitespace:
          dec ne
        let name = line.substr(lp, ne - 1)
        var vp = colonPos + 1
        vp += skipWhitespace(line, vp)
        var ve = ep
        while ve > vp and line[ve - 1] in Whitespace:
          dec ve
        let value = if vp >= ve: "" else: line.substr(vp, ve - 1)
        result.add((name, value))

proc contains*(headers: HttpHeaders; key: string): bool =
  ## Checks if there is at least one header for the key. Not case sensitive.
  for (k, _) in headers:
    if cmpIgnoreCase(k, key) == 0:
      return true

proc `[]`*(headers: HttpHeaders; key: string): string =
  ## Returns the first header value for the key. Not case sensitive.
  for (k, v) in headers:
    if cmpIgnoreCase(k, key) == 0:
      return v

proc `[]=`*(headers: var HttpHeaders; key, value: string) =
  ## Adds a new header if the key is not already present. If the key is already
  ## present this overrides the first header value for the key.
  ## Not case sensitive.
  for i, (k, _) in headers:
    if cmpIgnoreCase(k, key) == 0:
      var updated = headers[i]
      updated.value = value
      headers[i] = updated
      return
  headers.add((key, value))
