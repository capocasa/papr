import std/[httpclient, json, os, strutils, strformat, uri, sequtils, tables]
import cligen
import dotenv

const Version = staticRead("../papr.nimble").splitLines().filterIt(it.startsWith("version")).
    mapIt(it.split("=")[1].strip().strip(chars = {'"'}))[0]

const
  ExitUsage = 2
  ExitConfig = 3
  ExitNotFound = 4
  ExitApi = 5
  ExitCancelled = 6

proc die(msg: string, code: int) {.noreturn.} =
  stderr.writeLine msg
  quit code

type DocId* = distinct int

proc `$`*(id: DocId): string = $int(id)
proc `==`*(a, b: DocId): bool {.borrow.}

proc argParse*(dst: var DocId, dfl: DocId, a: var ArgcvtParams): bool =
  var tmp: int
  result = argParse(tmp, int(dfl), a)
  if result: dst = DocId(tmp)

proc argHelp*(dfl: DocId, a: var ArgcvtParams): seq[string] =
  argHelp(int(dfl), a)

proc loadEnv() =
  if fileExists(".env"):
    load()

proc getConfig(): tuple[url: string, token: string] =
  loadEnv()
  let url = getEnv("PAPERLESS_URL").strip(chars = {'/'})
  let token = getEnv("PAPERLESS_TOKEN")
  if url == "":
    die "papr: PAPERLESS_URL not set", ExitConfig
  if token == "":
    die "papr: PAPERLESS_TOKEN not set", ExitConfig
  (url, token)

proc apiClient(token: string): HttpClient =
  let client = newHttpClient()
  client.headers = newHttpHeaders({
    "Authorization": "Token " & token,
    "Accept": "application/json"
  })
  client

proc apiGet(url, token, endpoint: string): JsonNode =
  let client = apiClient(token)
  let resp = client.get(url & endpoint)
  if resp.code != Http200:
    die "papr: API error: HTTP " & $resp.code, ExitApi
  parseJson(resp.body)

proc resolveTagName*(url, token, tagName: string): int =
  # paperless-ngx ignores name__exact, so use iexact and match case-sensitively here
  let data = apiGet(url, token, "/api/tags/?name__iexact=" & encodeUrl(tagName))
  for t in data["results"]:
    if t["name"].getStr == tagName:
      return t["id"].getInt
  die "papr: tag not found: " & tagName, ExitNotFound

const SortFields = {
  "created": "created",
  "added": "added",
  "modified": "modified",
  "title": "title",
  "correspondent": "correspondent__name",
  "type": "document_type__name"
}.toTable

proc list*(tag: string = "", page: int = 1, limit: int = 25, text: bool = false,
           sort: string = "created", reverse: bool = false): int =
  ## List documents, optionally filtered by tag
  if sort notin SortFields:
    die "papr: unknown sort field '" & sort & "'. Supported: " &
      toSeq(SortFields.keys).join(", "), ExitUsage
  let (url, token) = getConfig()
  # Date fields default descending (newest first); text fields default ascending
  let isDate = sort in ["created", "added", "modified"]
  let descending = if reverse: not isDate else: isDate
  let prefix = if descending: "-" else: ""
  let ordering = prefix & SortFields[sort]
  let endpoint = if tag != "":
    let tagId = resolveTagName(url, token, tag)
    fmt"/api/documents/?tags__id={tagId}&page={page}&page_size={limit}&ordering={ordering}"
  else:
    fmt"/api/documents/?page={page}&page_size={limit}&ordering={ordering}"
  let data = apiGet(url, token, endpoint)

  let results = data["results"]

  for doc in results:
    let id = doc["id"].getInt
    let title = doc["title"].getStr
    let created = doc["created"].getStr.split("T")[0]
    let correspondent = if doc["correspondent"].kind != JNull:
      let corrId = doc["correspondent"].getInt
      let corrData = apiGet(url, token, fmt"/api/correspondents/{corrId}/")
      corrData["name"].getStr
    else:
      ""
    let corrStr = if correspondent != "": " | " & correspondent else: ""
    var line = fmt"{id:>6}  {created}  {title}{corrStr}"
    if text and doc.hasKey("content") and doc["content"].kind != JNull:
      let content = doc["content"].getStr.replace("\n", "\\t").strip
      if content.len > 0:
        line &= "  " & content
    echo line

