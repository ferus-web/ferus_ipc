import std/[logging, options]
import colored_logger
import ferus_ipc/server/prelude

let logger = newColoredLogger()
addHandler logger

var server = newIPCServer()

server.add(
  FerusGroup()
)

server.initialize() # optionally, provide a path as `Option[string]`
server.onConnection = proc(process: FerusProcess) =
  echo "yippee"

# Block until a new connection is made
server.acceptNewConnection()

while true:
  server.poll()
