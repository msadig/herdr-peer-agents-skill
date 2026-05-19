#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  herdr-peer.sh list
  herdr-peer.sh start NAME [--cwd PATH] [--workspace ID] [--tab ID] [--split right|down] [--focus|--no-focus] [-- CMD ...]
  herdr-peer.sh ask NAME MESSAGE [--timeout MS] [--lines N]
  herdr-peer.sh close NAME

Examples:
  herdr-peer.sh start reviewer --cwd "$PWD" --split right -- pi
  herdr-peer.sh ask reviewer "Review the git diff. Do not edit files."
  herdr-peer.sh close reviewer
EOF
}

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/herdr-peer-agents"
CACHE_FILE="$CACHE_DIR/peers.tsv"
mkdir -p "$CACHE_DIR"

json_get() {
  local expr="$1"
  python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
    cur=data
    for part in sys.argv[1].split("."):
        if not part: continue
        cur=cur.get(part, "") if isinstance(cur, dict) else ""
    print(cur if cur is not None else "")
except Exception:
    print("")' "$expr"
}

json_agent_field() { json_get "result.agent.$1"; }
json_pane_field() { json_get "result.pane.$1"; }

cache_save() {
  local name="$1" pane_id="$2" terminal_id="$3"
  local tmp="$CACHE_FILE.tmp"
  { [[ -f "$CACHE_FILE" ]] && awk -F'\t' -v n="$name" '$1 != n' "$CACHE_FILE" || true; printf '%s\t%s\t%s\t%s\n' "$name" "$pane_id" "$terminal_id" "$(date +%s)"; } > "$tmp"
  mv "$tmp" "$CACHE_FILE"
}

cache_field() {
  local name="$1" field="$2"
  [[ -f "$CACHE_FILE" ]] || return 1
  awk -F'\t' -v n="$name" -v f="$field" '$1 == n { if (f == "pane_id") print $2; else if (f == "terminal_id") print $3; else if (f == "ts") print $4; exit }' "$CACHE_FILE"
}

agent_get_json() {
  local target="$1"
  herdr agent get "$target" 2>/dev/null || return 1
}

pane_get_json() {
  local pane_id="$1"
  herdr pane get "$pane_id" 2>/dev/null || return 1
}

resolve_pane_id() {
  local name="$1" out pane_id
  if out="$(agent_get_json "$name")"; then
    pane_id="$(printf '%s' "$out" | json_agent_field pane_id)"
    [[ -n "$pane_id" ]] && { echo "$pane_id"; return 0; }
  fi
  pane_id="$(cache_field "$name" pane_id || true)"
  if [[ -n "$pane_id" ]] && pane_get_json "$pane_id" >/dev/null; then
    echo "$pane_id"; return 0
  fi
  return 1
}

resolve_terminal_id() {
  local name="$1" out terminal_id pane_id
  if out="$(agent_get_json "$name")"; then
    terminal_id="$(printf '%s' "$out" | json_agent_field terminal_id)"
    [[ -n "$terminal_id" ]] && { echo "$terminal_id"; return 0; }
  fi
  terminal_id="$(cache_field "$name" terminal_id || true)"
  [[ -n "$terminal_id" ]] && { echo "$terminal_id"; return 0; }
  pane_id="$(resolve_pane_id "$name" 2>/dev/null || true)"
  if [[ -n "$pane_id" ]]; then
    out="$(pane_get_json "$pane_id" || true)"
    terminal_id="$(printf '%s' "$out" | json_pane_field terminal_id)"
    [[ -n "$terminal_id" ]] && { echo "$terminal_id"; return 0; }
  fi
  return 1
}

resolve_send_target() {
  local name="$1" terminal_id pane_id
  if agent_get_json "$name" >/dev/null; then echo "$name"; return 0; fi
  terminal_id="$(resolve_terminal_id "$name" 2>/dev/null || true)"
  [[ -n "$terminal_id" ]] && { echo "$terminal_id"; return 0; }
  pane_id="$(resolve_pane_id "$name" 2>/dev/null || true)"
  [[ -n "$pane_id" ]] && { echo "$pane_id"; return 0; }
  echo "$name"
}