proc show*(id: seq[DocId] = @[]): int =
  ## Show document metadata
  if id.len == 0:
    die "papr: specify a document id", ExitUsage
  let docId = id[0]
  let (url, token) = getConfig()
  let doc = apiGet(url, token, fmt"/api/documents/{docId}/")

  echo "ID:            " & $doc["id"].getInt
  echo "Title:         " & doc["title"].getStr
  echo "Created:       " & doc["created"].getStr.split("T")[0]
  echo "Added:         " & doc["added"].getStr.split("T")[0]
  echo "Original name: " & doc["original_file_name"].getStr

  if doc["correspondent"].kind != JNull:
    let corrId = doc["correspondent"].getInt
    let corrData = apiGet(url, token, fmt"/api/correspondents/{corrId}/")
    echo "Correspondent: " & corrData["name"].getStr

  if doc["document_type"].kind != JNull:
    let dtId = doc["document_type"].getInt
    let dtData = apiGet(url, token, fmt"/api/document_types/{dtId}/")
    echo "Document type: " & dtData["name"].getStr

  let tags = doc["tags"]
  if tags.len > 0:
    var tagNames: seq[string]
    for tagId in tags:
      let tagData = apiGet(url, token, fmt"/api/tags/{tagId.getInt}/")
      tagNames.add(tagData["name"].getStr)
    echo "Tags:          " & tagNames.join(", ")

  if doc.hasKey("content") and doc["content"].kind != JNull:
    let content = doc["content"].getStr
    if content.len > 0:
      echo ""
      echo "--- Content preview ---"
      let lines = content.split("\n")
      for i, line in lines:
        if i >= 10:
          echo "  ..."
          break
        echo "  " & line

proc download*(id: seq[DocId] = @[], output: string = "", original: bool = false): int =
  ## Download document PDF
  if id.len == 0:
    die "papr: specify a document id", ExitUsage
  let docId = id[0]
  let (url, token) = getConfig()

  let doc = apiGet(url, token, fmt"/api/documents/{docId}/")
  let origName = doc["original_file_name"].getStr
  let title = doc["title"].getStr

  let outFile = if output != "": output
    elif original and origName != "": origName
    else: title.replace(" ", "_") & ".pdf"

  let endpoint = if original:
    fmt"/api/documents/{docId}/download/?original=true"
  else:
    fmt"/api/documents/{docId}/download/"

  let client = apiClient(token)
  let resp = client.get(url & endpoint)
  if resp.code != Http200:
    die "papr: download failed: HTTP " & $resp.code, ExitApi

  writeFile(outFile, resp.body)

proc listTagNames*(url, token: string): seq[string] =
  var page = 1
  while true:
    let data = apiGet(url, token, fmt"/api/tags/?page={page}&page_size=100&ordering=name")
    for t in data["results"]:
      result.add(t["name"].getStr)
    if data["next"].kind == JNull:
      break
    inc page

proc createTag(url, token, name: string) =
  let client = apiClient(token)
  client.headers["Content-Type"] = "application/json"
  let body = %*{"name": name}
  let resp = client.post(url & "/api/tags/", body = $body)
  if resp.code != Http201:
    die "papr: failed to create tag '" & name & "': HTTP " & $resp.code, ExitApi

proc deleteTag(url, token, name: string) =
  let tagId = resolveTagName(url, token, name)
  let client = apiClient(token)
  let resp = client.delete(url & fmt"/api/tags/{tagId}/")
  if resp.code != Http204:
    die "papr: failed to delete tag '" & name & "': HTTP " & $resp.code, ExitApi

proc renameTag(url, token, oldName, newName: string) =
  let tagId = resolveTagName(url, token, oldName)
  let client = apiClient(token)
  client.headers["Content-Type"] = "application/json"
  let body = %*{"name": newName}
  let resp = client.patch(url & fmt"/api/tags/{tagId}/", body = $body)
  if resp.code != Http200:
    die "papr: failed to rename tag '" & oldName & "': HTTP " & $resp.code, ExitApi

proc partitionArgs(args: seq[string]): tuple[tags: seq[string], ids: seq[DocId]] =
  for a in args:
    try:
      result.ids.add(DocId(parseInt(a)))
    except ValueError:
      result.tags.add(a)

proc updateDocTags(url, token: string, docId: DocId,
                   addTags, removeTags: seq[string]) =
  let doc = apiGet(url, token, fmt"/api/documents/{docId}/")
  var tagIds: seq[int]
  for t in doc["tags"]:
    tagIds.add(t.getInt)
  for name in addTags:
    let tid = resolveTagName(url, token, name)
    if tid notin tagIds:
      tagIds.add(tid)
  for name in removeTags:
    let tid = resolveTagName(url, token, name)
    let idx = tagIds.find(tid)
    if idx >= 0:
      tagIds.delete(idx)
  let body = %*{"tags": tagIds}
  let client = apiClient(token)
  client.headers["Content-Type"] = "application/json"
  let resp = client.patch(url & fmt"/api/documents/{docId}/", body = $body)
  if resp.code != Http200:
    die "papr: update failed for doc " & $docId & ": HTTP " & $resp.code, ExitApi

proc applyTags(addMode: bool, args: seq[string]) =
  let (url, token) = getConfig()
  let (tags, ids) = partitionArgs(args)
  if tags.len == 0 or ids.len == 0:
    die "papr: need at least one tag name and one document id", ExitUsage
  for id in ids:
    if addMode:
      updateDocTags(url, token, id, tags, @[])
    else:
      updateDocTags(url, token, id, @[], tags)

