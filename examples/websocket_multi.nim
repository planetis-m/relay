## Send to multiple echo servers concurrently with one WebSocketClient.
import std/os
import relay/websocket

proc main() =
  let endpoints = commandLineParams()
  if endpoints.len == 0:
    echo "Usage: websocket_multi <ws:// or wss:// URL> [more URLs...]"
    return

  let client = newWebSocketClient()
  try:
    var connectOps: seq[OperationId] = @[]
    var connections: seq[ConnectionId] = @[]
    for endpoint in endpoints:
      let started = client.startConnect(endpoint)
      connectOps.add(started.operationId)
      connections.add(started.connectionId)

    var pending = endpoints.len
    var remaining = endpoints.len
    while pending > 0 or remaining > 0:
      # Operation IDs distinguish connect completions from send completions.
      var completion: WebSocketResult
      while client.pollForResult(completion):
        dec pending
        if completion.operationId in connectOps and completion.error.kind == teNone:
          discard client.startSend(completion.connectionId,
            WebSocketMessage(kind: wmText, data: "hello"))
          inc pending

      for i, id in connections:
        var event: WebSocketEvent
        while client.pollForEvent(id, event):
          case event.kind
          of weMessage:
            echo "socket ", i, ": ", event.message.data
            client.startCloseConnection(id)
          of weClosed:
            dec remaining
      sleep(1)
  finally:
    client.close()

when isMainModule:
  main()
