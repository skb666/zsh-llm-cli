# Fallback to multiple LLM CLIs (kimi / opencode / omp / user-defined) via a
# tag-prefixed prompt of the form `<char>[<backend>] <prompt>`. Ctrl-X toggles
# the tag prefix of the currently active backend; Ctrl-N cycles the active
# backend. Plugin reads NO environment variables for user-facing config -- all
# configuration lives in two places:
#   - `<plugin>/backends/*.backend.ini` (built-in backends)
#   - `~/.config/zsh-llm-cli/backends/*.backend.ini` (user backends)
#   - `<plugin>/config.ini` (built-in global config)
#   - `~/.config/zsh-llm-cli/config.ini` (user global config; whole-file override)

# ============================================================================
# Global state declarations
# ============================================================================

typeset -ga __LLM_CLI_BACKEND_ORDER=()
typeset -gA __LLM_CLI_BACKENDS_PREFIX=()
typeset -gA __LLM_CLI_BACKENDS_TAG=()
typeset -gA __LLM_CLI_BACKENDS_BIN=()
typeset -gA __LLM_CLI_BACKENDS_ARGS=()
typeset -gA __LLM_CLI_BACKENDS_USE_SD=()
typeset -gA __LLM_CLI_BACKENDS_PREFIX_ACTIVE=()

typeset -gA __LLM_CLI_CONFIG_UI=()
typeset -gA __LLM_CLI_CONFIG_CYCLE=()

typeset -g  __LLM_CLI_CURRENT_BACKEND=
typeset -gi __LLM_CLI_CURRENT_BACKEND_INDEX=0

typeset -gA __LLM_CLI_GUARD_WIDGET_ALIASES=()
typeset -gi __LLM_CLI_WIDGETS_INSTALLED=0

typeset -gA __LLM_CLI_PARSE_SCALARS=()
typeset -ga __LLM_CLI_PARSE_ORDER=()

# ============================================================================
# INI parser
# ============================================================================

__llm_cli_parse_reset() {
  __LLM_CLI_PARSE_SCALARS=()
  __LLM_CLI_PARSE_ORDER=()
}

