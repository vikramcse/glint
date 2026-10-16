# Local API and MCP server

When **Settings › Privacy › Allow apps and agents to search Glint** is on, Glint runs a small HTTP/JSON server on `127.0.0.1`.
It's how scripts and AI agents on this Mac can search the index.

- **Scope:** it listens only on this Mac.
- **Access:** every request needs a bearer token.
- **Privacy:** Glint's logs record routes and status codes only, never queries or paths.

## Discovery and auth

While the server runs, Glint writes `~/Library/Application Support/Glint/api.json` with mode 0600:

```json
{ "pid": 4321, "port": 52341, "token": "…64 hex chars…", "version": 1 }
```

Send `Authorization: Bearer <token>` with every request. The token persists in `api-token` (also 0600) until the user picks **Reset Access**.

Mode 0600 keeps the token from other user accounts, not from other apps you run. Any process running as you can read `api.json` and search the index, which includes text from files that macOS privacy settings would otherwise stop it from reading. That's why the API is off until you turn it on. Turn it off, or pick **Reset Access**, if you stop trusting software on the Mac.

The server rejects these requests:

| Request | Response |
| --- | --- |
| Any `Origin` header (browser) | 403 |
| A `Host` other than `127.0.0.1:<port>` or `localhost:<port>` (DNS-rebinding defence) | 403 |
| A `POST` whose `Content-Type` isn't `application/json` (a missing header is accepted) | 415 |
| Bodies over 64 KB | 413 |
| Chunked bodies | 501 |
| A request not fully sent within 3 seconds | connection closed |

## Endpoints

| Method | Path | Body | Returns |
| --- | --- | --- | --- |
| GET | `/v1/status` | — | `phase`, `pauseReason?`, `indexed{kind:n}`, `totalIndexed`, `pending`, `failed`, `sources` |
| GET | `/v1/sources` | — | `sources[]`: `path`, `name`, `accessible`, `external`, `network`, `remote` (`s3`), `items`, `indexed`, `pending`, `failed`, `complete` |
| POST | `/v1/search` | `{query, kinds?, limit?, folders?, modifiedAfter?}` | `results[]` |
| POST | `/v1/similar` | `{path, limit?}` (absolute path) | `results[]` |

Notes on the request fields:
- `kinds`: any of `image`, `video`, `audio`, `pdf`, `document`.
- `limit`: 1–100, default 20.
- `modifiedAfter`: an ISO 8601 date or date-time.
- `path` (`/v1/similar`): an indexed file, or a file inside one of the folders Glint indexes (after resolving symlinks). Indexed files are compared by their stored vectors without being opened. Any other path gets 404 `file_not_found`, whether or not it exists, so the endpoint can't be used to read or probe files elsewhere. At most two files are read for comparison at a time; beyond that the API answers 429 `busy`.

Each result has these fields:
- `path`, `name`, `kind`, `score`, `modified`
- `page`: 1-based, for PDF matches.
- `start` and `end`: seconds, for audio and video matches.
- `snippet`
- `indexed`: false when the file matched by name only.

Errors use the body `{"error": {"code": "...", "message": "..."}}`.

## MCP (`glint-mcp`)

`glint-mcp` is an MCP server over stdio, speaking protocol 2025-06-18; it also accepts 2025-03-26 and 2024-11-05. It reads the discovery file on every call, so it keeps working when Glint restarts. It ships inside the app bundle.

```sh
claude mcp add glint -- /Applications/Glint.app/Contents/MacOS/glint-mcp
```

To use it with Claude Desktop, add this to `claude_desktop_config.json`:

```json
{ "mcpServers": { "glint": { "command": "/Applications/Glint.app/Contents/MacOS/glint-mcp" } } }
```

It provides four tools, all read-only:
- `search_files(query, kinds?, limit?, folders?, modified_after?)`
- `find_similar(path, limit?)`
- `index_status()`
- `list_sources()`

Results come back as readable text plus `structuredContent`. Paths and snippets come from the user's files, so the text puts each result on one line (line breaks and control characters in file text become spaces), caps snippets at 300 characters, and starts with a note telling the agent to treat them as data, not instructions. If Glint isn't running or the API is off, the tool result says how to turn it on, instead of returning a protocol error.
