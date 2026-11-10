#!/usr/bin/env bash
# Antigravity CLI (agy) lifecycle hook adapter for agterm agent status.
# Reads the hook payload from stdin, prints the JSON response agy requires on
# stdout, and forwards the state transition to agterm-agent-status.sh.
#
# Also runs a pane-specific screen watcher to detect interactive approval prompts
# ("Run this command?"), and inspects the transcript on Stop to set 'blocked' (yellow)
# when the assistant finishes with a question in the current turn.

set -u

[ -n "${AGTERMCTL:-}" ] || AGTERMCTL='/opt/agterm-linux/bin/agtermctl'
script_path=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
action=${1:-}

status_script=${AGTERM_STATUS_WRAPPER:-${AGTERM_STATUS_SCRIPT:-${HOME:-}/.config/agterm/agent-status/agterm-agent-status.sh}}

watch_file_path() {
  local pane=${AGTERM_PANE_ID:-${AGTERM_PANE:-main}}
  local key
  key=$(printf '%s-%s' "${AGTERM_SESSION_ID:-}" "$pane" | /usr/bin/tr -c 'A-Za-z0-9._-' '_')
  printf '%s/agterm-agy-watch-%s-%s' "${TMPDIR:-/tmp}" "${UID:-$(id -u)}" "$key"
}

read_visible_screen() {
  local pane_args=()
  [ -n "${AGTERM_PANE:-}" ] && pane_args+=(--pane "$AGTERM_PANE")
  [ -n "${AGTERM_PANE_ID:-}" ] && pane_args+=(--pane-id "$AGTERM_PANE_ID")

  if [ -n "${AGTERM_SOCKET:-}" ]; then
    "${AGTERMCTL:-agtermctl}" session text \
      --target "$AGTERM_SESSION_ID" \
      --socket "$AGTERM_SOCKET" \
      "${pane_args[@]+"${pane_args[@]}"}" 2>/dev/null
  else
    "${AGTERMCTL:-agtermctl}" session text \
      --target "$AGTERM_SESSION_ID" \
      "${pane_args[@]+"${pane_args[@]}"}" 2>/dev/null
  fi
}

report_status() {
  "$status_script" "$@" >/dev/null 2>&1 || true
}

notify_lock_path() {
  local pane=${AGTERM_PANE_ID:-${AGTERM_PANE:-main}}
  local key
  key=$(printf '%s-%s' "${AGTERM_SESSION_ID:-}" "$pane" | /usr/bin/tr -c 'A-Za-z0-9._-' '_')
  printf '%s/agterm-agy-notify-%s-%s.lock' "${TMPDIR:-/tmp}" "${UID:-$(id -u)}" "$key"
}

notify_file_path() {
  local pane=${AGTERM_PANE_ID:-${AGTERM_PANE:-main}}
  local key
  key=$(printf '%s-%s' "${AGTERM_SESSION_ID:-}" "$pane" | /usr/bin/tr -c 'A-Za-z0-9._-' '_')
  printf '%s/agterm-agy-notify-%s-%s.ts' "${TMPDIR:-/tmp}" "${UID:-$(id -u)}" "$key"
}

notify_desktop() {
  local title=${1:-"Antigravity (agy)"}
  local body=${2:-"Требуется действие"}
  local lfile nfile
  lfile=$(notify_lock_path)
  nfile=$(notify_file_path)

  (
    # Атомарная блокировка на панель: защищает от одновременной отправки из watcher и lifecycle hook
    flock -x 9 || exit 0

    local now last_time=0
    now=$(date +%s 2>/dev/null || printf '%s' "0")
    if [ -f "$nfile" ]; then
      last_time=$(cat "$nfile" 2>/dev/null || printf '%s' "0")
    fi

    # Дедупликация: не слать повторное уведомление чаще раза в 3 секунды на панель
    if [ "$now" -gt 0 ] && [ "$last_time" -gt 0 ] && [ "$((now - last_time))" -lt 3 ]; then
      exit 0
    fi

    local notify_args=()
    [ -n "${AGTERM_SESSION_ID:-}" ] && notify_args+=(--target "$AGTERM_SESSION_ID")
    [ -n "${AGTERM_SOCKET:-}" ] && notify_args+=(--socket "$AGTERM_SOCKET")

    local delivered=0
    local agtermctl_bin=${AGTERMCTL:-}
    [ -n "$agtermctl_bin" ] || agtermctl_bin=$(command -v agtermctl 2>/dev/null || true)

    if [ -n "$agtermctl_bin" ] && [ -x "$agtermctl_bin" ]; then
      if "$agtermctl_bin" notify "$body" --title "$title" "${notify_args[@]+"${notify_args[@]}"}" >/dev/null 2>&1; then
        delivered=1
      fi
    fi

    if [ "$delivered" -eq 0 ] && command -v notify-send >/dev/null 2>&1; then
      if notify-send -a "agterm" "$title" "$body" >/dev/null 2>&1; then
        delivered=1
      fi
    fi

    # Записываем timestamp только при успешной доставке (не блокируя retry при сбое)
    if [ "$delivered" -eq 1 ] && [ "$now" -gt 0 ]; then
      printf '%s\n' "$now" > "$nfile" 2>/dev/null || true
    fi
  ) 9>"$lfile" >/dev/null 2>&1 || true
}

