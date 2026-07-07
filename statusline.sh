#!/usr/bin/env bash
# Claude Code status line (two lines)
#   line 1: [status light] model | context usage | fable5 weekly-scoped limit %
#           (fetched from the oauth usage API, cached ~5 min, refreshed async)
#   line 2: cwd | rate limits (5h/7d overall usage + reset) | refresh timestamp

input="$(cat)"

have_jq=0
if command -v jq >/dev/null 2>&1; then
  have_jq=1
fi

if [ "$have_jq" = "1" ]; then
  cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty')
  model_name=$(printf '%s' "$input" | jq -r '.model.display_name // empty')
  ctx_used_tokens=$(printf '%s' "$input" | jq -r '.context_window.total_input_tokens // empty')
  ctx_size=$(printf '%s' "$input" | jq -r '.context_window.context_window_size // empty')
  used_pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty')
  cost_usd=$(printf '%s' "$input" | jq -r '.cost.total_cost_usd // empty')
  transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
  rl_5h_pct=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
  rl_5h_reset=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
  rl_7d_pct=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
  rl_7d_reset=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
else
  # Minimal fallback parsing without jq (best-effort, fragile: flat extraction).
  extract_str() {
    printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
  }
  extract_num() {
    printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\\([0-9.eE+-]*\\).*/\\1/p" | head -n1
  }
  cwd=$(extract_str current_dir)
  [ -z "$cwd" ] && cwd=$(extract_str cwd)
  model_name=$(extract_str display_name)
  ctx_used_tokens=$(extract_num total_input_tokens)
  ctx_size=$(extract_num context_window_size)
  used_pct=$(extract_num used_percentage)
  cost_usd=$(extract_num total_cost_usd)
  transcript_path=$(extract_str transcript_path)
  # rate_limits: five_hour comes first in the JSON, seven_day second, so the
  # 1st/2nd used_percentage+resets_at matches five_hour/seven_day respectively.
  rl_5h_pct=$(printf '%s' "$input" | grep -o '"used_percentage"[[:space:]]*:[[:space:]]*[0-9.]*' | sed -n '1s/.*: *//p')
  rl_5h_reset=$(printf '%s' "$input" | grep -o '"resets_at"[[:space:]]*:[[:space:]]*[0-9]*' | sed -n '1s/.*: *//p')
  rl_7d_pct=$(printf '%s' "$input" | grep -o '"used_percentage"[[:space:]]*:[[:space:]]*[0-9.]*' | sed -n '2s/.*: *//p')
  rl_7d_reset=$(printf '%s' "$input" | grep -o '"resets_at"[[:space:]]*:[[:space:]]*[0-9]*' | sed -n '2s/.*: *//p')
fi

# ---------------------------------------------------------------------------
# 0. Working-status light, inferred from the last transcript record:
#    assistant + tool_use          -> green  (executing)
#    assistant + thinking, no text -> yellow (thinking)
#    tool result just recorded     -> green  (still working)
#    anything else / unreadable    -> red    (idle)
#    The transcript is written asynchronously, so this is an approximation.
# ---------------------------------------------------------------------------
light="🔴"
if [ -n "$transcript_path" ] && [ -r "$transcript_path" ]; then
  last_line=$(tail -n 1 "$transcript_path" 2>/dev/null)
  if [ -n "$last_line" ]; then
    if [ "$have_jq" = "1" ]; then
      verdict=$(printf '%s' "$last_line" | jq -r '
        if (.toolUseResult? != null) then "green"
        elif ((.message.role // .type) == "assistant") then
          (
            [.message.content[]? | select(.type == "tool_use")] as $tu |
            [.message.content[]? | select(.type == "thinking")] as $th |
            [.message.content[]? | select(.type == "text")] as $tx |
            if ($tu | length) > 0 then "green"
            elif ($th | length) > 0 and ($tx | length) == 0 then "yellow"
            else "red" end
          )
        else "red" end' 2>/dev/null)
    else
      case "$last_line" in
        *'"toolUseResult"'*|*'"tool_use"'*) verdict="green" ;;
        *'"thinking"'*) case "$last_line" in
                          *'"text"'*) verdict="red" ;;
                          *) verdict="yellow" ;;
                        esac ;;
        *) verdict="red" ;;
      esac
    fi
    case "$verdict" in
      green)  light="🟢" ;;
      yellow) light="🟡" ;;
      *)      light="🔴" ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# Helper: format a raw token count as e.g. "12.3K" / "128K" / "1.2M".
