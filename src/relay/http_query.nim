import std/[parseutils, strutils]

type
  QueryParam* = tuple[key: string, value: string]
  QueryParams* = seq[QueryParam]

const
  QueryUnreservedChars = {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~'}

proc emptyQueryParams*(): QueryParams =
  result = @[]

proc contains*(query: QueryParams; key: string): bool =
  ## Returns true if there is at least one pair with the given key.
  ## Use `key in query` or `key notin query`.
  for (k, _) in query.items:
    if k == key:
      return true

proc `[]`*(query: QueryParams; key: string): string =
  ## Returns the value of the first pair with the given key, or "" if absent.
  ## Use a for loop over `query.items` to read multiple pairs with the same key.
  for (k, v) in query.items:
    if k == key:
      return v

proc `[]=`*(query: var QueryParams; key, value: string) =
  ## Sets the value for the key, overriding the first existing pair. If the
  ## key is not present, appends a new pair at the end.
  for pair in query.mitems:
    if pair.key == key:
      pair.value = value
      return
  query.add((key, value))

proc add*(query: var QueryParams; other: QueryParams) =
  ## Appends all pairs from `other` without deduplicating keys.
  for (k, v) in other.items:
    query.add((k, v))

proc getOrDefault*(query: QueryParams; key, default: string): string =
  ## Returns the value of the first pair with the given key, or `default`.
  if key in query: query[key] else: default

proc getAll*(query: QueryParams; key: string): seq[string] =
  ## Returns the values of every pair with the given key.
  for (k, v) in query.items:
    if k == key:
      result.add(v)

proc encodeQueryComponent*(s: string): string =
  ## Encodes `s` for use as a query component in x-www-form-urlencoded format.
  ## Spaces become `+`; other non-unreserved bytes become `%XX`.
  result = newStringOfCap(s.len + s.len shr 2)
  for c in s:
    if c == ' ':
      result.add '+'
    elif c in QueryUnreservedChars:
      result.add c
    else:
      result.add '%'
      result.add toHex(ord(c), 2)

proc decodeQueryComponent*(s: string): string =
  ## Decodes `s` from the x-www-form-urlencoded format. Raises `ValueError`
  ## on malformed percent-encoding.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    case s[i]
    of '%':
      if i + 2 >= s.len:
        raise newException(ValueError, "invalid percent-encoding in query component")
      var v: uint8
      if parseHex(s, v, i + 1, 2) == 0:
        raise newException(ValueError, "invalid percent-encoding in query component")
      result.add v.char
      i += 2
    of '+':
      result.add ' '
    else:
      result.add s[i]
    inc i

proc `$`*(query: QueryParams): string =
  ## Serializes to `key=value&key=value` with components percent-encoded.
  result = newStringOfCap(query.len * 8)
  for i, (k, v) in query.pairs:
    if i > 0:
      result.add '&'
    result.add encodeQueryComponent(k)
    result.add '='
    result.add encodeQueryComponent(v)
