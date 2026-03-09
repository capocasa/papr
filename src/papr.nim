import std/[httpclient, json, os, strutils, strformat, uri, sequtils]
import cligen
import dotenv

const Version = staticRead("../papr.nimble").splitLines().filterIt(it.startsWith("version")).
    mapIt(it.split("=")[1].strip().strip(chars = {'"'}))[0]

proc loadEnv() =
  if fileExists(".env"):
    load(".env")

proc getConfig(): tuple[url: string, token: string] =
  loadEnv()
  let url = getEnv("PAPERLESS_URL").strip(chars = {'/'})
  let token = getEnv("PAPERLESS_TOKEN")
  if url == "":
    quit "Error: PAPERLESS_URL not set", 1
  if token == "":
    quit "Error: PAPERLESS_TOKEN not set", 1
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
    quit "API error: HTTP " & $resp.code, 1
  parseJson(resp.body)

proc resolveTagName(url, token, tagName: string): int =
  let data = apiGet(url, token, "/api/tags/?name__iexact=" & encodeUrl(tagName))
  let results = data["results"]
  if results.len == 0:
    quit "Tag not found: " & tagName, 1
  results[0]["id"].getInt

proc list*(tag: string = "inbox", page: int = 1, limit: int = 25): int =
  ## List documents filtered by tag
  let (url, token) = getConfig()
  let tagId = resolveTagName(url, token, tag)
  let endpoint = fmt"/api/documents/?tags__id={tagId}&page={page}&page_size={limit}&ordering=-created"
  let data = apiGet(url, token, endpoint)

  let count = data["count"].getInt
  let results = data["results"]

  echo fmt"{count} documents tagged '{tag}'"
  echo ""

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
    echo fmt"  {id:>6}  {created}  {title}{corrStr}"

  if count > page * limit:
    echo ""
    echo fmt"  Page {page}/{(count + limit - 1) div limit}"

proc show*(id: int): int =
  ## Show document metadata
  let (url, token) = getConfig()
  let doc = apiGet(url, token, fmt"/api/documents/{id}/")

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

proc download*(id: int, output: string = "", original: bool = false): int =
  ## Download document PDF
  let (url, token) = getConfig()

  # Get metadata first for default filename
  let doc = apiGet(url, token, fmt"/api/documents/{id}/")
  let origName = doc["original_file_name"].getStr
  let title = doc["title"].getStr

  let outFile = if output != "": output
    elif original and origName != "": origName
    else: title.replace(" ", "_") & ".pdf"

  let endpoint = if original:
    fmt"/api/documents/{id}/download/?original=true"
  else:
    fmt"/api/documents/{id}/download/"

  let client = apiClient(token)
  let resp = client.get(url & endpoint)
  if resp.code != Http200:
    quit "Download failed: HTTP " & $resp.code, 1

  writeFile(outFile, resp.body)
  echo fmt"Downloaded: {outFile} ({formatSize(resp.body.len)})"

proc version*(): int =
  ## Show version
  echo "papr " & Version

when isMainModule:
  dispatchMulti(
    ["multi", doc = "Paperless-ngx CLI"],
    [list, help = {
      "tag": "Tag name to filter by",
      "page": "Page number",
      "limit": "Documents per page"
    }],
    [show, help = {
      "id": "Document ID"
    }],
    [download, help = {
      "id": "Document ID",
      "output": "Output filename (default: document title)",
      "original": "Download original file instead of archived version"
    }],
    [version]
  )