# ---------------------------------------------------------------------------
fmt_tokens() {
  n="$1"
  case "$n" in
    ''|*[!0-9.eE+-]*) printf '%s' "$n"; return ;;
  esac
  awk -v n="$n" 'BEGIN {
    if (n >= 1000000) printf "%.1fM", n/1000000;
    else if (n >= 1000) printf "%.1fK", n/1000;
    else printf "%d", n;
  }'
}

# ---------------------------------------------------------------------------
# 1. Model display name.
# ---------------------------------------------------------------------------
if [ -z "$model_name" ] || [ "$model_name" = "null" ]; then
  model_name="unknown-model"
fi

# ---------------------------------------------------------------------------
# 2. Context window usage: used tokens / total, plus percentage.
# ---------------------------------------------------------------------------
ctx_display="ctx n/a"
if [ -n "$ctx_used_tokens" ] && [ "$ctx_used_tokens" != "null" ]; then
  used_fmt=$(fmt_tokens "$ctx_used_tokens")
  if [ -n "$ctx_size" ] && [ "$ctx_size" != "null" ]; then
    size_fmt=$(fmt_tokens "$ctx_size")
    ctx_display="ctx ${used_fmt}/${size_fmt}"
  else
    ctx_display="ctx ${used_fmt}"
  fi
  if [ -n "$used_pct" ] && [ "$used_pct" != "null" ]; then
    pct_fmt=$(awk -v p="$used_pct" 'BEGIN{printf "%.0f", p}' 2>/dev/null)
    [ -n "$pct_fmt" ] && ctx_display="${ctx_display} (${pct_fmt}%)"
  fi
fi

# ---------------------------------------------------------------------------
# 3. (Session cost display removed — replaced by the fable5 weekly-scoped
#     usage segment built in section 7 below.)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 4. Current directory, abbreviated with ~ for $HOME, basename only.
# ---------------------------------------------------------------------------
dir_display="?"
if [ -n "$cwd" ] && [ "$cwd" != "null" ]; then
  case "$cwd" in
    "$HOME") dir_display="~" ;;
    *) dir_display=$(basename "$cwd") ;;
  esac
fi

# ---------------------------------------------------------------------------
# 5. Rate limits: 5h/7d window usage, each with a countdown until it resets.
# ---------------------------------------------------------------------------
# Round a possibly-float percentage to a whole number ("84.00000001" -> "84").
fmt_pct() {
  case "$1" in ''|null) printf '%s' "$1"; return ;; esac
  awk -v p="$1" 'BEGIN{printf "%.0f", p}' 2>/dev/null
}
# Countdown from now until a unix timestamp, English abbrev: "3d4h" / "2h15m" / "42m".
fmt_countdown() {
  ts="$1"
  case "$ts" in ''|null|*[!0-9]*) return ;; esac
  now=$(date +%s)
  awk -v r="$ts" -v n="$now" 'BEGIN {
    s = r - n;
    if (s <= 0) { printf "now"; exit }
    d = int(s / 86400); h = int(s % 86400 / 3600); m = int(s % 3600 / 60);
    if (d > 0) printf "%dd%dh", d, h;
    else if (h > 0) printf "%dh%dm", h, m;
    else printf "%dm", (m > 0 ? m : 1);
  }'
}

rl_display=""
if [ -n "$rl_5h_pct" ] && [ "$rl_5h_pct" != "null" ]; then
  rl_display="5h $(fmt_pct "$rl_5h_pct")%"
  cd5=$(fmt_countdown "$rl_5h_reset")
  [ -n "$cd5" ] && rl_display="${rl_display} (${cd5})"
