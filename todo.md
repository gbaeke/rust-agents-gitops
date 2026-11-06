# To do

Open points after the five phases of [docs/plan.md](docs/plan.md). None of them is needed for the setup to work.

## Gateway

- [ ] **Report the MCP rate-limit gap to agentgateway.** In v1.7.0, tool calls count against an app's request limit but are never refused: they get 200 with `x-ratelimit-remaining: 0`, while model calls get 429. The draft is in [docs/agentgateway-mcp-rate-limit-issue.md](docs/agentgateway-mcp-rate-limit-issue.md). It hasn't been posted; it would go out under the repo owner's GitHub account.
- [ ] **Limit tool calls after all.** Until agentgateway fixes the gap, try a limit on each app's MCP route (`apps/<app>/mcp.yaml`) instead of on the Gateway, and test whether that one is enforced.
- [ ] **Strict, cluster-wide limits.** Today's limits are counted per gateway replica (2 × 30 a minute). A `global` rate limit needs a rate limit service (for example Envoy's ratelimit with Redis).
- [ ] **Token limits as a budget.** For example `tokens: 20000, unit: Hours` per app in `limits.yaml`, which fits cost control better than a request count.

## Releases

- [ ] **Per-image tags.** Both images get the hash of the last commit to any source path, so a change to the agent also gives the unchanged MCP server a new tag and restarts its pods. Tag each image with the last commit to its own paths (for the MCP image: `mcp-server/`, `Cargo.lock`, `Dockerfile`) in `scripts/release.sh`.
- [ ] **Build images in CI.** A GitHub Actions workflow that builds and pushes to ghcr.io and commits the tag. Filter it on source paths, so the tag commit doesn't trigger another build.

## Argo CD

- [ ] **Argo manages itself** (D8, optional): an Application `argocd` for the same chart and values in project `platform`, so that changes to `bootstrap/argocd-values.yaml` go through git instead of a re-run of `bootstrap.sh`.
- [ ] **Faster pickup after a push.** Argo polls git every 3 minutes, so the gateway can lag behind an app (seen in phases 3 and 5). A GitHub webhook would fix that, but GitHub can't reach this lab machine.
- [ ] **Slow removal of an app.** Removing an app's folder took about 4.5 minutes: the controller kept failing to render the deleted path for about 4 minutes before it began deleting. Find out whether that's a setting (a retry or timeout) or expected.

## Agent

- [ ] **Per-turn MCP tool listing.** The agent lists its MCP tools once, when it connects, so tools added later only show up after a restart. Listing them at the start of each turn, or caching them briefly as the OpenAI Agents SDK does, would pick up changes. rig's `McpClientHandler` refreshes on `notifications/tools/list_changed`, but our stateless MCP route never sends that.

## Rust code

From a review of `agent/` and `mcp-server/` on 2026-11-05, ordered by how far one request can hurt everything else. Start with the Postgres connections, the subagent fan-out, the empty `old_string` and the `fetch_url` body, then the turn log line.

### Flooding and bounds

- [ ] **One Postgres connection per chat, with no limit.** `agent/src/store.rs:289` opens a dedicated `PgConnection` for the turn lock on every `/api/chat`, before it checks whether the session is busy, with no connect timeout. 50 tabs with fresh session ids are 50 lock connections per replica plus the pool's 10; with 3 replicas Postgres' default `max_connections=100` runs out and every session breaks. Fix: a `Semaphore` of about 8 active turns per replica in `AppState` (`try_acquire`, 503 with `Retry-After` when full), `PgPoolOptions` with `max_connections` and `acquire_timeout`, and a timeout on the lock connect.
- [ ] **Subagents have no fan-out limit.** In `agent/src/tools/task.rs` the model can start any number of `task` calls per turn, for up to 40 turns, each subagent running up to 15. "Research these 30 customers" multiplies model calls 30 to 400 times, and `limits.yaml` has no limit for `rust-agents`. Fix: a shared semaphore in `Task` (about 3 at once), a per-turn task budget, and a `rust-agents` entry in `limits.yaml`.
- [ ] **No overall turn timeout.** A hung model stream holds the session lock and its DB connection until the client disconnects. Wrap the run in `tokio::time::timeout` (e.g. 10 minutes) and emit `UiEvent::Error`.
- [ ] **`edit_file` with an empty `old_string`.** In `agent/src/tools/files.rs:177`, `"".matches("")` counts `len+1` matches, so with `replace_all` the `new_string` goes between every character (200 KB × 1 KB ≈ 200 MB). Reject an empty `old_string`, and check `MAX_FILE_BYTES` after an edit too: only `write_file` checks it now.
- [ ] **No total workspace cap.** Each file is capped, but not the file count or total size, and the whole workspace is cloned, saved and sent over SSE after every tool result (`agent/src/main.rs:216`). Add a file count and total-bytes limit.
- [ ] **Unchecked request inputs.** `session_id` can be empty or a megabyte long (it becomes a primary key), `message` can be up to axum's 2 MB default and all of it goes to the model, and an empty message is passed on. Limit `session_id` to 64 chars of `[A-Za-z0-9-]` and `message` to about 20k chars, and reject empty ones.
- [ ] **`SESSION_TTL_DAYS` parsing.** `inf` or `1e300` makes `Duration::from_secs_f64` panic (`agent/src/main.rs:326`), and an invalid value silently becomes 7. Validate it and warn or exit.

