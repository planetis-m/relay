import std/strutils

type
  HttpHeader* = tuple[name: string, value: string]
  HttpHeaders* = seq[HttpHeader]

proc emptyHttpHeaders*(): HttpHeaders =
  @[]

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
