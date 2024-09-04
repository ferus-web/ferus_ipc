import std/[os, logging, options], ferus_ipc/client/prelude

var client = newIPCClient()
addHandler newIPCLogger(lvlAll, client)
# client.broadcastVersion("0.1.0")
client.identifyAs(
  FerusProcess(
    worker: false,
    pid: getCurrentProcessId().uint64,
    group: 0
  )
)

client.onConnect = proc =
    info "We're connected!"

client.onError = proc(error: FailedHandshakeReason) =
    case error
    of fhInvalidVersion:
      quit "Invalid version"
    else: discard

let path = client.connect()

client.handshake()
error("failed to do non existent task!")

var location = DataLocation(kind: DataLocationKind.WebRequest, url: "totallyrealwebsite.xyz")
let value = client.requestDataTransfer(ResourceRequired, location)

echo value.get.data

# we need to keep calling `poll` otherwise the IPC server will consider us unresponsive and finally dead!
while true:
  client.poll()

# no need to call `client.close()`, ORC manages that for you ;)
