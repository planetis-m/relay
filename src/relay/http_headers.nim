import std/[strutils, parseutils]

type
  HttpHeader* = tuple[name: string, value: string]
  HttpHeaders* = seq[HttpHeader]

proc emptyHttpHeaders*(): HttpHeaders =
  result = @[]

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
  for i in 0 ..< headers.len:
    if cmpIgnoreCase(headers[i].name, key) == 0:
      headers[i].value = value
      return
  headers.add((key, value))

func trimRight(s: string, start, stop: int): int =
  result = stop
  while result > start and s[result - 1] in Whitespace:
    dec result

func parseHeaders*(raw: string): HttpHeaders =
  result = @[]
  var pos = 0
  while pos < raw.len:
    var line = ""
    pos += parseUntil(raw, line, "\r\n", pos)
    pos += skip(raw, "\r\n", pos)
    var lp = 0
    lp += skipWhitespace(line, lp)
    let ep = trimRight(line, lp, line.len)
    if lp >= ep:
      discard
    elif line.startsWith("HTTP/"):
      result.setLen(0)
    else:
      let colonPos = line.find(':', lp)
      var name: string
      var vp: int
      if colonPos < 0 or colonPos >= ep:
        name = line.substr(lp, ep - 1)
        vp = ep  # no value
      else:
        let ne = trimRight(line, lp, colonPos)
        name = if lp >= ne: "" else: line.substr(lp, ne - 1)
        vp = colonPos + 1
        vp += skipWhitespace(line, vp)
      let ve = trimRight(line, vp, ep)
      let value = if vp >= ve: "" else: line.substr(vp, ve - 1)
      result.add((name, value))
