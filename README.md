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
papr list                     # all documents
papr list -t inbox            # by tag name
papr list -s added            # sort by date added
papr list -s title -r         # reverse sort
papr list -x                  # include OCR text
papr list -p 2                # page 2
```

### Show document metadata

```
papr show -i 817
```

Shows ID, title, dates, correspondent, document type, tags and a content preview.

### Download PDF

```
papr download -i 817              # archived (OCR'd) version
papr download -i 817 --original   # original scan
papr download -i 817 -o invoice.pdf
```

### Tag documents

```
papr tag -i 817 --add important
papr tag -i 817 --remove inbox
papr tag -i 817 --add processed --remove inbox
```

### Delete documents

```
papr delete -i 817              # asks for confirmation
papr delete -i 817 -y           # skip confirmation
```

### Consume pipeline

```
papr tasks                      # files currently being processed
```

## License

MIT

## Changelog

```
0.1.3    list all documents by default, add sort options, add tasks command
```