find_parent_agy_pid() {
  local pid=$$ comm
  for _ in 1 2 3 4 5 6; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    { [ -n "$pid" ] && [ "$pid" -gt 1 ]; } 2>/dev/null || break
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ') || break
    case "$comm" in
      agy|antigravity|antigravity-cli)
        printf '%s' "$pid"
        return 0
        ;;
    esac
  done
  return 1
}

watch_for_blocker() {
  local token=${1:-} token_file=${2:-}
  [ -n "$token" ] && [ -n "$token_file" ] || return 0

  local max_checks=21600
  local interval=0.5
  local checks=0 prompt_was_visible=0 current_token screen footer
  local is_prompt=0
  local agy_pid
  agy_pid=$(find_parent_agy_pid) || true

  while [ "$checks" -lt "$max_checks" ]; do
    current_token=$(cat "$token_file" 2>/dev/null) || break
    [ "$current_token" = "$token" ] || break

    if [ -n "$agy_pid" ] && ! kill -0 "$agy_pid" 2>/dev/null; then
      break
    fi

    screen=$(read_visible_screen) || break
    footer=$(printf '%s\n' "$screen" | /usr/bin/tail -n 16 | /usr/bin/tr '[:upper:]' '[:lower:]')

    is_prompt=0
    case "$footer" in
      *"requesting permission for:"*|*"run this command?"*|*"allow this action?"*|*"allow command?"*)
        case "$footer" in
          *"> 1. yes"*|*"1. yes"*|*"navigate"*|*"no, cancel"*|*"esc to cancel"*)
            is_prompt=1
            ;;
        esac
        ;;
      *"press enter to confirm"*|*"enter to submit answer"*|*"enter to submit all"*)
        is_prompt=1
        ;;
    esac

    if [ "$is_prompt" -eq 1 ]; then
      if [ "$prompt_was_visible" -eq 0 ]; then
        current_token=$(cat "$token_file" 2>/dev/null) || break
        [ "$current_token" = "$token" ] || break
        report_status blocked
        notify_desktop "Antigravity (agy)" "Требуется подтверждение команды"
        prompt_was_visible=1
      fi
    else
      if [ "$prompt_was_visible" -eq 1 ]; then
        current_token=$(cat "$token_file" 2>/dev/null) || break
        [ "$current_token" = "$token" ] || break
        report_status active --blink
        prompt_was_visible=0
      fi
    fi

    checks=$((checks + 1))
    [ "$checks" -ge "$max_checks" ] && break
    sleep "$interval"
  done
}

if [ "$action" = "__watch-blocked" ]; then
  watch_for_blocker "${2:-}" "${3:-}"
  exit 0
fi

payload=""

case "$action" in
  invocation|tool-done)
    cat >/dev/null
    printf '{}\n'
    ;;
  ask)
    cat >/dev/null
    printf '{"decision":"allow"}\n'
    ;;
  stop)
    payload=$(cat)
    printf '{"decision":"stop"}\n'
    ;;
  *)
    cat >/dev/null
    printf '{}\n'
    exit 0
    ;;
