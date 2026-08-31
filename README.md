# tmux-session

Save and restore a single tmux session: windows, pane splits (layout), and working directories.

## Install

1. Copy the script somewhere on your `PATH` (recommended):

```bash
mkdir -p ~/.local/bin
cp tmux-session.sh ~/.local/bin/tmux-session.sh
chmod +x ~/.local/bin/tmux-session.sh
```

2. Make sure `~/.local/bin` is in your `PATH` (usually already true on Fedora).

3. Requires `tmux` installed.

The session state is stored at:

```text
~/.config/tmux/tmux_session.txt
```

## Usage

```bash
# Attach to session "main", or restore it from backup if it does not exist
tmux-session.sh start

# Save the current layout of session "main"
tmux-session.sh save

# Force restore from backup (when the session is gone)
tmux-session.sh restore
```

On attach, the script registers an `EXIT` trap and saves the session when you detach/close.

## Keyboard shortcut (GNOME / Fedora)

Bind a custom shortcut to open your default terminal with:

```bash
xdg-terminal-exec -- ~/.local/bin/tmux-session.sh start
```

Alternatives:

```bash
ptyxis -- ~/.local/bin/tmux-session.sh start
gnome-terminal -- ~/.local/bin/tmux-session.sh start
```

## Notes

- The managed session name is `main` (see `SESSION_NAME` in the script).
- Window indexes with gaps (e.g. `0, 1, 17`) are remapped to sequential tabs on restore.
- Running commands and scrollback are not restored — only windows, split layout, and cwd per pane.

### Tips

Config in `nano ~/.tmux.conf`

```
set -g mouse on # Enable mouse

# Splits (Ctrl + direction)
bind-key -n C-Left select-pane -L
bind-key -n C-Right select-pane -R
bind-key -n C-Up select-pane -U
bind-key -n C-Down select-pane -D

# Windows (Alt + direction)
bind-key -n M-Left previous-window
bind-key -n M-Right next-window
```

Reload config: `tmux source-file ~/.tmux.conf`

Cron: `*/5 * * * * /home/USER/.local/bin/tmux-session.sh save`