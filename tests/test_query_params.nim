import relay/http_query, std/strutils

proc main =
  block empty:
    let q = emptyQueryParams()
    doAssert q.len == 0
    doAssert $q == ""
    doAssert not ("a" in q)

  block set_get:
    var q: QueryParams
    q["q"] = "hello world"
    q["lang"] = "el"
    doAssert q.len == 2
    doAssert q["q"] == "hello world"
    doAssert q["lang"] == "el"
    doAssert q["missing"] == ""
    doAssert "lang" in q
    doAssert "missing" notin q
    doAssert getOrDefault(q, "lang", "en") == "el"
    doAssert getOrDefault(q, "missing", "en") == "en"

  block override_first:
    var q: QueryParams
    q["x"] = "1"
    q["x"] = "2"
    doAssert q.len == 1
    doAssert q["x"] == "2"

  block duplicates:
    var q: QueryParams
    q.add(("tag", "a"))
    q.add(("tag", "b"))
    q.add(("tag", "c"))
    doAssert q.len == 3
    doAssert q["tag"] == "a"
    doAssert getAll(q, "tag") == @["a", "b", "c"]

  block append_query:
    var base: QueryParams
    base["a"] = "1"
    var extra: QueryParams
    extra["b"] = "2"
    base.add(extra)
    doAssert base.len == 2
    doAssert base["b"] == "2"

  block encode:
    doAssert encodeQueryComponent("hello world") == "hello+world"
    doAssert encodeQueryComponent("a&b=c") == "a%26b%3Dc"
    doAssert encodeQueryComponent("plain") == "plain"
    doAssert encodeQueryComponent("") == ""
    doAssert encodeQueryComponent("gr-ου") == "gr-%CE%BF%CF%85"

  block decode:
    doAssert decodeQueryComponent("hello+world") == "hello world"
    doAssert decodeQueryComponent("a%26b%3Dc") == "a&b=c"
    doAssert decodeQueryComponent("plain") == "plain"
    doAssert decodeQueryComponent("%CE%BF%CF%85") == "ου"
    doAssert decodeQueryComponent("") == ""

  block decode_invalid:
    var raised = false
    try:
      discard decodeQueryComponent("%2")
    except ValueError:
      raised = true
    doAssert raised
    raised = false
    try:
      discard decodeQueryComponent("%zz")
    except ValueError:
      raised = true
    doAssert raised

  block dollar_roundtrip:
    var q: QueryParams
    q["q"] = "hello world"
    q["lang"] = "el"
    let s = $q
    doAssert s == "q=hello+world&lang=el"

when isMainModule:
  main()
