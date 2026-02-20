# flowcurl

FlowCurl is a general-purpose Nim HTTP batching client with:

- parallel in-flight requests (`maxInFlight`),
- strict ordered result delivery by submission order,
- Curly-style batch APIs (`startRequests`, `waitForResult`, `makeRequests`).

## Install

```bash
nimble install
```

## Quick Example

```nim
import flowcurl

var client = newOrderedClient(maxInFlight = 8)
var batch: RequestBatch
batch.get("https://example.com", tag = "home")
batch.get("https://example.org", tag = "org")

for item in client.makeRequests(batch):
  if item.error.kind == teNone:
    echo item.response.request.tag, " -> ", item.response.code
  else:
    echo item.response.request.tag, " failed: ", item.error.message

client.close()
```

## API

Public exports are in `src/flowcurl.nim`.

- `newOrderedClient`
- `startRequests`
- `waitForResult`
- `pollForResult`
- `makeRequests`
- `clearQueue`
- `hasRequests`
- `numInFlight`
- `queueLen`
- `close`
- `abort`

## Run tests

```bash
nimble test
```

## Live example

```bash
nim c -r examples/basic_get.nim
```

