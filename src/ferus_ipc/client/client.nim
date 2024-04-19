import std/[os, logging, net, options, sugar, times], jsony
import ../shared

when defined(unix):
  from std/posix import getuid

type
  InitializationFailed* = object of Defect
  IPCClient* = object
    socket*: Socket
    path*: string

    process*: FerusProcess

    onConnect*: proc()
    onError*: proc(error: FailedHandshakeReason)

proc send*[T](client: var IPCClient, data: T) {.inline.} =
  let serialized = (toJson data) & '\0'

  debug "Sending: " & serialized

  client.socket.send(serialized)

proc receive*(client: var IPCClient): string {.inline.} =
  var buff: string
  
  while true:
    debug "recv: blocking for 1 byte; current buffer is " & buff
    let c = client.socket.recv(1)

    if c == "":
      break

    case c[0]
    of ' ', '\0', char(10):
      break
    else:
      discard

    buff &= c

  buff

proc receive*[T](client: var IPCClient, struct: typedesc[T]): Option[T] {.inline.} =
  let data = client.receive()

  try:
    data
      .fromJson(struct)
      .some()
  except JsonError as exc:
    warn "receive(" & $struct & ") failed: " & exc.msg
    warn "buffer: " & data
    
    none T

proc handshake*(client: var IPCClient) =
  info "IPC client performing handshake."
  client.send(
    HandshakePacket(
      process: client.process
    )
  )
  let resPacket = &client.receive(HandshakeResultPacket)

  if resPacket.accepted:
    client.onConnect()
  else:
    client.onError(resPacket.reason)

proc connect*(client: var IPCClient): string {.inline.} =
  proc inner(client: var IPCClient, num: int = 0): string {.inline.} =
    let path = "/var" / "run" / "user" / $getuid() / "ferus-ipc-master-" & $num & ".sock"

    try:
      client.socket.connectUnix(path)
      client.path = path

      path
    except OSError as exc:
      warn "Unable to connect to path: " & path
      if num > 1000:
        raise newException(
          InitializationFailed,
          "Could not find Ferus' master IPC server after 1000 " &
          "tries. Are you sure that a ferus_ipc instance is running?"
        )

      inner(client, num + 1)

  inner(client)

proc poll*(client: var IPCClient) =
  client.send(
    KeepAlivePacket()
  )

proc newIPCClient*: IPCClient {.inline.} =
  IPCClient(
    socket: newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  )

export shared
