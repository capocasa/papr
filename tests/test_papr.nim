import std/[unittest, net, strutils, uri, json, exitprocs]
import papr

const TestPort = 18765
const TestUrl = "http://127.0.0.1:" & $TestPort

var serverSocket: Socket
var serverThread: Thread[Socket]

# Fixture: paperless has two tags with different case.
#   "Inbox" -> id 10
#   "inbox" -> id 15
# A case-insensitive filter (name__iexact) would return both. A case-sensitive
# filter (name__exact) returns only the exact match.

proc handleClient(client: Socket) =
  defer: client.close()
  var reqLine = ""
  try:
    reqLine = client.recvLine(timeout = 2000)
  except CatchableError:
    return
  let parts = reqLine.split(" ")
  if parts.len < 2: return
  let path = parts[1]

  while true:
    var line = ""
    try: line = client.recvLine(timeout = 2000)
    except CatchableError: return
    if line == "" or line == "\c\L": break

  var results = newJArray()
  var nameFilter = ""
  var hasFilter = false
  if "?" in path:
    let query = path.split("?", 1)[1]
    for kv in query.split("&"):
      let kvp = kv.split("=", 1)
      if kvp.len != 2: continue
      if kvp[0] == "name__exact":
        nameFilter = decodeUrl(kvp[1])
        hasFilter = true
        if nameFilter == "Inbox":
          results.add(%*{"id": 10, "name": "Inbox"})
        elif nameFilter == "inbox":
          results.add(%*{"id": 15, "name": "inbox"})
      elif kvp[0] == "name__iexact":
        nameFilter = decodeUrl(kvp[1])
        hasFilter = true
        if nameFilter.toLowerAscii == "inbox":
          results.add(%*{"id": 15, "name": "inbox"})
          results.add(%*{"id": 10, "name": "Inbox"})

  # No name filter -> return full tag list (unpaginated)
  if not hasFilter and path.startsWith("/api/tags/"):
    results.add(%*{"id": 10, "name": "Inbox"})
    results.add(%*{"id": 15, "name": "inbox"})

  var payload = newJObject()
  payload["results"] = results
  payload["next"] = newJNull()
  let body = $payload
  let response = "HTTP/1.1 200 OK\c\L" &
    "Content-Type: application/json\c\L" &
    "Content-Length: " & $body.len & "\c\L" &
    "Connection: close\c\L\c\L" & body
  try: client.send(response)
  except CatchableError: discard

proc serverLoop(sock: Socket) {.thread.} =
  while true:
    var client: Socket
    try:
      sock.accept(client)
    except CatchableError:
      break
    handleClient(client)

proc startServer() =
  serverSocket = newSocket()
  serverSocket.setSockOpt(OptReuseAddr, true)
  serverSocket.bindAddr(Port(TestPort))
  serverSocket.listen()
  createThread(serverThread, serverLoop, serverSocket)

proc stopServer() =
  try: serverSocket.close()
  except CatchableError: discard

startServer()
addExitProc(stopServer)

suite "resolveTagName":
  test "resolves 'Inbox' to tag 10":
    check resolveTagName(TestUrl, "t", "Inbox") == 10

  test "resolves 'inbox' to tag 15":
    check resolveTagName(TestUrl, "t", "inbox") == 15

suite "listTagNames":
  test "preserves original case of tag names":
    let names = listTagNames(TestUrl, "t")
    check "Inbox" in names
    check "inbox" in names
