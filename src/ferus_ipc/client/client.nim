import std/[os, net, options, sugar, times], jsony
import ../shared

when not defined(ferusInJail):
  import std/logging

when defined(unix):
  from std/posix import getuid

type
  AlreadyRegisteredIdentity* = object of CatchableError
  InitializationFailed* = object of Defect
  IPCClient* = object
    socket*: Socket
    path*: string
    connected: bool = false

    process: Option[FerusProcess]

    onConnect*: proc()
    onError*: proc(error: FailedHandshakeReason)

proc send*[T](client: var IPCClient, data: T) {.inline.} =
  let serialized = (toJson data) & '\0'

  # debug "Sending: " & serialized

  client.socket.send(serialized)

proc info*(client: var IPCClient, message: string) {.inline.} =
  client.send(
    FerusLogPacket(
      level: 0'u8,
      message: message
    )
  )

proc warn*(client: var IPCClient, message: string) {.inline.} =
  client.send(
    FerusLogPacket(
      level: 1'u8,
      message: message
    )
  )

proc error*(client: var IPCClient, message: string) {.inline.} =
  client.send(
    FerusLogPacket(
      level: 2'u8,
      message: message
    )
  )

proc debug*(client: var IPCClient, message: string) {.inline.} =
  client.send(
    FerusLogPacket(
      level: 3'u8,
      message: message
    )
  )

proc receive*(client: var IPCClient): string {.inline.} =
  var buff: string
  
  while true:
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
    if client.connected:
      client.warn "receive(" & $struct & ") failed: " & exc.msg
      client.warn "buffer: " & data
    else:
      when not defined(ferusInJail):
        client.warn "receive(" & $struct & ") failed: " & exc.msg
        client.warn "buffer: " & data
    
    none T

proc handshake*(client: var IPCClient) =
  when not defined(ferusInJail):
    info "IPC client performing handshake."
  client.send(
    HandshakePacket(
      process: &client.process
    )
  )
  let resPacket = &client.receive(HandshakeResultPacket)

  if resPacket.accepted:
    if client.onConnect != nil:
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
    except OSError:
      when not defined(ferusInJail):
        if num > 1000:
          raise newException(
            InitializationFailed,
            "Could not find Ferus' master IPC server after 1000 " &
            "tries. Are you sure that a ferus_ipc instance is running?"
          )
      else:
        # we must quietly die otherwise writing to stdout will trigger seccomp!
        if num > 1000:
          quit(1)

      inner(client, num + 1)

  inner(client)

proc identifyAs*(client: var IPCClient, process: FerusProcess) {.inline, raises: [AlreadyRegisteredIdentity].} =
  if *client.process:
    when not defined(ferusInJail):
      raise newException(
        AlreadyRegisteredIdentity,
        "Already registered as another process. You cannot call `identifyAs` twice!"
      )
    else:
      quit(1)

  client.process = some(process)

proc setState*(client: var IPCClient, state: FerusProcessState) {.inline.} =
  if not *client.process:
    when not defined(ferusInJail):
      raise newException(
        ValueError,
        "No process was registered before calling `setState()`. Run `identifyAs()` and provide a process first!"
      )

  var process = &client.process
  process.state = state

  client.process = some(process)

  client.send(
    ChangeStatePacket(
      state: state
    )
  )

proc poll*(client: var IPCClient) =
  client.send(
    KeepAlivePacket()
  )

proc newIPCClient*: IPCClient {.inline.} =
  IPCClient(
    socket: newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  )

export shared
