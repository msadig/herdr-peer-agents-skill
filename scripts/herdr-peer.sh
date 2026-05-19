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

json_agent_field() {
  local field="$1"
  python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["result"]["agent"].get(sys.argv[1], ""))' "$field"
}

require_agent_pane() {
  local name="$1"
  herdr agent get "$name" | json_agent_field pane_id
}

agent_field() {
  local name="$1"
  local field="$2"
  herdr agent get "$name" | json_agent_field "$field"
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
    herdr "${args[@]}"
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

    pane_id="$(require_agent_pane "$name")"
    agent_kind="$(agent_field "$name" agent)"
    herdr agent send "$name" "$message"
    herdr pane send-keys "$pane_id" Enter

    # Codex's composer commonly treats the first Enter as accepting/ending the current input line;
    # a second Enter reliably submits the prompt. Pi usually needs only one Enter.
    if [[ "$agent_kind" == "codex" ]]; then
      sleep 0.5
      herdr pane send-keys "$pane_id" Enter
    fi

    # Avoid idle-race: give the agent a chance to transition to working, but do not fail if it is too fast.
    herdr agent wait "$name" --status working --timeout 10000 >/dev/null 2>&1 || true
    herdr agent wait "$name" --status idle --timeout "$timeout"
    herdr agent read "$name" --source recent-unwrapped --lines "$lines"
    ;;

  close)
    shift || true
    name="${1:-}"
    if [[ -z "$name" ]]; then usage; exit 2; fi
    pane_id="$(require_agent_pane "$name")"
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