agent_kind_for() {
  local name="$1" out pane_id kind
  if out="$(agent_get_json "$name")"; then
    kind="$(printf '%s' "$out" | json_agent_field agent)"
    [[ -n "$kind" ]] && { echo "$kind"; return 0; }
  fi
  pane_id="$(resolve_pane_id "$name" 2>/dev/null || true)"
  if [[ -n "$pane_id" ]] && out="$(pane_get_json "$pane_id")"; then
    kind="$(printf '%s' "$out" | json_pane_field agent)"
    [[ -n "$kind" ]] && { echo "$kind"; return 0; }
  fi
  echo "unknown"
}

wait_for_detection_and_rename() {
  local name="$1" pane_id="$2" terminal_id="$3" deadline=$((SECONDS + 45)) out kind status missing_count=0
  while (( SECONDS < deadline )); do
    if ! out="$(pane_get_json "$pane_id")"; then
      missing_count=$((missing_count + 1))
      if (( missing_count >= 3 )); then
        echo "Warning: pane $pane_id for peer '$name' disappeared before agent detection." >&2
        return 1
      fi
      sleep 1
      continue
    fi
    missing_count=0
    kind="$(printf '%s' "$out" | json_pane_field agent)"
    status="$(printf '%s' "$out" | json_pane_field agent_status)"
    if [[ -n "$kind" && "$kind" != "unknown" ]]; then
      # Herdr can briefly create the pane before the process is detected as an agent.
      # Rename after detection so later `agent get <name>` works reliably.
      herdr agent rename "$terminal_id" "$name" >/dev/null 2>&1 || herdr agent rename "$pane_id" "$name" >/dev/null 2>&1 || true
      cache_save "$name" "$pane_id" "$terminal_id"
      echo "Detected $kind peer '$name' in pane $pane_id ($terminal_id), status=${status:-unknown}" >&2
      return 0
    fi
    sleep 1
  done
  echo "Warning: peer '$name' is still not detected as an agent after 45s. Cached pane=$pane_id terminal=$terminal_id." >&2
  return 1
}

wait_for_idle() {
  local target="$1" pane_id="$2" timeout_ms="$3"
  if herdr agent wait "$target" --status idle --timeout "$timeout_ms"; then
    return 0
  fi

  # Fallback for name/detection edge cases: poll pane state directly.
  local deadline=$((SECONDS + (timeout_ms / 1000))) out status
  while (( SECONDS < deadline )); do
    out="$(pane_get_json "$pane_id" || true)"
    status="$(printf '%s' "$out" | json_pane_field agent_status)"
    [[ "$status" == "idle" || "$status" == "done" ]] && return 0
    sleep 2
  done
  return 1
}

shell_join() {
  local out="" part
  for part in "$@"; do
    printf -v part '%q' "$part"
    out+="${out:+ }$part"
  done
  printf '%s' "$out"
}

select_base_pane() {
  local workspace="$1" tab="$2" out
  if [[ -n "$workspace" ]]; then
    out="$(herdr pane list --workspace "$workspace")"
  else
    out="$(herdr pane list)"
  fi
  printf '%s' "$out" | python3 -c 'import json,sys
want_tab=sys.argv[1]
data=json.load(sys.stdin)
panes=data.get("result",{}).get("panes",[])
if want_tab:
    panes=[p for p in panes if p.get("tab_id")==want_tab]
if not panes:
    sys.exit(1)
focused=[p for p in panes if p.get("focused")]
print((focused or panes)[0]["pane_id"])' "$tab"
}

manual_split_start() {
  local name="$1" cwd="$2" workspace="$3" tab="$4" split="$5" focus="$6"
  shift 6
  local agent_cmd=("$@")
  local base_pane split_json pane_id terminal_id cmdline

  base_pane="$(select_base_pane "$workspace" "$tab")"
  echo "Falling back to manual pane split from $base_pane, then pane run." >&2
  split_json="$(herdr pane split "$base_pane" --direction "$split" --cwd "$cwd" "$focus")"
  printf '%s\n' "$split_json"
  pane_id="$(printf '%s' "$split_json" | json_pane_field pane_id)"
  terminal_id="$(printf '%s' "$split_json" | json_pane_field terminal_id)"
  cache_save "$name" "$pane_id" "$terminal_id"
  herdr pane rename "$pane_id" "$name" >/dev/null 2>&1 || true
  cmdline="$(shell_join "${agent_cmd[@]}")"
  herdr pane run "$pane_id" "$cmdline" >/dev/null
  wait_for_detection_and_rename "$name" "$pane_id" "$terminal_id" || true
}

