#!/usr/bin/env python3
"""Exercise real tmux mouse events on an isolated server; never touch personal sessions."""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parent.parent
TMUX = shutil.which('tmux')
if not TMUX:
    raise SystemExit('tmux 3.2+ is required')


def wait_for(predicate, label, timeout=4):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.03)
    raise AssertionError('Timed out: ' + label)


def locate_text(data, text, rows=30, columns=100):
    """Locate a label in tmux's VT repaint so clicks follow the actual menu position."""
    screen = [[' '] * columns for _ in range(rows)]
    row, column = 0, 0
    ansi = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|[()][0-9A-Za-z]|.)")
    decoded = data.decode('utf-8', errors='replace')
    end = 0
    for match in list(ansi.finditer(decoded)) + [None]:
        start = len(decoded) if match is None else match.start()
        for character in decoded[end:start]:
            if character == '\r': column = 0
            elif character == '\n': row += 1
            elif character == '\b': column = max(0, column - 1)
            elif character.isprintable():
                if 0 <= row < rows and 0 <= column < columns: screen[row][column] = character
                column += 1
        if match is None: break
        sequence = match.group()
        if sequence.startswith('\x1b['):
            command = sequence[-1]
            parameters = sequence[2:-1]
            if all(c.isdigit() or c == ';' for c in parameters):
                values = [int(v) if v else 1 for v in parameters.split(';')]
                if command in 'Hf': row, column = values[0] - 1, (values[1] if len(values) > 1 else 1) - 1
                elif command == 'd': row = values[0] - 1
                elif command == 'G': column = values[0] - 1
                elif command == 'A': row -= values[0]
                elif command == 'B': row += values[0]
                elif command == 'C': column += values[0]
                elif command == 'D': column -= values[0]
        end = match.end()
    for y, cells in enumerate(screen):
        line = ''.join(cells)
        if text in line: return line.index(text) + 2, y + 1
    raise AssertionError('Label not found in rendered menu: ' + text)


with tempfile.TemporaryDirectory(prefix='mini-term-menu-', dir='/private/tmp') as directory:
    socket = str(Path(directory) / 'tmux.sock')
    child = None
    master = None

    def tmux(*args):
        return subprocess.check_output([TMUX, '-S', socket, *args], text=True, stderr=subprocess.STDOUT).strip()

    def drain(duration=0.2):
        data = bytearray()
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            if select.select([master], [], [], max(0, deadline - time.monotonic()))[0]:
                try:
                    data.extend(os.read(master, 65536))
                except OSError:
                    break
        return bytes(data)

    def tap(x, y):
        # Ghostty sends the new mouse position before the press/release pair.
        os.write(master, f'\x1b[<35;{x};{y}M\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m'.encode())

    try:
        names = ['alpha', 'beta', 'space name', '-leading', 'quote\'"name', '#{session_name}']
        tmux('-f', '/dev/null', 'new-session', '-d', '-s', names[0], '-x', '100', '-y', '30', 'sleep 60')
        for name in names[1:]:
            tmux('new-session', '-d', '-s', name.replace('#', '##'), 'sleep 60')
        tmux('source-file', str(ROOT / 'Config/mini-term.tmux.conf'))
        tmux('set-option', '-g', '@mini-term-menu-script', str(ROOT / 'Scripts/tmux-session-menu.sh'))
        child, master = pty.fork()
        if child == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.environ.pop('TMUX', None)
            os.execv(TMUX, [TMUX, '-S', socket, 'attach-session', '-t', 'alpha'])
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
        wait_for(lambda: tmux('list-clients', '-F', '#{session_name}') == 'alpha', 'attach alpha')
        drain()

        # A complete finger tap must leave the menu open, ready for another tap/key.
        tap(2, 30)
        menu = drain(0.4)
        assert b'Switch session' in menu, repr(menu[:1000])
        assert b'beta' in menu and b'space name' in menu and b'-leading' in menu, repr(menu[-1200:])
        assert b'#{session_name}' in menu, 'A session name was interpreted as a tmux format'
        # A second finger tap selects beta in the popup above the status line.
        beta_x, beta_y = locate_text(menu, ' beta')
        tap(beta_x, beta_y)
        wait_for(lambda: tmux('list-clients', '-F', '#{session_name}') == 'beta', 'switch to beta')
        drain()
        print('PASS: status tap opens persistent popup; names are quoted; selection switches attached client.')

        # Also support a status bar at the top; the popup must follow it.
        tmux('set-option', '-g', 'status-position', 'top')
        drain()
        tap(2, 1)
        top_menu = drain(0.4)
        quote_name = 'quote\'"name'
        quote_x, quote_y = locate_text(top_menu, ' ' + quote_name)
        tap(quote_x, quote_y)
        wait_for(lambda: tmux('list-clients', '-F', '#{session_name}') == quote_name, 'top-status popup with quoted name')
        drain()
        print('PASS: top status bars open a popup below them; quoted-name sessions switch correctly.')

        # On short displays, use a scrollable tree instead of a menu that cannot fit.
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 8, 100, 0, 0))
        wait_for(lambda: tmux('list-clients', '-F', '#{client_height}') == '8', 'resize client')
        drain()
        tap(2, 1)
        drain()
        wait_for(lambda: tmux('display-message', '-p', '-t', quote_name, '#{pane_mode}') == 'tree-mode', 'short-screen tree fallback')
        os.write(master, b'q')
        print('PASS: short displays fall back to tmux’s scrollable session tree.')
    finally:
        subprocess.run([TMUX, '-S', socket, 'kill-server'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if child:
            try:
                os.waitpid(child, 0)
            except ChildProcessError:
                pass
        if master is not None:
            os.close(master)