esac

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0
{ [ -z "${CLAUDECODE:-}" ] && [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; } || exit 0
[ -x "$status_script" ] || exit 0

is_headless_agy() {
  local pid=$$ parent_cmd found_agy token
  local -a tokens=()
  for _ in 1 2 3 4 5 6; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    { [ -n "$pid" ] && [ "$pid" -gt 1 ]; } 2>/dev/null || break
    parent_cmd=$(ps -o command= -p "$pid" 2>/dev/null) || break
    case "$parent_cmd" in
      sh\ -c\ *|*/sh\ -c\ *|bash\ -c\ *|*/bash\ -c\ *|zsh\ -c\ *|*/zsh\ -c\ *)
        continue
        ;;
    esac
    read -r -a tokens <<< "$parent_cmd"
    found_agy=0
    for token in "${tokens[@]+"${tokens[@]}"}"; do
      if [ "$found_agy" -eq 0 ]; then
        case "$token" in
          agy|*/agy) found_agy=1 ;;
        esac
      else
        case "$token" in
          -p|--print|--prompt|--print=*|--prompt=*) return 0 ;;
        esac
      fi
    done
    [ "$found_agy" -eq 1 ] && return 1
  done
  return 1
}

is_headless_agy && exit 0

agy_wait_alive() {
  local state_file="/tmp/agterm-mailbox-chat-${UID:-$(id -u)}/agy-${AGTERM_PANE_ID:-}.json"
  [ -f "$state_file" ] || return 1
  local content pid=""
  content=$(<"$state_file") 2>/dev/null || return 1
  if [[ $content =~ \"pid\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
    pid=${BASH_REMATCH[1]}
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
  fi
  return 1
}

agy_wait_ready() {
  # WaitMsBeforeAsync can let Stop run just before agy-wait writes its registration.
  for _ in 1 2 3 4 5; do
    agy_wait_alive && return 0
    sleep 0.1
  done
  return 1
}

stop_watcher() {
  rm -f -- "$(watch_file_path)" >/dev/null 2>&1 || true
}

start_watcher() {
  stop_watcher
  local token token_file
  token_file=$(watch_file_path)
  token="$$-${RANDOM:-0}"
  (umask 077; printf '%s\n' "$token" > "$token_file") 2>/dev/null || return 0
  export AGTERMCTL AGTERM_SESSION_ID AGTERM_SOCKET AGTERM_PANE AGTERM_PANE_ID status_script
  "$script_path" __watch-blocked "$token" "$token_file" </dev/null >/dev/null 2>&1 &
}

assistant_message_contains_question() {
  local payload_data=${1:-}
  [ -n "$payload_data" ] || return 1

  python3 -c '
import json, re, sys

try:
    payload = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)

path = payload.get("transcriptPath")
if not path:
    sys.exit(1)

try:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
except Exception:
    sys.exit(1)

last_text = None
for line in reversed(lines):
    try:
        step = json.loads(line)
    except Exception:
        continue
    # Stop at current turn boundary (user input)
    if step.get("type") == "USER_INPUT":
        break
    if step.get("source") == "MODEL" and step.get("type") == "PLANNER_RESPONSE":
        content = step.get("content")
        if content and isinstance(content, str) and content.strip():
            last_text = content
            break

if not last_text:
    sys.exit(1)

cleaned = re.sub(r"```.*?```", "", last_text, flags=re.DOTALL)
cleaned = re.sub(r"`[^`\n]*`", "", cleaned)
cleaned = re.sub(r"https?://\S+", "", cleaned)
cleaned = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", cleaned)

if "?" in cleaned:
    sys.exit(0)
sys.exit(1)
' "$payload_data" 2>/dev/null
}

case "$action" in
  invocation)
    report_status active --blink
    start_watcher
    ;;
  tool-done)
    report_status active --blink
    ;;
  ask)
    report_status blocked
    notify_desktop "Antigravity (agy)" "Требуется ответ на вопрос"
    ;;
  stop)
    stop_watcher
    idle_false_re='"fullyIdle"[[:space:]]*:[[:space:]]*false'
    if [[ $payload =~ $idle_false_re ]] && ! agy_wait_ready; then
      exit 0
    fi
    if assistant_message_contains_question "$payload"; then
      report_status blocked
      notify_desktop "Antigravity (agy)" "Ассистент ожидает вашего ответа"
    else
      report_status completed --auto-reset
    fi
    ;;
esac

exit 0
