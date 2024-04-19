import std/[
  os, logging, net, options, 
  sugar, strutils, times, json
]
import jsony
import ../shared, ./groups

when defined(unix):
  from std/posix import getuid

when defined(release):
  const 
    FerusIpcUnresponsiveThreshold* = "120".parseFloat
    FerusIpcDeadThreshold* = "240".parseFloat
    FerusIpcKickThreshold* = "400".parseFloat
else:
  when defined(ferusIpcMyTimeIsPrecious):
    const 
      FerusIpcUnresponsiveThreshold* = "3".parseFloat
      FerusIpcDeadThreshold* = "5".parseFloat
      FerusIpcKickThreshold* = "7".parseFloat
  else:
    const 
      FerusIpcUnresponsiveThreshold* = "30".parseFloat
      FerusIpcDeadThreshold* = "100".parseFloat
      FerusIpcKickThreshold* = "140".parseFloat

type
  InitializationFailed* = object of Defect
  IPCServer* = object
    socket*: Socket
    groups*: seq[FerusGroup]
    path*: string

    onConnection*: proc(process: FerusProcess)

proc send*[T](server: IPCServer, sock: Socket, data: T) {.inline.} =
  let serialized = (toJson data) & '\0'
  debug "Sending: " & serialized

  sock.send(serialized)

proc receive*(server: IPCServer, socket: Socket): string {.inline.} =
  var buff: string

  while true:
    let c = socket.recv(1)

    if c == "":
      break

    case c[0]
    of '\0', char(10):
      break
    else:
      discard

    buff &= c
  
  if buff.len > 0:
    debug "Received buffer from socket (length $1): $2" % [$buff.len, buff]

  buff

proc receive*[T](server: IPCServer, socket: Socket, kind: typedesc[T]): Option[T] {.inline.} =
  try:
    server
      .receive(socket)
      .fromJson(kind)
      .some()
  except CatchableError:
    none T

proc findDeadProcesses*(server: var IPCServer) =
  let epoch = epochTime()
  var dead: seq[tuple[gi, i: int]]
  
  for gi, group in server.groups:
    for i, fproc in group:
      var mfproc = group.processes[i] # TODO: rename this garbage, I keep it reading it as "motherfucking process"
      let delta = epoch - fproc.lastContact

      if fproc.state != Unreachable and fproc.state != Dead:
        if delta > FerusIpcUnresponsiveThreshold:
          info "Marking process as unreachable: group=$1, pid=$2, kind=$3, worker=$4" % [
            $fproc.group, $fproc.pid, $fproc.kind, $fproc.worker
          ]
          if fproc.kind == Parser:
            info " ... (parser kind: " & $fproc.pKind & ')'
      
          mfproc.state = Unreachable
      else:
        if fproc.state != Dead and delta > FerusIpcDeadThreshold and delta < FerusIpcKickThreshold:
          info "Marking process as dead: group=$1, pid=$2, kind=$3, worker=$4" % [
            $fproc.group, $fproc.pid, $fproc.kind, $fproc.worker
          ]
          if fproc.kind == Parser:
            info " ... (parser kind: " & $fproc.pKind & ')'

          mfproc.state = Dead
        elif delta > FerusIpcKickThreshold:
          info "Process has been unresponsive for $1 seconds, it is now considered dead: group=$2, pid=$3, kind=$4, worker=$5" % [
            $delta, $fproc.group, $fproc.pid, $fproc.kind, $fproc.worker
          ]
          dead.add((gi, i))

      server.groups[gi][i] = mfproc
  
  for process in dead:
    server.groups[process.gi].processes.del(process.i)

proc acceptNewConnection*(server: var IPCServer) =
  var
    conn: Socket
    address: string

  server.socket.acceptAddr(conn, address)

  info "New connection from: " & address
  let packet = server.receive(conn, HandshakePacket)

  if not *packet:
    server.send(
      conn,
      HandshakeResultPacket(
        accepted: false,
        reason: fhInvalidData
      )
    )
    close conn
    return

  let 
    data = &packet
    groupId = data.process.group
  
  if not data.process.worker:
    for group in server.groups:
      if group.id == groupId and 
        *group.find(
          (process: FerusProcess) => process.equate(data.process)
        ): server.send(conn, HandshakeResultPacket(accepted: false, reason: fhRedundantProcess))

  info "Process is probably not a duplicate, accepting it."
  var process = deepCopy(data.process)
  process.lastContact = epochTime()
  process.socket = conn
  server.groups[groupId].processes.add(
    process
  )

  server.send(
    conn,
    HandshakeResultPacket(
      accepted: true
    )
  )