### `fetch_url` in the MCP server

- [ ] **SSRF.** The only check is the `http(s)://` prefix, reqwest follows redirects, and the `mcp-server` pods have no egress NetworkPolicy, so a fetched page can steer the model to cluster-internal addresses (Argo CD server, gateway admin on `:15000`, any Service). Add an egress policy in `bases/rust-agent/network-policies.yaml` that allows only public IPs (deny RFC1918 and link-local, allow DNS), or refuse private addresses in code with a redirect policy that checks each hop.
- [ ] **Unbounded body.** `response.bytes()` (`mcp-server/src/main.rs:197`) reads the whole response before truncating to 12k characters; a multi-GB response can OOM the pod. Check `Content-Length` and stop reading at about 2 MB.

### Efficiency and robustness

- [ ] **A new `reqwest::Client` per request.** In stateless mode the factory at `mcp-server/src/main.rs:242` runs per request, so `Toolbox::new()` builds a client each time: no connection reuse, a new TLS setup, and `.expect()` on the request path. Build it once in `main` and clone it in.
- [ ] **Dropped SSE serialization errors.** `json_data(event).unwrap_or_default()` (`agent/src/main.rs:247`) sends an empty event and logs nothing.
- [ ] **Internal errors reach the browser.** `internal_error` sends `error.to_string()` (Postgres and sqlx text) to the client. Log the full chain and return a short generic message.

### Error handling

- [ ] **One error format.** `{error}` at `agent/src/main.rs:236` and `:370` drops the cause chain, while `store.rs` call sites use `{error:#}`. Use `{:#}` everywhere.
- [ ] **Keep error sources.** `connect_mcp` maps errors with `anyhow!("{error}")`; use `.map_err(anyhow::Error::from)` or `.context(...)`.
- [ ] **`ToolError` constructors.** It's built by hand with `format!` in about 10 places; small constructors would keep the messages consistent.

### Logging

- [ ] **JSON logs.** Both binaries log plain text. Enable the `json` feature of `tracing-subscriber` behind an env var (e.g. `LOG_FORMAT=json`), keeping the pretty output for `cargo run`.
- [ ] **Fields, not interpolation.** E.g. `tracing::warn!(session_id, error = %format!("{error:#}"), "workspace save failed")`.
- [ ] **Log each turn.** Nothing logs a turn today. Wrap the stream in `info_span!("turn", session_id, pod)`, log one summary line on `Done` (tokens, requests, `elapsed_ms`, tool count), tool calls and results at debug, and the 409 rejections.
- [ ] **Log MCP tool calls.** The MCP server logs nothing per call: `info!` with the tool name and duration, failures at warn.
- [ ] **HTTP access logs.** `tower_http::trace::TraceLayer` on both routers (method, path, status, latency).

### DRY

- [ ] **One truncation helper.** `clip` (`agent/src/main.rs:293`), `snippet` (`agent/src/kb.rs:143`) and the cut in `page_text` (`mcp-server/src/main.rs:203`) do the same thing.
- [ ] **One `NoArgs`.** It's defined in both `files.rs` and `knowledge.rs`; move it to `tools/mod.rs`.
- [ ] **The knowledge-base tools in one place.** They're listed in both `AppState::agent` and `Task::call`; a helper that adds them to an `AgentBuilder` keeps the agent and subagents in sync.
- [ ] **Shared startup code.** The tracing setup and `shutdown_signal` are copied in both binaries; with the JSON switch a tiny shared crate would stop them drifting apart.
- [ ] **A `Config::from_env()`.** Env vars are read in several ad hoc shapes; one struct would hold the defaults and fail loudly on bad values (which also covers `SESSION_TTL_DAYS`).

## Checks

- [ ] **A final rebuild test with both agents.** `cluster.sh down`, `up`, `bootstrap.sh`: everything, both agents included, must come back from git with no other step.
- [ ] **ufw-docker for host ports 31000–31009** (D6). Confirm from another machine that the existing rule for 30000–30009 covers them.
