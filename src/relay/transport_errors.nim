import ./bindings/curl

type
  TransportErrorKind* = enum
    teNone,
    teTimeout,
    teNetwork,
    teDns,
    teTls,
    teCanceled,
    teProtocol,
    teInternal

  TransportError* = object
    kind*: TransportErrorKind
    message*: string
    curlCode*: int

proc isRetryable*(kind: TransportErrorKind): bool {.inline.} =
  ## Returns true for timeouts, network, DNS, TLS, and internal errors.
  case kind
  of teTimeout, teNetwork, teDns, teTls, teInternal:
    result = true
  of teNone, teCanceled, teProtocol:
    result = false

proc noTransportError*(): TransportError {.inline.} =
  TransportError(kind: teNone, message: "", curlCode: 0)

proc newTransportError*(kind: TransportErrorKind; message: sink string;
    curlCode = 0): TransportError {.inline.} =
  TransportError(kind: kind, message: message, curlCode: curlCode)

proc classifyTransportError*(curlCode: CURLcode): TransportErrorKind {.inline.} =
  case curlCode
  of CURLE_OPERATION_TIMEDOUT:
    teTimeout
  of CURLE_COULDNT_RESOLVE_PROXY, CURLE_COULDNT_RESOLVE_HOST:
    teDns
  of CURLE_SSL_CONNECT_ERROR, CURLE_PEER_FAILED_VERIFICATION:
    teTls
  of CURLE_ABORTED_BY_CALLBACK:
    teCanceled
  else:
    teNetwork