proc tag*(args: seq[string] = @[]): int =
  ## List, create, delete, rename tags, or apply tags to documents.
  ## Subcommands: list, create <name>, delete <name>, rename <old> <new>.
  ## Otherwise: apply given tags to given document ids (tags are non-numeric,
  ## ids are numeric; at least one of each required).
  let (url, token) = getConfig()

  if args.len == 0:
    for name in listTagNames(url, token):
      echo name
    return 0

  case args[0]
  of "list":
    if args.len != 1:
      die "usage: papr tag list", ExitUsage
    for name in listTagNames(url, token):
      echo name
  of "create":
    if args.len != 2:
      die "usage: papr tag create <name>", ExitUsage
    createTag(url, token, args[1])
  of "delete":
    if args.len != 2:
      die "usage: papr tag delete <name>", ExitUsage
    deleteTag(url, token, args[1])
  of "rename":
    if args.len != 3:
      die "usage: papr tag rename <old> <new>", ExitUsage
    renameTag(url, token, args[1], args[2])
  else:
    applyTags(addMode = true, args)

proc untag*(args: seq[string] = @[]): int =
  ## Remove tags from documents. Args: tag names and document ids mixed;
  ## at least one of each required.
  applyTags(addMode = false, args)

proc search*(terms: seq[string], page: int = 1, limit: int = 25, text: bool = false): int =
  ## Search documents by query
  if terms.len == 0:
    die "papr: specify search terms", ExitUsage
  let (url, token) = getConfig()
  let query = encodeUrl(terms.join(" "))
  let endpoint = fmt"/api/documents/?query={query}&page={page}&page_size={limit}&ordering=-created"
  let data = apiGet(url, token, endpoint)

  let results = data["results"]

  for doc in results:
    let id = doc["id"].getInt
    let title = doc["title"].getStr
    let created = doc["created"].getStr.split("T")[0]
    let correspondent = if doc["correspondent"].kind != JNull:
      let corrId = doc["correspondent"].getInt
      let corrData = apiGet(url, token, fmt"/api/correspondents/{corrId}/")
      corrData["name"].getStr
    else:
      ""
    let corrStr = if correspondent != "": " | " & correspondent else: ""
    var line = fmt"{id:>6}  {created}  {title}{corrStr}"
    if text and doc.hasKey("content") and doc["content"].kind != JNull:
      let content = doc["content"].getStr.replace("\n", "\\t").strip
      if content.len > 0:
        line &= "  " & content
    echo line

proc destroy*(id: seq[DocId] = @[], yes: bool = false): int =
  ## Delete a document
  if id.len == 0:
    die "papr: specify a document id", ExitUsage
  let docId = id[0]
  let (url, token) = getConfig()
  let doc = apiGet(url, token, fmt"/api/documents/{docId}/")
  let title = doc["title"].getStr

  if not yes:
    stderr.write fmt"Delete '{title}' (id {docId})? [y/N] "
    let answer = stdin.readLine.strip.toLowerAscii
    if answer != "y":
      quit ExitCancelled

  let client = apiClient(token)
  let resp = client.delete(url & fmt"/api/documents/{docId}/")
  if resp.code != Http204:
    die "papr: delete failed: HTTP " & $resp.code, ExitApi

proc tasks*(): int =
  ## Show files currently in the consume pipeline
  let (url, token) = getConfig()
  let data = apiGet(url, token, "/api/tasks/")
  for t in data:
    let status = t{"status"}.getStr
    if status in ["PENDING", "STARTED"]:
      let name = t{"task_file_name"}.getStr
      if name != "":
        echo name

proc version*(): int =
  ## Show version
  echo "papr " & Version

when isMainModule:
  dispatchMulti(
    ["multi", doc = "Paperless-ngx CLI"],
    [list, help = {
      "tag": "Tag name to filter by (default: all)",
      "page": "Page number",
      "limit": "Documents per page",
      "text": "Include OCR text",
      "sort": "Sort field: created, added, modified, title, correspondent, type",
      "reverse": "Reverse sort order"
    }, short = {"text": 'x', "reverse": 'r'}],
    [show, help = {
      "id": "Document ID"
    }, positional = "id"],
    [download, help = {
      "id": "Document ID",
      "output": "Output filename (default: document title)",
      "original": "Download original file instead of archived version"
    }, positional = "id"],
    [tag, help = {
      "args": "[list|create <name>|delete <name>|rename <old> <new>] or <tags> <ids>"
    }, positional = "args"],
    [untag, help = {
      "args": "<tags> <ids>"
    }, positional = "args"],
    [search, help = {
      "terms": "Search terms",
      "page": "Page number",
      "limit": "Documents per page",
      "text": "Include OCR text"
    }, short = {"text": 'x'}],
    [destroy, cmdName = "delete", help = {
      "id": "Document ID",
      "yes": "Skip confirmation"
    }, positional = "id", short = {"yes": 'y'}],
    [tasks],
    [version]
  )
