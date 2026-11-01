#!/usr/bin/env python3
"""Install the optional status-line picker on the Mac running tmux."""
import argparse
from datetime import datetime
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--config', type=Path, help='tmux config to include from (auto-detects gpakosz .local)')
parser.add_argument('--no-reload', action='store_true', help='install for next tmux startup only')
args = parser.parse_args()

home = Path.home()
main_config = home / '.tmux.conf'
config = args.config
if config is None:
    is_gpakosz = main_config.exists() and 'gpakosz/.tmux' in main_config.read_text()
    config = home / '.tmux.conf.local' if is_gpakosz else main_config
config = config.expanduser()
existing = config.read_text() if config.exists() else ''
source_line = 'source-file -q "$HOME/.config/mini-term/mini-term.tmux.conf"'

install_dir = home / '.config/mini-term'
install_dir.mkdir(parents=True, exist_ok=True)
shutil.copy2(ROOT / 'Config/mini-term.tmux.conf', install_dir / 'mini-term.tmux.conf')
shutil.copy2(ROOT / 'Scripts/tmux-session-menu.sh', install_dir / 'tmux-session-menu.sh')
if source_line not in existing.splitlines():
    if config.exists():
        backup = config.with_name(config.name + '.mini-term-backup-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
        shutil.copy2(config, backup)
        print(f'Backed up {config} to {backup}')
    block = '\n# Mini Term: tap the status-line session name to switch sessions.\n' + source_line + '\n'
    # gpakosz .local files contain an embedded shell payload after this marker.
    # Keep tmux commands in the customization section, before that payload.
    marker = '# -- custom variables '
    index = existing.find(marker)
    updated = existing[:index] + block + '\n' + existing[index:] if index >= 0 else existing.rstrip() + '\n' + block
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text(updated)
    print(f'Added include to {config}')
else:
    print(f'Include already present in {config}')
print(f'Installed popup files in {install_dir}')

if not args.no_reload:
    tmux = shutil.which('tmux')
    if tmux is None:
        raise SystemExit('Installed; tmux was not found, so live configuration was not reloaded.')
    if subprocess.run([tmux, 'list-sessions'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        subprocess.run([tmux, 'source-file', str(install_dir / 'mini-term.tmux.conf')], check=True)
        print('Enabled on the running tmux server. Existing sessions remain running.')
    else:
        print('No running tmux server; configuration will load at next startup.')