cmd="${1:-}"
case "$cmd" in
  list)
    herdr agent list
    ;;

  start)
    shift || true
    name="${1:-}"
    if [[ -z "$name" ]]; then usage; exit 2; fi
    shift

    cwd="$PWD"
    workspace=""
    tab=""
    split="right"
    focus="--no-focus"
    agent_cmd=(pi)

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --cwd) cwd="$2"; shift 2 ;;
        --workspace) workspace="$2"; shift 2 ;;
        --tab) tab="$2"; shift 2 ;;
        --split) split="$2"; shift 2 ;;
        --focus) focus="--focus"; shift ;;
        --no-focus) focus="--no-focus"; shift ;;
        --) shift; agent_cmd=("$@"); break ;;
        *) echo "Unknown arg for start: $1" >&2; usage; exit 2 ;;
      esac
    done

    args=(agent start "$name" --cwd "$cwd" --split "$split" "$focus")
    [[ -n "$workspace" ]] && args+=(--workspace "$workspace")
    [[ -n "$tab" ]] && args+=(--tab "$tab")
    args+=(-- "${agent_cmd[@]}")

    if start_json="$(herdr "${args[@]}" 2>/dev/null)"; then
      printf '%s\n' "$start_json"
      pane_id="$(printf '%s' "$start_json" | json_agent_field pane_id)"
      terminal_id="$(printf '%s' "$start_json" | json_agent_field terminal_id)"
      if [[ -n "$pane_id" && -n "$terminal_id" ]]; then
        cache_save "$name" "$pane_id" "$terminal_id"
        if wait_for_detection_and_rename "$name" "$pane_id" "$terminal_id"; then
          exit 0
        fi
        herdr pane close "$pane_id" >/dev/null 2>&1 || true
      fi
    else
      echo "Warning: herdr agent start failed; trying manual pane split fallback." >&2
    fi

    manual_split_start "$name" "$cwd" "$workspace" "$tab" "$split" "$focus" "${agent_cmd[@]}"
    ;;

  ask)
    shift || true
    name="${1:-}"
    if [[ -z "$name" ]]; then usage; exit 2; fi
    shift

    timeout="300000"
    lines="200"
    msg_parts=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --timeout) timeout="$2"; shift 2 ;;
        --lines) lines="$2"; shift 2 ;;
        *) msg_parts+=("$1"); shift ;;
      esac
    done
    message="${msg_parts[*]}"
    if [[ -z "$message" ]]; then usage; exit 2; fi

    pane_id="$(resolve_pane_id "$name")"
    target="$(resolve_send_target "$name")"
    agent_kind="$(agent_kind_for "$name")"

    herdr agent send "$target" "$message" || herdr pane send-text "$pane_id" "$message"
    herdr pane send-keys "$pane_id" Enter

    # Codex's composer commonly treats the first Enter as accepting/ending the current input line;
    # a second Enter reliably submits the prompt. Some terminal states need the extra Enter too.
    if [[ "$agent_kind" == "codex" ]]; then
      sleep 0.5
      herdr pane send-keys "$pane_id" Enter
    fi

    # Avoid idle-race: give the agent a chance to transition to working, but do not fail if it is too fast.
    herdr agent wait "$target" --status working --timeout 10000 >/dev/null 2>&1 || true
    wait_for_idle "$target" "$pane_id" "$timeout"
    herdr agent read "$target" --source recent-unwrapped --lines "$lines" || herdr pane read "$pane_id" --source recent-unwrapped --lines "$lines"
    ;;

  close)
    shift || true
    name="${1:-}"
    if [[ -z "$name" ]]; then usage; exit 2; fi
    pane_id="$(resolve_pane_id "$name")"
    herdr pane close "$pane_id"
    ;;

  -h|--help|help|"")
    usage
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    usage
    exit 2
    ;;
esac
