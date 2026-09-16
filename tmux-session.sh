#!/usr/bin/env bash

SESSION_NAME="main"
BACKUP_FILE="$HOME/.config/tmux/tmux_session.txt"
SCRIPT_PATH="$(readlink -f "$0")"

mkdir -p "$(dirname "$BACKUP_FILE")"

# Backup format (layout always last on W lines — may contain commas):
#   W::<window_index>::<window_name>::<active_pane_index>::<window_layout>
#   P::<window_index>::<pane_index>::<pane_id>::<pane_current_path>
#   ACTIVE::<window_index>

# Trim leading/trailing whitespace without xargs (paths/names may contain spaces).
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# tmux layout checksum (same algorithm as layout.c) over the part after "xxxx,".
layout_checksum() {
    local s="$1"
    local csum=0
    local i c
    for ((i = 0; i < ${#s}; i++)); do
        printf -v c '%d' "'${s:i:1}"
        csum=$(((csum >> 1) + ((csum & 1) << 15)))
        csum=$(((csum + c) & 0xffff))
    done
    printf '%04x' "$csum"
}

# Replace saved pane IDs in a layout with IDs of newly created panes, then fix checksum.
# Args after layout: old_id new_id old_id new_id ...
remap_layout() {
    local layout="$1"
    shift
    local rest old new token i line
    local -a tokens=()
    local -a pairs=()
    rest="${layout#????,}"

    while [ "$#" -ge 2 ]; do
        pairs+=("${1#%}:${2#%}")
        shift 2
    done

    # Longer IDs first so 12 is not partially eaten by 1
    mapfile -t pairs < <(printf '%s\n' "${pairs[@]}" | awk -F: '{ print length($1), $0 }' | sort -rn | cut -d' ' -f2-)

    i=0
    for line in "${pairs[@]}"; do
        old="${line%%:*}"
        new="${line#*:}"
        token="__TMUXPANE_${i}__"
        tokens+=("$token" "$new")
        rest=$(printf '%s' "$rest" | sed -E "s/,${old}([,}{])/,${token}\1/g; s/,${old}\$/,${token}/")
        i=$((i + 1))
    done

    i=0
    while [ "$i" -lt "${#tokens[@]}" ]; do
        token="${tokens[$i]}"
        new="${tokens[$((i + 1))]}"
        rest="${rest//$token/$new}"
        i=$((i + 2))
    done

    printf '%s,%s' "$(layout_checksum "$rest")" "$rest"
}

save_tmux() {
    if ! tmux info &>/dev/null; then
        echo "tmux server is not running. Nothing to save."
        return 1
    fi

    if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "Session '$SESSION_NAME' not found. Nothing to save."
        return 1
    fi

    > "$BACKUP_FILE"

    # Windows: all tabs, with exact split layout string
    tmux list-windows -t "$SESSION_NAME" -F \
        'W::#{window_index}::#{window_name}::#{pane_index}::#{window_layout}' \
        >> "$BACKUP_FILE"

    # Panes across the whole session (-s), with pane_id for layout remap on restore
    tmux list-panes -s -t "$SESSION_NAME" -F \
        'P::#{window_index}::#{pane_index}::#{pane_id}::#{pane_current_path}' \
        >> "$BACKUP_FILE"

    # Remember which window was active
    active_idx=$(
        tmux list-windows -t "$SESSION_NAME" -F '#{window_index} #{window_active}' \
            | awk '$2 == 1 { print $1; exit }'
    )
    if [ -n "$active_idx" ]; then
        echo "ACTIVE::$active_idx" >> "$BACKUP_FILE"
    fi

    echo "tmux state saved successfully."
}

attach_session() {
    trap 'tmux has-session -t "$SESSION_NAME" 2>/dev/null && "$SCRIPT_PATH" save' EXIT

    tmux attach-session -t "$SESSION_NAME" \; set-option destroy-unattached on
}

restore_tmux() {
    if [ ! -f "$BACKUP_FILE" ] || [ ! -s "$BACKUP_FILE" ]; then
        tmux new-session -s "$SESSION_NAME" \; set-option destroy-unattached on
        return 0
    fi

    declare -A win_name win_layout win_active_pane
    declare -A pane_path pane_old_id
    declare -a win_order
    declare -A win_seen
    active_old_idx=""

    while read -r line || [ -n "$line" ]; do
        [[ -z "${line// }" ]] && continue

        case "$line" in
            W::*)
                rest="${line#W::}"
                w_idx="${rest%%::*}"
                rest="${rest#*::}"
                w_name="${rest%%::*}"
                rest="${rest#*::}"
                a_pane="${rest%%::*}"
                w_layout="${rest#*::}"

                w_idx=$(trim "$w_idx")
                w_name=$(trim "$w_name")
                a_pane=$(trim "$a_pane")

                [ -z "$w_idx" ] && continue
                win_name[$w_idx]="$w_name"
                win_layout[$w_idx]="$w_layout"
                win_active_pane[$w_idx]="$a_pane"
                if [ -z "${win_seen[$w_idx]:-}" ]; then
                    win_order+=("$w_idx")
                    win_seen[$w_idx]=1
                fi
                ;;
            P::*)
                rest="${line#P::}"
                w_idx="${rest%%::*}"
                rest="${rest#*::}"
                p_idx="${rest%%::*}"
                rest="${rest#*::}"
                p_id="${rest%%::*}"
                p_path="${rest#*::}"

                w_idx=$(trim "$w_idx")
                p_idx=$(trim "$p_idx")
                p_id=$(trim "$p_id")
                p_path=$(trim "$p_path")

                [ -z "$w_idx" ] || [ -z "$p_idx" ] && continue
                [ -d "$p_path" ] || p_path="$HOME"
                pane_path["$w_idx:$p_idx"]="$p_path"
                pane_old_id["$w_idx:$p_idx"]="${p_id#%}"
                ;;
            ACTIVE::*)
                active_old_idx=$(trim "${line#ACTIVE::}")
                ;;
        esac
    done < "$BACKUP_FILE"

    if [ "${#win_order[@]}" -eq 0 ]; then
        echo "Backup has no windows. Starting a clean session."
        tmux new-session -s "$SESSION_NAME" \; set-option destroy-unattached on
        return 0
    fi

    declare -A window_map
    next_new_idx=0

    for w_idx in "${win_order[@]}"; do
        w_name="${win_name[$w_idx]}"
        w_layout="${win_layout[$w_idx]}"
        a_pane="${win_active_pane[$w_idx]:-0}"

        # Pane indexes for this window, sorted numerically
        mapfile -t p_indexes < <(
            for key in "${!pane_path[@]}"; do
                [ "${key%%:*}" = "$w_idx" ] && printf '%s\n' "${key#*:}"
            done | sort -n
        )

        if [ "${#p_indexes[@]}" -eq 0 ]; then
            p_indexes=(0)
            pane_path["$w_idx:0"]="$HOME"
        fi

        first_path="${pane_path[$w_idx:${p_indexes[0]}]}"
        [ -d "$first_path" ] || first_path="$HOME"

        if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
            tmux new-session -d -s "$SESSION_NAME" -n "$w_name" -c "$first_path"
        else
            tmux new-window -d -t "$SESSION_NAME" -n "$w_name" -c "$first_path"
        fi
        mapped_idx=$next_new_idx
        window_map[$w_idx]=$mapped_idx
        next_new_idx=$((next_new_idx + 1))

        target="$SESSION_NAME:$mapped_idx"

        # Create remaining panes (split direction does not matter; layout fixes geometry)
        for p_idx in "${p_indexes[@]:1}"; do
            p_path="${pane_path[$w_idx:$p_idx]}"
            [ -d "$p_path" ] || p_path="$HOME"
            tmux split-window -d -t "$target" -c "$p_path"
        done

        # Map old pane IDs -> new pane IDs (by pane_index order) and apply layout
        mapfile -t new_ids < <(tmux list-panes -t "$target" -F '#{pane_id}' | tr -d '%')
        remap_args=()
        i=0
        for p_idx in "${p_indexes[@]}"; do
            old_id="${pane_old_id[$w_idx:$p_idx]:-}"
            new_id="${new_ids[$i]:-}"
            if [ -n "$old_id" ] && [ -n "$new_id" ]; then
                remap_args+=("$old_id" "$new_id")
            fi
            i=$((i + 1))
        done

        if [ -n "$w_layout" ] && [ "${#remap_args[@]}" -gt 0 ]; then
            new_layout=$(remap_layout "$w_layout" "${remap_args[@]}")
            tmux select-layout -t "$target" "$new_layout" 2>/dev/null \
                || tmux select-layout -t "$target" "$w_layout" 2>/dev/null \
                || true
        elif [ -n "$w_layout" ]; then
            tmux select-layout -t "$target" "$w_layout" 2>/dev/null || true
        fi

        # Focus the pane that was active in this window
        if [[ "$a_pane" =~ ^[0-9]+$ ]]; then
            tmux select-pane -t "$target.$a_pane" 2>/dev/null || true
        fi
    done

    # Focus the window that was active when saving
    if [ -n "$active_old_idx" ] && [ -n "${window_map[$active_old_idx]:-}" ]; then
        tmux select-window -t "$SESSION_NAME:${window_map[$active_old_idx]}" 2>/dev/null || true
    fi

    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        attach_session
    else
        echo "Failed to restore session from $BACKUP_FILE"
        tmux new-session -s "$SESSION_NAME" \; set-option destroy-unattached on
    fi
}

start_tmux() {
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        attach_session
    else
        restore_tmux
    fi
}

case "$1" in
    save)    save_tmux ;;
    restore) restore_tmux ;;
    start)   start_tmux ;;
    *)
        echo "Usage: $0 {start|save|restore}"
        echo ""
        echo "  start   - attach to the single session or restore from backup"
        echo "  save    - save the current state of session '$SESSION_NAME'"
        echo "  restore - force restore from backup (when no session exists)"
        exit 1
        ;;
esac
