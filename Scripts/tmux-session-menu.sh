#!/bin/sh
# Invoked by the tmux mouse binding. Only stable session IDs enter commands;
# labels travel as argv values, never as generated shell/tmux source code.
set -eu
socket=$1
client=$2
tmux_bin=${TMUX_PROGRAM:-tmux}

sessions=$("$tmux_bin" -S "$socket" list-sessions -F '#{session_id}')
height=$("$tmux_bin" -S "$socket" display-message -p -c "$client" '#{client_height}')
count=$(printf '%s\n' "$sessions" | wc -l | tr -d ' ')
case "$height" in ''|*[!0-9]*) height=0 ;; esac
if [ "$count" -gt "$((height - 5))" ]; then
    # Give the command the invoking client's pane, not the server's most recent pane.
    pane=$("$tmux_bin" -S "$socket" display-message -p -c "$client" '#{pane_id}')
    exec "$tmux_bin" -S "$socket" choose-tree -Zs -t "$pane"
fi

# -O keeps the menu open after the opening finger is released; -M handles taps
# even though it is being presented by a command client rather than a key event.
set -- display-menu -O -M -c "$client" -T 'Switch session' -x 0 -y S
for session_id in $sessions; do
    # The list above contains only tmux-generated $<digits> IDs.
    case "$session_id" in '$'*) ;; *) continue ;; esac
    if ! name=$("$tmux_bin" -S "$socket" display-message -p -t "$session_id" '#{session_name}' 2>/dev/null); then
        continue # A session may exit while the popup is being constructed.
    fi
    # Labels are tmux formats: escape # and flatten controls; a leading space
    # keeps session names beginning with '-' selectable instead of disabled.
    label=$(printf '%s' "$name" | tr '\n\r\t' '   ' | sed 's/#/##/g')
    set -- "$@" " $label" '' "switch-client -t '$session_id'"
done
exec "$tmux_bin" -S "$socket" "$@"
