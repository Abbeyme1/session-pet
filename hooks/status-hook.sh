#!/usr/bin/env bash
# Session Pet status hook — writes a per-session state file the menu bar
# app polls. One shared script for every wired event; behavior branches on
# hook_event_name. See README.md for install instructions and the exact
# settings.json `hooks` block to wire this up.
#
# Requires `jq`. Install to ~/.claude/hooks/session-pet/status-hook.sh and
# chmod +x it.

if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
EVENT=$(jq -r '.hook_event_name // empty' <<<"$INPUT")
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT")
CWD=$(jq -r '.cwd // empty' <<<"$INPUT")

# Subagents (Task tool spawns) share the SAME session_id as their parent —
# verified live: a real subagent's PreToolUse event carried the identical
# session_id as the main session, distinguished only by agent_id/agent_type.
# Without keying the status file by agent_id too, a subagent's activity
# silently overwrites the parent's own status file and vice versa.
AGENT_ID=$(jq -r '.agent_id // empty' <<<"$INPUT")
AGENT_TYPE=$(jq -r '.agent_type // empty' <<<"$INPUT")

if [ -z "$SESSION_ID" ] || [ -z "$EVENT" ]; then
  exit 0
fi

STATUS_DIR="$HOME/.claude/session-pet/status"
mkdir -p "$STATUS_DIR"
if [ -n "$AGENT_ID" ]; then
  SAFE_AGENT_ID=$(printf '%s' "$AGENT_ID" | tr -c 'A-Za-z0-9-' '_')
  OUT="$STATUS_DIR/${SESSION_ID}__${SAFE_AGENT_ID}.json"
else
  OUT="$STATUS_DIR/$SESSION_ID.json"
fi
TMP="$OUT.tmp.$$"

TMUX_PANE_ID=""
if [ -n "$TMUX" ]; then
  TMUX_PANE_ID=$(tmux display-message -p '#{pane_id}' 2>/dev/null)
fi

case "$EVENT" in
  SessionStart)
    STATE="idle"
    TOOL="null"
    ;;
  UserPromptSubmit)
    STATE="working"
    TOOL="null"
    ;;
  PreToolUse)
    STATE="working"
    TOOL=$(jq -c '.tool_name // "Bash"' <<<"$INPUT")
    ;;
  PermissionRequest)
    STATE="waiting"
    TOOL=$(jq -c '.tool_name // "Bash"' <<<"$INPUT")
    ;;
  PostToolUseFailure)
    STATE="error"
    TOOL=$(jq -c '.tool_name // "Bash"' <<<"$INPUT")
    ;;
  Stop)
    STATE="idle"
    TOOL="null"
    ;;
  *)
    exit 0
    ;;
esac

jq -n \
  --arg session_id "$SESSION_ID" \
  --arg cwd "$CWD" \
  --arg state "$STATE" \
  --arg event "$EVENT" \
  --arg tmux_pane "$TMUX_PANE_ID" \
  --arg agent_id "$AGENT_ID" \
  --arg agent_type "$AGENT_TYPE" \
  --argjson tool "$TOOL" \
  --argjson tool_input "$(jq -c '.tool_input // null' <<<"$INPUT")" \
  --argjson updated_at "$(date +%s)" \
  '{session_id: $session_id, cwd: $cwd, state: $state, last_event: $event, tmux_pane: (if $tmux_pane == "" then null else $tmux_pane end), agent_id: (if $agent_id == "" then null else $agent_id end), agent_type: (if $agent_type == "" then null else $agent_type end), tool: $tool, tool_input: $tool_input, updated_at: $updated_at}' \
  > "$TMP" && mv "$TMP" "$OUT"
