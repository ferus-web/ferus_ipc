import std/[times, net, logging, options]

proc `*`*[T](opt: Option[T]): bool {.inline, noSideEffect, gcsafe.} =
  # dumb hacks to make code look less yucky
  opt.isSome

proc `&`*[T](opt: Option[T]): T {.inline, noSideEffect, gcsafe.} =
  opt.get()

type
  FerusProcessKind* = enum
    Network = 0           ## Network process (HTTP/Gemini/FTP/etc.)
    JSRuntime = 1         ## JS runtime (Tokenizer+Parser+VM)
    Parser = 2            ## Generic parser (HTML/CSS/JSON; see `ParserKind`)
    Renderer = 3          ## Renderer process
    CachingWorker = 4     ## Sits around and caches web content
    CookieWorker = 5      ## Sits around and stores cookies provided by the master process

  ParserKind* = enum
    pkCSS = 0 
    pkHTML = 1
    pkJSON = 2 ## Only used for untrustable JSON. All "trustable" JSON (IPC communication) is handled by the server itself.

  FerusProcessState* = enum
    Initialized = 0 ## Just started
    Processing = 1  ## Doing something
    Idling = 2      ## Doing nothing
    Exited = 3      ## Already exited
    Dead = 4        ## Crashed (didn't send a proper exit packet)
    Unreachable = 5 ## Hasn't sent any packets to confirm that it's not stuck in an unrecoverable loop

  FailedHandshakeReason* = enum
    fhInvalidData = 0 ## Invalid data passed over to server
    fhRedundantProcess = 1 ## This is a redundant process (this should never happen, if it does then it is a bug)
    fhInvalidVersion = 2 ## Version disparity between server and client (probably means the program got updated whilst it was running)

  FerusProcess* = object
    ## A server and client's representation of a client/process.
    worker*: bool             ## Is this process a worker?
    pid*: uint64              ## Process ID of this process
    socket*: Socket           ## IPC client socket (only available on the server)
    group*: uint64            ## The tab/group this process was spawned for
    lastContact*: float
    
    state*: FerusProcessState ## What is this process doing?

    case kind*: FerusProcessKind
    of Parser:
      pKind*: ParserKind      ## What does this process parse?
    else: discard

  FerusMagic* = enum
    ## feHandshake
    ## IPC clients send this to the server to negotiate joining in.
    ## Arguments:
    ## `kind`: FerusProcessKind - the process kind
    ##  if `kind` is parser:
    ##    - `parser_kind`: ParserKind - the kind of parser this process is
    ## `worker`: bool - is this process a worker? (short-lived process)
    ## `page`: uint64 - what page was this process spawned for?
    feHandshake
    
    ## feLogMessage
    ## IPC clients send this to the server for it to log the message provided.
    ## Arguments:
    ## `level`: uint8 (between 0 .. 3) - logging level
    ##  - 0: INFO
    ##  - 1: WARN
    ##  - 2: ERROR
    ##  - 3: DEBUG
    ## Anything above this range will trigger a bad message packet.
    ## 
    ## `message`: string - the message string
    feLogMessage
    
    ## feBadMessage
    ## The IPC server sends this in response to a packet that was malformed, along with a reason.
    ## The server might disconnect and kill the recipient of this packet if it suspects a potential takeover as well.
    ## Arguments:
    ## `error`: string
    feBadMessage

    ## feHandshakeResult
    ## The IPC server sends this in response to a `feHandshake` request.
    ## Arguments:
    ## `accepted`: bool - whether the request was accepted or not
    ##  if `accepted` is false:
    ##    - `reason`: FailedHandshakeReason - why was the request not accepted?
    feHandshakeResult
    
    ## feChangeState
    ## IPC clients send this to indicate their state
    ## `state`: uint - must be within the range 0..2; crashed+exited are reserved for the server's discretion
    feChangeState

    ## feParserSendResult
    ## IPC clients that are parsers send this to the server when they've completed parsing something.
    ## `final`: string - a JSON string that is passed over to jsony.
    ## `errors`: seq[string] - a list of errors that were encountered whilst parsing
    feParserSendResult

    ## feParserParse
    ## The IPC server sends this to a parser when something needs to be parsed.
    ## `input`: string - a string that needs to be parsed by this process.
    feParserParse

    ## feNetworkSendResult
    ## IPC clients that are network processes send this to the server when they've completed fetching a network resource.
    ## `content`: string - a string that was fetched.
    ## `mime`: string - a valid MIME identifier
    feNetworkSendResult

    ## feNetworkFetch
    ## The IPC server sends this to a network process when it needs to fetch a network resource.
    ## `url`: string - a JSON string that must be convertable to Sanchar's URL type.
    feNetworkFetch

    ## feJSExec
    ## The IPC server sends this to a JS runtime when it needs to run a JS string.
    ## `input`: string - a string that may or may not be valid JavaScript.
    feJSExec

    ## feJSExecError
    ## IPC clients that are JavaScript parsers send this to the server when they encounter an error that prevents the execution of JavaScript.
    ## This is only for syntax errors.
    ## `error`: string - The error that occured.
    ## `line`: uint - Which line it occured in.
    ## `char`: uint - Which character of a line it occured in.
    feJSExecError

    ## feJSGetDOMElem
    ## IPC clients that are JavaScript parsers send this to the server when they want to manipulate the DOM.
    ## `name`: string
    ## `by`: BaliElementSelector (unimplemented)
    feJSGetDOMElem

    ## feKeepAlive
    ## IPC clients send this to indicate that they are still alive, and when you'll be dying they'll be still alive, and when you'll be dead they'll be still alive.
    feKeepAlive

    ## feRendererMutation
    ## The IPC server sends this when it wants the renderer process to mutate its scene tree.
    ## `list`: IPCDisplayList - the display list that will be committed once it is resolved into a `DisplayList`
    feRendererMutation

    ## feRendererLoadFont
    ## The IPC server sends this when it wants a renderer process to load a font file
    ## `content`: string - the font data
    feRendererLoadFont

    ## feRendererExit
    ## A renderer client will send this to the IPC server when it's about to gracefully exit.
    feRendererExit

    ## feRendererSetWindowTitle
    ## The IPC server sends this to the renderer process along with the new title.
    ## `title`: string - the new window title
    feRendererSetWindowTitle

    ## feHtmlParserResult
    ## A HTML parser will send this to the IPC server when it's done parsing, along with a HTML document.
    ## `document`: Document - the parsed HTML document
    feHtmlParserResult

    ## feExitPacket
    ## IPC clients send this when they're about to exit.
    ## `reason`: ExitReason - the reason why the process is exiting
    feExitPacket
    
  # TODO: might wanna move these into their own file
  HandshakePacket* = ref object
    kind: FerusMagic = feHandshake
    process*: FerusProcess
  
  ExitReason* = enum
    erUnknown           ## Unhandled crash, most likely.
    erSandboxViolation  ## Sandbox violation, via SIGSYS hook.
    erServerRequest     ## Server requested this process to exit.

  ExitPacket* = ref object
    kind: FerusMagic = feExitPacket
    reason*: ExitReason

  HandshakeResultPacket* = ref object
    kind: FerusMagic = feHandshakeResult
    case accepted*: bool
    of false:
      reason*: FailedHandshakeReason
    else: discard

  KeepAlivePacket* = ref object
    kind: FerusMagic = feKeepAlive

  ChangeStatePacket* = ref object
    kind: FerusMagic = feChangeState
    state*: FerusProcessState

  FerusLogPacket* = ref object
    kind: FerusMagic = feLogMessage
    level*: uint8
    message*: string

  BadMessagePacket* = ref object
    kind: FerusMagic = feBadMessage
    error*: string

