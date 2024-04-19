import std/[logging, options], colored_logger, ferus_ipc/client/prelude

let logger = newColoredLogger()
addHandler logger

var client = newIPCClient()
# client.broadcastVersion("0.1.0")
# client.identifyAs(Worker)

client.onConnect = proc =
    echo "We're connected!"
    client.send("Hello FerusIPC!")

client.onError = proc(error: FailedHandshakeReason) =
    case error
    of fhInvalidVersion:
      quit "Invalid version"
    else: discard

let path = client.connect()

client.handshake()

# we need to keep calling `poll` otherwise the IPC server will consider us unresponsive and finally dead!
while true:
  client.poll()

# no need to call `client.close()`, ORC manages that for you ;)
