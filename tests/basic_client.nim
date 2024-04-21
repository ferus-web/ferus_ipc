import std/[os, logging, options], colored_logger, ferus_ipc/client/prelude

let logger = newColoredLogger()
addHandler logger

var client = newIPCClient()
# client.broadcastVersion("0.1.0")
client.identifyAs(
  FerusProcess(
    worker: false,
    pid: getCurrentProcessId().uint64,
    group: 0
  )
)

client.onConnect = proc =
    echo "We're connected!"

client.onError = proc(error: FailedHandshakeReason) =
    case error
    of fhInvalidVersion:
      quit "Invalid version"
    else: discard

let path = client.connect()

client.handshake()
client.setState(Dead) # we're gonna get killed after we send this since the server detects that we're doing something silly and probably got taken over
client.error("failed to do non existent task!")

# we need to keep calling `poll` otherwise the IPC server will consider us unresponsive and finally dead!
while true:
  client.poll()

# no need to call `client.close()`, ORC manages that for you ;)