proc `==`*(a, b: FerusProcess): bool {.inline.} =
  a.worker == b.worker and
  a.kind == b.kind and
  a.socket == b.socket

proc magicFromStr*(s: string): Option[FerusMagic] {.inline.} =
  case s
  of "feHandshake": 
    return some feHandshake
  of "feHandshakeResult":
    return some feHandshakeResult
  of "feChangeState":
    return some feChangeState
  of "feParserSendResult":
    return some feParserSendResult
  of "feParserParse":
    return some feParserParse
  of "feNetworkSendResult":
    return some feNetworkSendResult
  of "feNetworkFetch":
    return some feNetworkFetch
  of "feJSExec":
    return some feJSExec
  of "feJSExecError":
    return some feJSExecError
  of "feJSGetDomElem":
    return some feJSGetDOMElem
  of "feKeepAlive":
    return some feKeepAlive
  of "feLogMessage":
    return some feLogMessage
  of "feRendererLoadFont":
    return some feRendererLoadFont
  of "feRendererSetWindowTitle":
    return some feRendererSetWindowTitle
  of "feHtmlParserResult":
    return some feHtmlParserResult
  of "feRendererMutation":
    return some feRendererMutation
  of "feExitPacket":
    return some feExitPacket
  else:
    warn "magicFromStr(" & s & "): no such magic string found."

proc equate*(p1, p2: FerusProcess): bool {.inline.} =
  if p1.kind != p2.kind:
    return false

  case p1.kind
  of Parser:
    p1.pKind == p2.pKind
  else:
    true
