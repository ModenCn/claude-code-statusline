# claude-code-statusline

A compact two-line [Claude Code](https://claude.com/claude-code) status line, written in plain Bash.

```
🟢 Opus 4.8 (1M context) | ctx 177.3K/1.0M (18%) | fable5 82%
   ~ | 5h 1% (2h54m) · 7d 46% (1d4h) | 2026-07-06 18:45:20
```

## What it shows

**Line 1** — `[status light] model | context usage | fable5 weekly-scoped limit`

- **Status light** — inferred from the last transcript record: 🟢 executing / running a tool, 🟡 thinking, 🔴 idle. (The transcript is written asynchronously, so it's an approximation.)
- **Model** — current model display name.
- **Context usage** — used tokens / window size and percentage, e.g. `ctx 177.3K/1.0M (18%)`.
- **fable5** — the **per-model weekly limit** for Fable 5. Claude Code's status-line input only exposes the *overall* 5h/7d buckets, not the per-model cap, so this is fetched separately from the OAuth usage API (see below). Shows `fable5 n/a` when unavailable.

**Line 2** — `cwd | rate limits | refresh timestamp`

- **cwd** — current directory basename (`~` for `$HOME`).
- **Rate limits** — overall `5h` and `7d` usage with an English countdown to reset, e.g. `5h 1% (2h54m) · 7d 46% (1d4h)`.
- **Refresh timestamp** — the moment the line was last rendered.

## The fable5 segment (per-model weekly limit)

The status-line JSON only contains `rate_limits.five_hour` and `rate_limits.seven_day` (both **overall**). The per-model weekly caps that `/usage` shows live in an OAuth usage endpoint under `limits[].scope.model`. This script reads that endpoint and picks the limit whose `scope.model.display_name` matches `fable`.

- **Async + cached** — the network call runs in the background and the result is cached (`~/.claude/fable_usage.cache`, TTL 300s). Rendering **never blocks** on the network; it shows the last known value. A lock file collapses concurrent renders into a single in-flight request.
- **Your token never leaves your machine** except to Anthropic's own API. The script reads it at runtime from `~/.claude/.credentials.json` (`.claudeAiOauth.accessToken`) — nothing is hardcoded.
- **Caveat:** `https://api.anthropic.com/api/oauth/usage` is **undocumented and may change or disappear** at any time. If it does, the segment simply falls back to `fable5 n/a`. Adjust the `test("fable"; "i")` selector to track a different model.

## Install

1. Save `statusline.sh` somewhere, e.g. `~/.claude/statusline.sh`, and make it executable:
   ```bash
   chmod +x ~/.claude/statusline.sh
   ```
2. Point Claude Code at it in `~/.claude/settings.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash ~/.claude/statusline.sh"
     }
   }
   ```

## Requirements

- `bash`, `curl`
- `jq` — used for robust JSON parsing (there is a fragile no-`jq` fallback for the basic fields, but the fable5 segment needs `jq`).
- **GNU coreutils** — the countdowns and cache TTL use `date -d` and `stat -c`, i.e. this targets **Linux**. On macOS install coreutils (`brew install coreutils`) and swap `date`→`gdate`, `stat -c %Y`→`stat -f %m`, or run it under a Linux shell.

## Customize

- **Refresh cadence / cache location** — `FABLE_TTL`, `FABLE_CACHE`, `FABLE_LOCK` near section 7.
- **Which model to track** — change the `test("fable"; "i")` selector.
- **Countdown format** — `fmt_countdown` (`3d4h` / `2h15m` / `42m`).

## License

MIT — see [LICENSE](LICENSE).
