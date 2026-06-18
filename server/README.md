# n1d — autonomous investigation backend

`n1d` is a small local HTTP server that runs the [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI as an **autonomous data-science agent** over your personal health and sensing data.

Instead of a fixed set of charts, it gives the agent a dynamically generated **data catalog** of every source it can query (data on your phone plus any JSON sources in a local personal data store), lets it export and analyze any source on demand, and asks it to write a structured result. When answering a question requires an assumption the data can't verify, the agent stops and poses a structured question rather than inventing a proxy variable.

It is the backend for a companion app; this directory contains only the server.

## Prerequisites

- **Node.js 18+** (uses only the standard library — no `npm install` needed).
- **Claude Code CLI** installed and authenticated, with `claude` available on your `PATH`. n1d spawns `claude` to do the actual work. Verify with:
  ```sh
  claude --version
  ```

## Running

```sh
node n1d.mjs
# or
npm start
```

On start it prints the listen URL, the model in use, and the number of catalog sources. The handbook is reloaded per request, so editing it takes effect on save without a restart.

## Configuration

All configuration is via environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `8787` | HTTP port to listen on. |
| `N1_BIND` | `127.0.0.1` | Bind address. Set to `0.0.0.0` to allow phone access over a private Tailscale tailnet (see Networking & security). |
| `N1_MODEL` | `claude-opus-4-8` | Claude model id passed to the `claude` CLI. |
| `N1_HANDBOOK` | `../agent/handbook.md` (relative to `n1d.mjs`) | Path to the agent methodology handbook (reloaded per request). |
| `N1_EXTRA_SOURCES_DIR` | _unset_ | Optional directory of extra JSON data sources to expose in the catalog (see below). |
| `N1_SENSING_FILE` | `sensing.json` | Name of the optional sensing event-log file inside `N1_EXTRA_SOURCES_DIR`. |

See [`.env.example`](./.env.example) for a copy-paste template.

### Personal data store (`N1_EXTRA_SOURCES_DIR`)

This optional directory lets you expose your own local data to the agent. It is purely
env-driven: set `N1_EXTRA_SOURCES_DIR` to point at your own store. If unset, the catalog
simply contains the phone-provided sources and everything still works.

Recognized files in the directory:

- `health_*.json` / `module_*.json` — each a JSON array of records; becomes one catalog source.
- the sensing event log (optional) — a single JSON array of sensing events shaped `{ modality, timestamp, payload }`; each distinct `modality` becomes its own `sensing:<modality>` source. The filename defaults to `sensing.json` and is configurable via `N1_SENSING_FILE`.

If the directory is absent or empty, the catalog just contains whatever the phone provides. No crash.

## API

The job model is **start-then-poll**: a `POST` returns a job id immediately and runs the analysis in the background; the client polls `GET /job/:id` until it finishes. This survives a client that drops the connection (e.g. a phone backgrounding the app).

### `POST /`
Start an investigation or onboarding run. Request body (JSON):

| Field | Description |
| --- | --- |
| `question` | The user's question (or their reply to a previous structured question). |
| `mode` | `"onboarding"` to propose ground-truth facts + suggested questions; otherwise a normal investigation. |
| `sessionId` | Optional. Resume a previous conversation in the same workspace (keeps fetched/computed data). |
| `phoneSources` | Optional. `{ name: csvString }` map of data already on the phone; written into the workspace and added to the catalog. |
| `dataNotes` | Optional free-text notes appended to the task. |
| `profile` | Optional array of confirmed ground-truth facts about the user (so the agent doesn't re-ask). |

Responds immediately with:
```json
{ "jobId": "..." }
```

### `GET /job/:id`
Poll a job. Returns:
```json
{
  "id": "...",
  "status": "running" | "done" | "error",
  "steps": [ { "title": "...", "detail": "..." } ],
  "result": { /* steps, findings, askUser, ... */ } ,
  "error": null,
  "sessionId": "..."
}
```
`steps` is the streamed chain-of-thought so far; `result` is populated when `status` is `done`. Finished jobs are retained for one hour. Pass the returned `sessionId` back as `sessionId` on a follow-up `POST` to continue the same conversation.

### `GET /health`
Liveness check:
```json
{ "ok": true, "backend": "autonomous-investigator", "model": "claude-opus-4-8", "sources": 0 }
```

## Networking & security

n1d binds `127.0.0.1` (localhost) by default. To let a phone reach it — typically over a [Tailscale](https://tailscale.com/) tailnet — set `N1_BIND=0.0.0.0`. **Only do this on a private tailnet you fully trust:** the server runs an agent with shell access, so never expose it on an untrusted network.

**Security note:** n1d runs the `claude` CLI with code-execution tools (`Bash`, `Read`, `Write`, `Glob`, `Grep`) over your personal data. Anyone who can reach the port can submit jobs that execute code on your machine against that data. **Only expose it on a network you fully trust.** There is no authentication built in.