# Helper: trim leading and trailing ASCII whitespace from $1, echoed on stdout.
__llm_cli_trim() {
  emulate -L zsh
  # Use parameter-expansion anchor positions. (i) returns the index of the
  # first match of the pattern; (I) returns the last. We use these to find
  # the first and last non-whitespace positions, then slice the string.
  local s="$1"
  local first=1
  local last=${#s}
  local i
  for (( i = 1; i <= ${#s}; i++ )); do
    if [[ "${s[$i]}" != [[:space:]] ]]; then
      first=$i
      break
    fi
  done
  for (( i = ${#s}; i >= 1; i-- )); do
    if [[ "${s[$i]}" != [[:space:]] ]]; then
      last=$i
      break
    fi
  done
  if (( first > last )); then
    return 0
  fi
  print -r -- "${s[$first,$last]}"
}

__llm_cli_parse_ini() {
  emulate -L zsh
  local file="$1"
  local line=
  local section=
  local ch=
  local composite=
  local valid=
  local i=
  local key=
  local val=
  integer line_num=0
  integer err=0

  [[ -r "$file" ]] || { print -u2 "zsh-llm-cli: cannot read INI file: $file"; return 1; }

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$(( line_num + 1 ))

    if [[ -z "$line" || "${line[1]}" == "#" ]]; then
      continue
    fi

    if [[ "${line[1]}" == "[" && "${line[-1]}" == "]" ]]; then
      section="${line[2,-2]}"
      valid=1
      i=1
      ch="${section[$i]}"
      while [[ -n "$ch" ]]; do
        case "$ch" in
          [A-Za-z0-9_-]) ;;
          *) valid=0; break ;;
        esac
        i=$(( i + 1 ))
        ch="${section[$i]}"
      done
      if [[ "$valid" != "1" || -z "$section" ]]; then
        print -u2 "zsh-llm-cli: $file:$line_num: invalid section name: [$section]"
        err=1
        section=
      fi
      continue
    fi

    if [[ "$line" != *=* ]]; then
      print -u2 "zsh-llm-cli: $file:$line_num: malformed line: $line"
      err=1
      continue
    fi

    key="$(__llm_cli_trim "${line%%=*}")"
    val="$(__llm_cli_trim "${line#*=}")"
    [[ -z "$key" ]] && continue

    composite="${section}.${key}"
    if [[ -z "${__LLM_CLI_PARSE_SCALARS[$composite]+set}" ]]; then
      __LLM_CLI_PARSE_SCALARS[$composite]="$val"
      __LLM_CLI_PARSE_ORDER+=("$composite")
    else
      __LLM_CLI_PARSE_SCALARS[$composite]="${__LLM_CLI_PARSE_SCALARS[$composite]}|$val"
    fi
  done < "$file"

  return $err
}

__llm_cli_parse_get() {
  emulate -L zsh
  print -r -- "${__LLM_CLI_PARSE_SCALARS[$1]:-}"
}

# ============================================================================
# Global config loading
# ============================================================================

__LLM_CLI_PLUGIN_DIR="${0:A:h}"
__LLM_CLI_USER_CONFIG_DIR="${HOME}/.config/zsh-llm-cli"

__llm_cli_load_config() {
  emulate -L zsh
  local cfg_file="$1"
  [[ ! -r "$cfg_file" ]] && return 0

  __llm_cli_parse_reset
  __llm_cli_parse_ini "$cfg_file"

  local composite section key_lc val
  for composite in "${__LLM_CLI_PARSE_ORDER[@]}"; do
    section="${composite%%.*}"
    key_lc="${composite#*.}"
    val="${__LLM_CLI_PARSE_SCALARS[$composite]}"
    if [[ "$section" == "ui" ]]; then
      __LLM_CLI_CONFIG_UI[$key_lc]="$val"
    elif [[ "$section" == "cycle" ]]; then
      __LLM_CLI_CONFIG_CYCLE[$key_lc]="$val"
    fi
  done
}

__llm_cli_load_config "${__LLM_CLI_PLUGIN_DIR}/config.ini"

: "${__LLM_CLI_CONFIG_UI[rprompt_format]:=llm-cli: %name %tag}"
: "${__LLM_CLI_CONFIG_CYCLE[key_toggle]:=^X}"
: "${__LLM_CLI_CONFIG_CYCLE[key_next]:=^N}"

if [[ -r "${__LLM_CLI_USER_CONFIG_DIR}/config.ini" ]]; then
  __LLM_CLI_CONFIG_UI=()
  __LLM_CLI_CONFIG_CYCLE=()
  __llm_cli_load_config "${__LLM_CLI_USER_CONFIG_DIR}/config.ini"
  : "${__LLM_CLI_CONFIG_UI[rprompt_format]:=llm-cli: %name %tag}"
  : "${__LLM_CLI_CONFIG_CYCLE[key_toggle]:=^X}"
  : "${__LLM_CLI_CONFIG_CYCLE[key_next]:=^N}"
  print -u2 "zsh-llm-cli: user override for config"
fi

# ============================================================================
# Backend loading
# ============================================================================

typeset -gA __LLM_CLI_BACKENDS_USER_SEEN=()

__llm_cli_load_backend() {
  emulate -L zsh
  local file="$1"
  local source_kind="$2"
  local name=
  local prefix=
  local bin=
  local tag=
  local args_joined=
  local use_sd=
  local is_override=
  __LLM_CLI_LOAD_DUPLICATE=0

  __llm_cli_parse_reset
  __llm_cli_parse_ini "$file"
  local parse_rc=$?
  if (( parse_rc != 0 )); then
    return $parse_rc
  fi

  name="$(__llm_cli_parse_get backend.name)"
  prefix="$(__llm_cli_parse_get backend.prefix)"
  bin="$(__llm_cli_parse_get backend.bin)"

  if [[ -z "$name" || -z "$prefix" || -z "$bin" ]]; then
    print -u2 "zsh-llm-cli: $file: missing [backend] name/prefix/bin (skipping)"
    return 0
  fi

  if [[ -n "${__LLM_CLI_BACKENDS_TAG[$name]:-}" ]] && [[ "$source_kind" == "builtin" ]]; then
    print -u2 "zsh-llm-cli: $file: duplicate backend name '$name' in main repo"
    __LLM_CLI_LOAD_DUPLICATE=1
    return 1
  fi

  tag="${prefix}[${name}]"

  is_override=0
  if [[ "$source_kind" == "user" ]]; then
    if [[ -n "${__LLM_CLI_BACKENDS_USER_SEEN[$name]:-}" ]]; then
      print -u2 "zsh-llm-cli: $file: duplicate backend name '$name' in user dir"
      __LLM_CLI_LOAD_DUPLICATE=1
      return 1
    fi
    if [[ -n "${__LLM_CLI_BACKENDS_TAG[$name]:-}" ]]; then
      is_override=1
    else
      __LLM_CLI_BACKENDS_USER_SEEN[$name]=1
    fi
  fi

  args_joined="$(__llm_cli_parse_get args.always)"
  use_sd="$(__llm_cli_parse_get stream.use_sd)"
  [[ -z "$use_sd" ]] && use_sd=auto

  if [[ "$is_override" == "1" ]]; then
    __LLM_CLI_BACKENDS_PREFIX[$name]="$prefix"
    __LLM_CLI_BACKENDS_TAG[$name]="$tag"
    __LLM_CLI_BACKENDS_BIN[$name]="$bin"
    __LLM_CLI_BACKENDS_ARGS[$name]="$args_joined"
    __LLM_CLI_BACKENDS_USE_SD[$name]="$use_sd"
    if [[ -z "${__LLM_CLI_BACKENDS_PREFIX_ACTIVE[$name]:-}" ]]; then
      __LLM_CLI_BACKENDS_PREFIX_ACTIVE[$name]=0
    fi
    print -u2 "zsh-llm-cli: user override for $name"
  else
    __LLM_CLI_BACKENDS_PREFIX[$name]="$prefix"
    __LLM_CLI_BACKENDS_TAG[$name]="$tag"
    __LLM_CLI_BACKENDS_BIN[$name]="$bin"
    __LLM_CLI_BACKENDS_ARGS[$name]="$args_joined"
    __LLM_CLI_BACKENDS_USE_SD[$name]="$use_sd"
    __LLM_CLI_BACKENDS_PREFIX_ACTIVE[$name]=0
    __LLM_CLI_BACKEND_ORDER+=("$name")
  fi

  return 0
}

__LLM_CLI_LOAD_DUPLICATE=0
local __llm_cli_f
for __llm_cli_f in "${__LLM_CLI_PLUGIN_DIR}"/backends/*.backend.ini(N); do
  __llm_cli_load_backend "$__llm_cli_f" "builtin"
  if (( __LLM_CLI_LOAD_DUPLICATE )); then
    print -u2 "zsh-llm-cli: aborting due to duplicate backend name in main repo"
    __LLM_CLI_BACKEND_ORDER=()
    break
  fi
done
unset __llm_cli_f

if [[ -d "${__LLM_CLI_USER_CONFIG_DIR}/backends" ]]; then
  for __llm_cli_f in "${__LLM_CLI_USER_CONFIG_DIR}"/backends/*.backend.ini(N); do
    __llm_cli_load_backend "$__llm_cli_f" "user"
    if (( __LLM_CLI_LOAD_DUPLICATE )); then
      print -u2 "zsh-llm-cli: aborting due to duplicate backend name in user dir"
      __LLM_CLI_BACKEND_ORDER=()
      break
    fi
  done
  unset __llm_cli_f
fi

if (( ${#__LLM_CLI_BACKEND_ORDER[@]} > 0 )); then
  __LLM_CLI_CURRENT_BACKEND_INDEX=1
  __LLM_CLI_CURRENT_BACKEND="${__LLM_CLI_BACKEND_ORDER[1]}"
  __LLM_CLI_BACKENDS_PREFIX_ACTIVE[$__LLM_CLI_CURRENT_BACKEND]=0
else
  __LLM_CLI_CURRENT_BACKEND_INDEX=0
  __LLM_CLI_CURRENT_BACKEND=
fi

# ============================================================================
# command_not_found_handler
# ============================================================================

if (( $+functions[command_not_found_handler] )); then
  functions[__llm_cli_original_command_not_found_handler]=$functions[command_not_found_handler]
fi

command_not_found_handler() {
  emulate -L zsh
  local first_token="$1"
  shift
  local -a rest=("$@")

  # Priority 1: explicit prefix in buffer (e.g. "💠[omp] foo bar") wins
  # over the active-mode fallback, so users can dispatch a different
  # backend on the fly without first toggling back to it.
  if [[ -n "$first_token" ]]; then
    local backend tag
    for backend in "${__LLM_CLI_BACKEND_ORDER[@]}"; do
      tag="${__LLM_CLI_BACKENDS_TAG[$backend]}"
      if [[ "$first_token" == "$tag" ]]; then
        __llm_cli_dispatch "$backend" "${rest[@]}"
        return $?
      fi
    done
  fi

  # Priority 2: active mode. Once Ctrl-X toggles prefix ON for the
  # currently-active backend, every unrecognised command in this shell
  # session is forwarded to that backend without needing the buffer
  # prefix. This is the "ctrl+x pressed -> RPROMPT shows backend -> all
  # subsequent commands route there" UX. Toggle Ctrl-X again to leave
  # active mode.
  local active_backend="${__LLM_CLI_CURRENT_BACKEND}"
  if [[ -n "$active_backend" \
        && "${__LLM_CLI_BACKENDS_PREFIX_ACTIVE[$active_backend]:-0}" == "1" \
        && -n "$first_token" ]]; then
    __llm_cli_dispatch "$active_backend" "$first_token" "${rest[@]}"
    return $?
  fi

  # Priority 3: original handler (or "command not found").
  if (( $+functions[__llm_cli_original_command_not_found_handler] )); then
    __llm_cli_original_command_not_found_handler "$first_token" "${rest[@]}"
    return $?
  fi
  if [[ -n "$first_token" ]]; then
    print -u2 "zsh: command not found: $first_token"
  fi
  return 127
}

__llm_cli_dispatch() {
  emulate -L zsh
  local backend="$1"
  shift
  local -a prompt_arr=("$@")

  local bin="${__LLM_CLI_BACKENDS_BIN[$backend]}"
  local tag="${__LLM_CLI_BACKENDS_TAG[$backend]}"

  if (( ${#prompt_arr[@]} == 0 )); then
    print -u2 "zsh-llm-cli: nothing to run after '$tag'."
    return 127
  fi

  if ! command -v "$bin" >/dev/null 2>&1; then
    if (( $+functions[__llm_cli_original_command_not_found_handler] )); then
      __llm_cli_original_command_not_found_handler "$tag" "${prompt_arr[@]}"
      return $?
    fi
    print -u2 "zsh-llm-cli: $bin: command not found; unable to handle '$tag'."
    return 127
  fi

  local -a argv=()
  local args_joined="${__LLM_CLI_BACKENDS_ARGS[$backend]:-}"
  if [[ -n "$args_joined" ]]; then
    local -a args_parts
    args_parts=("${(@s:|:)args_joined}")
    # Re-split each `always =` value on shell-word boundaries so users can
    # write `always = --agent orchestrator` instead of two separate
    # `always = --agent` / `always = orchestrator` lines. The (@z) flag is
    # zsh's shell-aware word-splitting: it honours quoting, so a value
    # like `--model="some name with spaces"` still works.
    local part
    for part in "${args_parts[@]}"; do
      local -a ws_parts
      ws_parts=("${(@z)part}")
      argv+=("${ws_parts[@]}")
    done
  fi
  argv+=("${(j: :)prompt_arr[@]}")

  local use_sd_setting="${__LLM_CLI_BACKENDS_USE_SD[$backend]:-auto}"
  local use_sd=0
  case "$use_sd_setting" in
    0) use_sd=0 ;;
    1)
      if command -v sd >/dev/null 2>&1; then
        use_sd=1
      else
        print -u2 "zsh-llm-cli: use_sd=1 but sd not found in \$PATH."
        return 127
      fi
      ;;
    *)
      if command -v sd >/dev/null 2>&1; then
        use_sd=1
      fi
      ;;
  esac

  if (( use_sd )); then
    "$bin" "${argv[@]}" | sd
    return $?
  else
    "$bin" "${argv[@]}"
    return $?
  fi
}

# ============================================================================
# ZLE widgets
# ============================================================================

__llm_cli_toggle_prefix() {
  emulate -L zsh
  local backend="${__LLM_CLI_CURRENT_BACKEND}"
  [[ -z "$backend" ]] && return 0

  local tag="${__LLM_CLI_BACKENDS_TAG[$backend]}"
  local tag_with_space="${tag} "
  local tag_len=${#tag_with_space}

  if [[ "$BUFFER" == "${tag_with_space}"* ]]; then
    BUFFER="${BUFFER#$tag_with_space}"
    if (( CURSOR > tag_len )); then
      CURSOR=$(( CURSOR - tag_len ))
    else
      CURSOR=0
    fi
    __LLM_CLI_BACKENDS_PREFIX_ACTIVE[$backend]=0
  else
    BUFFER="${tag_with_space}${BUFFER}"
    CURSOR=$(( CURSOR + tag_len ))
    __LLM_CLI_BACKENDS_PREFIX_ACTIVE[$backend]=1
  fi
}

__llm_cli_cycle_backend() {
  emulate -L zsh
  local n=${#__LLM_CLI_BACKEND_ORDER[@]}
  (( n == 0 )) && return 0

  local old_backend="${__LLM_CLI_CURRENT_BACKEND}"
  __LLM_CLI_CURRENT_BACKEND_INDEX=$(( (__LLM_CLI_CURRENT_BACKEND_INDEX % n) + 1 ))
  local new_backend="${__LLM_CLI_BACKEND_ORDER[$__LLM_CLI_CURRENT_BACKEND_INDEX]}"
  __LLM_CLI_CURRENT_BACKEND="$new_backend"

  # If the old active backend was in "prefix ON" state, swap the tag in the
  # buffer to the new active backend's tag and migrate the active bit.
  if [[ -n "$old_backend" \
        && "${__LLM_CLI_BACKENDS_PREFIX_ACTIVE[$old_backend]:-0}" == "1" ]]; then
    local old_tag="${__LLM_CLI_BACKENDS_TAG[$old_backend]} "
    local new_tag="${__LLM_CLI_BACKENDS_TAG[$new_backend]} "
    if [[ "$BUFFER" == "${old_tag}"* ]]; then
      BUFFER="${new_tag}${BUFFER#$old_tag}"
      CURSOR=$(( CURSOR + ${#new_tag} - ${#old_tag} ))
    fi
    __LLM_CLI_BACKENDS_PREFIX_ACTIVE[$new_backend]=1
    __LLM_CLI_BACKENDS_PREFIX_ACTIVE[$old_backend]=0
  fi

  zle reset-prompt
}

__llm_cli_line_init() {
  emulate -L zsh

  # Chain to the previous zle-line-init (if any) so other plugins' logic
  # (history expansion, etc.) still runs.
  if (( ${+widgets[.zle-line-init]} )); then
    zle .zle-line-init
  fi

  # If the current backend is in "prefix ON" state AND the buffer is empty,
  # seed the new line with the tag prefix. We MUST NOT overwrite a non-empty
  # buffer (e.g. when the user pulled a non-prefixed command from history
  # with up-arrow).
  local backend="${__LLM_CLI_CURRENT_BACKEND}"
  if [[ -n "$backend" \
        && "${__LLM_CLI_BACKENDS_PREFIX_ACTIVE[$backend]:-0}" == "1" \
        && -z "$BUFFER" ]]; then
    local tag="${__LLM_CLI_BACKENDS_TAG[$backend]} "
    BUFFER="$tag"
    CURSOR=${#BUFFER}
  fi
}

__llm_cli_line_pre_redraw() {
  emulate -L zsh

  # Guard cursor position when a tag prefix is active: cursor MUST stay at
  # or after the prefix (cannot enter the prefix zone).
  local backend="${__LLM_CLI_CURRENT_BACKEND}"
  if [[ -n "$backend" \
        && "${__LLM_CLI_BACKENDS_PREFIX_ACTIVE[$backend]:-0}" == "1" ]]; then
    local tag="${__LLM_CLI_BACKENDS_TAG[$backend]} "
    local tag_len=${#tag}
    if (( CURSOR < tag_len )); then
      CURSOR=$tag_len
    elif (( CURSOR > ${#BUFFER} )); then
      CURSOR=${#BUFFER}
    fi
  fi

  # Chain to the previous zle-line-pre-redraw (if any).
  if (( ${+widgets[.zle-line-pre-redraw]} )); then
    zle .zle-line-pre-redraw
  fi
}

__llm_cli_line_finish() {
  emulate -L zsh
  return 0
}

__llm_cli_guard_backward_action() {
  emulate -L zsh
  local backend="${__LLM_CLI_CURRENT_BACKEND}"
  if [[ -z "$backend" || "${__LLM_CLI_BACKENDS_PREFIX_ACTIVE[$backend]:-0}" != "1" ]]; then
    __llm_cli_call_guarded_original
    return
  fi

  local tag="${__LLM_CLI_BACKENDS_TAG[$backend]} "
  local tag_len=${#tag}

  if [[ "$BUFFER" == "${tag}"* ]] && (( CURSOR <= tag_len )); then
    zle beep 2>/dev/null
    return
  fi
  __llm_cli_call_guarded_original
}

__llm_cli_call_guarded_original() {
  emulate -L zsh
  local alias="${__LLM_CLI_GUARD_WIDGET_ALIASES[$WIDGET]-}"
  if [[ -n "$alias" ]]; then
    zle "$alias" 2>/dev/null
  else
    zle ".${WIDGET}" 2>/dev/null
  fi
}

__llm_cli_register_guard_widget() {
  emulate -L zsh
  local widget="$1"
  local alias="__llm_cli_prev_${widget//-/_}"

  if zle -A "$widget" "$alias" 2>/dev/null; then
    __LLM_CLI_GUARD_WIDGET_ALIASES[$widget]="$alias"
  else
    __LLM_CLI_GUARD_WIDGET_ALIASES[$widget]=""
  fi

  zle -N "$widget" __llm_cli_guard_backward_action
}

# ============================================================================
# Interactive-mode wiring
# ============================================================================

if [[ -o interactive ]]; then
  zle -N __llm_cli_toggle_prefix
  zle -N __llm_cli_cycle_backend

  local -a __llm_cli_keymaps=("emacs" "viins")
  local keymap
  for keymap in "${__llm_cli_keymaps[@]}"; do
    bindkey -M "$keymap" "${__LLM_CLI_CONFIG_CYCLE[key_toggle]}" __llm_cli_toggle_prefix 2>/dev/null
    bindkey -M "$keymap" "${__LLM_CLI_CONFIG_CYCLE[key_next]}"   __llm_cli_cycle_backend  2>/dev/null
  done
  unset keymap __llm_cli_keymaps

  if (( ! __LLM_CLI_WIDGETS_INSTALLED )); then
    zle -N zle-line-init __llm_cli_line_init
    zle -N zle-line-pre-redraw __llm_cli_line_pre_redraw
    zle -N zle-line-finish __llm_cli_line_finish

    __llm_cli_register_guard_widget backward-delete-char
    __llm_cli_register_guard_widget backward-kill-word
    __llm_cli_register_guard_widget vi-backward-delete-char
    __llm_cli_register_guard_widget vi-backward-kill-word

    __LLM_CLI_WIDGETS_INSTALLED=1
  fi
fi
