import std/[options, strutils]
import ../shared

type
  FerusGroup* = ref object
    id*: uint64
    processes*: seq[FerusProcess]

iterator items*(group: FerusGroup): lent FerusProcess {.inline.} =
  for process in group.processes:
    yield process

proc `[]=`*(group: FerusGroup, i: int, new: sink FerusProcess) {.inline.} =
  group.processes[i] = new

proc `[]`*(group: FerusGroup, i: int): FerusProcess {.inline.} =
  group.processes[i]

iterator pairs*(group: FerusGroup): tuple[i: int, process: FerusProcess] {.inline.} =
  for i, process in group.processes:
    yield (i: i, process: process)

proc validate*(group: FerusGroup) {.inline.} =
  for process in group:
    if process.group != group.id:
      raise newException(
        ValueError,
        "Stray process found in IPC group " &
        "(group=%1, stray=%2)" % [$group.id, $process.group]
      )

proc find*(group: FerusGroup, fn: proc(process: FerusProcess): bool): Option[FerusProcess] {.inline.} =
  for `proc` in group:
    if fn(`proc`):
      return some `proc`

proc findAll*(group: FerusGroup, fn: proc(process: FerusProcess): bool): seq[FerusProcess] {.inline.} =
  for `proc` in group:
    if fn(`proc`):
      result &= `proc`