fi
if [ -n "$rl_7d_pct" ] && [ "$rl_7d_pct" != "null" ]; then
  seg="7d $(fmt_pct "$rl_7d_pct")%"
  cd7=$(fmt_countdown "$rl_7d_reset")
  [ -n "$cd7" ] && seg="${seg} (${cd7})"
  if [ -n "$rl_display" ]; then
    rl_display="${rl_display} · ${seg}"
  else
    rl_display="$seg"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Refresh timestamp (moment the script runs).
# ---------------------------------------------------------------------------
refresh_ts=$(date "+%Y-%m-%d %H:%M:%S")

# ---------------------------------------------------------------------------
# 7. fable5 weekly model-scoped limit.
#    The statusline input only exposes the overall 5h/7d buckets; the per-model
#    weekly cap lives in the oauth usage API under limits[].scope.model. We
#    cache the result and refresh it in the background so a slow/absent network
#    never blocks the status line render (it just shows the last known value).
#    Refresh cadence ~5 min; a lock file collapses concurrent renders into one
#    in-flight request.
# ---------------------------------------------------------------------------
fable_display="fable5 n/a"
if [ "$have_jq" = "1" ]; then
  FABLE_CACHE="$HOME/.claude/fable_usage.cache"
  FABLE_LOCK="$HOME/.claude/fable_usage.lock"
  FABLE_TTL=300
  now_epoch=$(date +%s)
  need_refresh=1
  for _f in "$FABLE_CACHE" "$FABLE_LOCK"; do
    if [ -f "$_f" ]; then
      _mt=$(stat -c %Y "$_f" 2>/dev/null || echo 0)
      [ $((now_epoch - _mt)) -lt "$FABLE_TTL" ] && need_refresh=0
    fi
  done
  if [ "$need_refresh" = "1" ]; then
    : > "$FABLE_LOCK" 2>/dev/null   # mark refresh in-flight before spawning
    (
      tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null)
      [ -z "$tok" ] && exit 0
      curl -s -m 6 \
        -H "Authorization: Bearer $tok" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-cli" \
        "https://api.anthropic.com/api/oauth/usage" \
      | jq -c '[.limits[]? | select(.group == "weekly" and (.scope.model.display_name != null))]' \
        > "$FABLE_CACHE.tmp" 2>/dev/null \
      && mv "$FABLE_CACHE.tmp" "$FABLE_CACHE"
    ) >/dev/null 2>&1 &
  fi
  if [ -s "$FABLE_CACHE" ]; then
    fab=$(jq -r '
      ((map(select(.scope.model.display_name | test("fable"; "i")))[0]) // .[0]) as $l
      | if $l == null then empty
        else "\($l.percent)|\($l.resets_at // "")|\($l.severity // "")" end
    ' "$FABLE_CACHE" 2>/dev/null)
    if [ -n "$fab" ]; then
      # Only the percent is shown. No countdown (same reset as line 2's 7d) and
      # no severity marker (the number speaks for itself). The API returns a
      # float (e.g. 84.00000000000001), so round to a whole number.
      f_pct=${fab%%|*}
      f_pct=$(awk -v p="$f_pct" 'BEGIN{printf "%.0f", p}' 2>/dev/null)
      fable_display="fable5 ${f_pct}%"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Render. Status light stays outside the dim wrapper so it keeps full color.
# ---------------------------------------------------------------------------
DIM="\033[2m"
RESET="\033[0m"

printf "%s ${DIM}%s | %s | %s${RESET}\n" "$light" "$model_name" "$ctx_display" "$fable_display"
if [ -n "$rl_display" ]; then
  printf "${DIM}%s | %s | %s${RESET}\n" "$dir_display" "$rl_display" "$refresh_ts"
else
  printf "${DIM}%s | %s${RESET}\n" "$dir_display" "$refresh_ts"
fi
