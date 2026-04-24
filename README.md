# papr

Command-line client for [Paperless-ngx](https://docs.paperless-ngx.com/). List, inspect, download and tag your documents from the terminal.

## Install

```
nimble install papr
```

## Setup

Create a `.env` file in your working directory:

```
PAPERLESS_URL=https://paperless.example.com
PAPERLESS_TOKEN=your-api-token
```

Get your API token from the Paperless-ngx web UI under Settings, or:

```
curl -X POST https://paperless.example.com/api/token/ \
  -d '{"username":"...","password":"..."}'
```

## Usage

### List documents

```
papr list                           # all documents
papr list inbox                     # has tag inbox
papr list work invoice              # has both (AND)
papr list +draft +urgent            # has draft OR urgent
papr list work '!archived'          # has work, not archived
papr list +draft +urgent work '!archived'   # combined
papr list -s added                  # sort by date added
papr list -s title -r               # reverse sort
papr list -x                        # include OCR text
papr list -p 2                      # page 2
```

Tag filter syntax: bare tag is required (AND), `+tag` joins an any-of group
(OR), `!tag` excludes. Quote `!tag` in interactive bash/zsh to avoid history
expansion.

### Show document metadata

```
papr show 817
```

Shows ID, title, dates, correspondent, document type, tags and a content preview.

### Download PDF

```
papr download 817              # archived (OCR'd) version
papr download 817 --original   # original scan
papr download 817 -o invoice.pdf
```

### Tag documents

Tags and document ids go together in any order; numeric args are ids,
the rest are tag names. At least one of each is required.

```
papr tag important 817              # apply tag to doc
papr tag important urgent 817 923   # multiple tags, multiple docs
papr untag inbox 817                # remove tag from doc
```

### Manage tags

```
papr tag                            # list all tags
papr tag list                       # same
papr tag create Inbox               # create a new tag
papr tag rename Inbox Mailbox       # rename
papr tag delete Mailbox             # delete
```

### Delete documents

```
papr delete 817              # asks for confirmation
papr delete 817 -y           # skip confirmation
```

### Consume pipeline

```
papr tasks                      # files currently being processed
```

## License

MIT

## Changelog

```
0.1.3    list all documents by default, add sort options, add tasks command,
         case-sensitive tag lookup, tag/untag subcommand restructure
```
