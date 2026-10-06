import std/os
import relay/websocket

proc main() =
  if paramCount() != 1:
    echo "Usage: websocket_echo <ws:// or wss:// URL>"
    return
  let client = newWebSocketClient()
  try:
    let opened = client.connect(paramStr(1))
    if opened.error.kind != teNone:
      echo opened.error.kind, " ", opened.error.message
      return
    let sent = client.send(opened.connectionId, "hello")
    if sent.error.kind != teNone:
      echo sent.error.kind, " ", sent.error.message
      return
    let item = client.receive(opened.connectionId)
    case item.kind
    of wrMessage:
      echo item.message.kind, " ", item.message.data
    of wrClosed:
      echo "closed: ", item.error.kind, " ", item.error.message
    of wrTimedOut:
      echo "receive timed out"
  finally:
    client.close()

when isMainModule:
  main()