proc add*(server: var IPCServer, group: FerusGroup) {.inline.} =
  var mGroup = deepCopy(group)
  mGroup.id = (server.groups.len).uint64
  server.groups.add(mGroup)

proc tryParseJson*[T](data: string, kind: typedesc[T]): Option[T] {.inline.} =
  try:
    data
      .fromJson(kind)
      .some()
  except CatchableError:
    none T

proc processChangeState(
  server: var IPCServer, 
  process: var FerusProcess, 
  data: ChangeStatePacket
) {.inline.} =
  info "PID $1 wants to change process state from $2 -> $3" % [$process.pid, $process.state, $data.state]
  
  if process.state == Dead:
    warn "PID $1 has attempted to change its process state despite being declared dead. Ignoring." % [$process.pid]
    return

  process.state = data.state

proc talk(server: var IPCServer, process: var FerusProcess) {.inline.} =
  let 
    rawData = server.receive(process.socket)
    data = tryParseJson(rawData, JsonNode)

  if not *data:
    return

  let 
    jsd = &data
    kind = jsd
      .getOrDefault("kind")
      .getStr()
      .magicFromStr()

  if not *kind:
    return
  
  case &kind:
    of feKeepAlive:
      process.lastContact = epochTime()
      if process.state == Dead:
        process.state = Idling
    of feChangeState:
      let changePacket = tryParseJson(
        rawData, 
        ChangeStatePacket
      )

      if not *changePacket:
        return

      server
        .processChangeState(
          process,
          &changePacket
        )
    else: discard

proc receiveMessages*(server: var IPCServer) {.inline.} =
  for gi, group in server.groups:
    validate group
    # debug "receiveMessages(): processing group " & $group.id

    for i, _ in group:
      var process = group[i]
      server.talk(process)
      server.groups[gi][i] = process

proc poll*(server: var IPCServer) =
  server.findDeadProcesses()
  server.receiveMessages()

proc `=destroy`*(server: IPCServer) =
  info "IPC server is now shutting down; closing socket!"
  server.socket.close()

proc bindServerPath*(server: var IPCServer): string =
  proc bindOptimalPath(socket: Socket, num: int = 0): string =
    let 
      uid = getuid().int
      curr = "/var" / "run" / "user" / $uid / "ferus-ipc-master-" & $num & ".sock"

    try:
      socket.bindUnix(curr)
      result = curr
      info "Successfully binded to: " & curr
    except OSError:
      debug curr & " is occupied; finding another socket file."
      if num > int16.high:
        raise newException(
          InitializationFailed,
          "Failed to find an optimal server socket path after " & $int16.high &
          "tries. You might have *quite* a few Ferus instances open (or we messed up). " &
          "Try to manually remove any file that follows this pattern: `/tmp/ferus-ipc-master-*.sock`"
        )

      return bindOptimalPath(socket, num + 1)

  when defined(unix):
    if not dirExists("/var" / "run" / "user" / $getuid()):
      raise newException(
        InitializationFailed,
        "Your system does not have a /var/run/user/$1 directory. Ferus' IPC server cannot bind to another path." % [$getuid()]
      )

    return bindOptimalPath(server.socket)

  raise newException(
    InitializationFailed,
    "Windows/non *NIX systems are not supported yet. Sorry! :("
  )

proc initialize*(server: var IPCServer, path: Option[string] = none string) {.inline.} =
  debug "IPC server initializing"
  server.socket.setSockOpt(OptReusePort, true)
  if path.isSome:
    server.socket.bindUnix(path.unsafeGet())
    server.path = unsafeGet path
  else:
    server.path = server.bindServerPath()

  server.socket.listen(65536)

proc newIPCServer*: IPCServer {.inline.} =
  IPCServer(
    socket: newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  )

export sugar
