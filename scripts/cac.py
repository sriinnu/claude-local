#!/usr/bin/env python3
"""cac: a terminal chat wrapper around headless Claude Code (`claude -p` over stream-json).

Stdlib only. One thread, one select loop over the keyboard and claude's output, so typing and
streaming never fight over the screen. claude runs in its own session and never sees the keyboard;
every keystroke lands here first, which is what makes Shift+Tab, Ctrl-C and y/n approvals work.

The launcher lives in claude_config.zsh (`cac`), which scrubs the env and adds --settings.
Every argument is passed on to claude.
"""
from __future__ import annotations

import codecs
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import termios
import textwrap
import time
import unicodedata
import uuid

MODES = ("default", "acceptEdits", "plan", "auto", "dontAsk")
CYCLE = ("default", "acceptEdits", "plan", "auto")  # Shift+Tab order
DEFAULT_MODE = "auto"
SYSTEM_NOTE = (
    "This session runs in cac, a terminal wrapper around headless Claude Code. Tool approvals that "
    "need the user appear as y/n prompts they answer here. The user changes permission mode with "
    "Shift+Tab or /mode <" + "|".join(MODES) + ">. AskUserQuestion is unavailable: ask in plain text."
)
HELP = (
    "enter send · ctrl-j or alt-enter newline · \\ then enter newline\n"
    "ctrl-c stop the reply, or clear the line · ctrl-d quit · up/down history\n"
    "shift+tab cycle mode · /mode <" + "|".join(MODES) + ">\n"
    "ctrl-o or /view: concise (one-line thinking gist) or detailed (full summary, tool output)\n"
    "/exit quit · other /commands go to claude"
)
NOISE = "claude.ai connectors are disabled"  # printed on every API-key start, says nothing useful
GATE_SECONDS = 0.25  # keys this soon after an approval prompt appears can't answer it
PAUSE_SECONDS = 0.5  # an answer must follow a pause, or it's someone still typing their next message
FORCE_AFTER_SECONDS = 1.5  # a second ctrl-c sooner than this is impatience, not "kill it"
WAKE_RELEASE_SECONDS = 3.0  # output outside a turn has no result to end it; give the keyboard back
HISTORY_MAX = 500
HISTORY_ENTRY_MAX = 8192
COLLAPSE_ROWS = 12
DETAIL_RESULT_LINES = 12


class Style:
    def __init__(self, on: bool):
        code = (lambda s: f"\x1b[{s}m") if on else (lambda s: "")
        self.you = code("1;36")
        self.mark = code("35")
        self.dim = code("2")
        self.off = code("0")
        self.code = code("33")
        self.bold = code("1")
        self.head = code("1;35")
        self.err = code("31")
        self.warn = code("1;33")


def sanitize(text: str) -> str:
    """Drop control characters so model or tool output can't drive the terminal."""
    return "".join(
        c for c in text
        if c in "\n\t" or not (ord(c) < 0x20 or 0x7f <= ord(c) <= 0x9f)
    )


def cell_width(c: str) -> int:
    if c == "\t":
        return 4
    if c == "\ufe0f":
        return 1  # emoji presentation: the terminal draws the 1-cell base as 2
    if unicodedata.combining(c) or unicodedata.category(c) in ("Mn", "Me", "Cf"):
        return 0
    return 2 if unicodedata.east_asian_width(c) in ("W", "F") else 1


def text_width(s: str) -> int:
    return sum(cell_width(c) for c in s)


def fit(s: str, cells: int) -> str:
    """Trim s to at most `cells` terminal cells, on one line."""
    s = " ".join(sanitize(s).split())
    if text_width(s) <= cells:
        return s
    out, used = [], 0
    for c in s:
        used += cell_width(c)
        if used > cells - 1:
            break
        out.append(c)
    return "".join(out) + "…"


def fit_path(s: str, cells: int) -> str:
    """Like fit, but keep the tail: the end of a path is the part that identifies it."""
    s = sanitize(s).replace("\n", " ")
    if text_width(s) <= cells:
        return s
    out, used = [], 1
    for c in reversed(s):
        used += cell_width(c)
        if used > cells:
            break
        out.append(c)
    return "…" + "".join(reversed(out))


def wrap_cells(s: str, cells: int) -> list:
    """Break one line into rows without losing anything."""
    rows, row, used = [], [], 0
    for c in s:
        w = cell_width(c)
        if used + w > cells and row:
            rows.append("".join(row))
            row, used = [], 0
        row.append("    " if c == "\t" else c)
        used += w
    rows.append("".join(row))
    return rows


def sentences(text: str) -> list:
    """Split thinking into sentences, without markdown decoration."""
    clean = re.sub(r"[*#`]+", "", text)
    return [x.strip() for x in re.split(r"(?<=[.!?])\s+|\n+", clean) if x.strip()]


def gist_of(text: str) -> str:
    """The first real sentence. A short first line is usually just a heading."""
    parts = sentences(text)
    for part in parts:
        if len(part.split()) >= 4:
            return part
    return parts[0] if parts else ""


def human(n: int) -> str:
    return f"{n / 1000:.1f}k" if n >= 1000 else str(n)


class KeyParser:
    """Turns raw terminal bytes into ("char", s), ("paste", s) and ("key", name) events."""

    CSI = {
        "A": "up", "B": "down", "C": "right", "D": "left", "H": "home", "F": "end", "Z": "shift-tab",
        "1~": "home", "7~": "home", "4~": "end", "8~": "end", "3~": "delete",
        "1;5C": "word-right", "1;3C": "word-right", "1;5D": "word-left", "1;3D": "word-left",
        "13;2u": "newline", "27;2;13~": "newline",
    }
    PASTE_END = "\x1b[201~"

    def __init__(self):
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.buf = ""
        self.paste = None  # text so far while inside a bracketed paste
        self.pending_since = None

    def feed(self, data: bytes) -> list:
        text = self.decoder.decode(data)
        # A terminal without bracketed paste delivers a paste as one burst. Nobody types a line
        # break followed by more text inside one read, so don't let it fire several sends.
        if (self.paste is None and not self.buf and "\x1b" not in text
                and re.search(r"[\r\n]", text.rstrip("\r\n"))):
            return [("paste", text)]
        self.buf += text
        return self._parse()

    def flush(self) -> list:
        """A lone ESC or a cut-off sequence has timed out."""
        lone = self.buf == "\x1b"
        self.buf = ""
        self.pending_since = None
        return [("key", "esc")] if lone else []

    def _parse(self) -> list:
        events = []
        self.pending_since = None
        while self.buf:
            if self.paste is not None:
                end = self.buf.find(self.PASTE_END)
                if end >= 0:
                    events.append(("paste", self.paste + self.buf[:end]))
                    self.paste = None
                    self.buf = self.buf[end + len(self.PASTE_END):]
                    continue
                keep = len(self.PASTE_END) - 1  # the end marker may be split across reads
                self.paste += self.buf[:-keep] if len(self.buf) > keep else ""
                self.buf = self.buf[-keep:] if len(self.buf) > keep else self.buf
                break
            c = self.buf[0]
            if c == "\x1b":
                used = self._escape(events)
                if used == 0:
                    self.pending_since = time.monotonic()
                    break
                self.buf = self.buf[used:]
            elif c == "\r":
                events.append(("key", "enter"))
                self.buf = self.buf[1:]
            elif c == "\n":
                events.append(("key", "newline"))
                self.buf = self.buf[1:]
            elif c in "\x7f\x08":
                events.append(("key", "backspace"))
                self.buf = self.buf[1:]
            elif c == "\t":
                events.append(("char", "\t"))
                self.buf = self.buf[1:]
            elif ord(c) < 0x20:
                events.append(("key", "ctrl-" + chr(ord(c) + 96)))
                self.buf = self.buf[1:]
            else:
                m = re.match(r"[^\x00-\x1f\x7f]+", self.buf)
                events.append(("char", m.group()))
                self.buf = self.buf[m.end():]
        return events

    def _escape(self, events: list) -> int:
        """Handle the escape sequence at the start of buf. Returns chars used, 0 if incomplete."""
        b = self.buf
        if len(b) < 2:
            return 0
        n = b[1]
        if n == "[":
            m = re.match(r"\x1b\[([0-?]*[ -/]*)([@-~])", b)
            if not m:
                # Still gathering parameters, or garbage we should stop waiting on.
                return 0 if re.fullmatch(r"\x1b\[[0-?]*[ -/]*", b) else 2
            seq = m.group(1) + m.group(2)
            if seq == "200~":
                self.paste = ""
            elif seq in self.CSI:
                events.append(("key", self.CSI[seq]))
            return m.end()
        if n == "O":
            if len(b) < 3:
                return 0
            name = self.CSI.get(b[2])
            if name:
                events.append(("key", name))
            return 3
        alt = {"\r": "newline", "\n": "newline", "b": "word-left", "f": "word-right",
               "d": "kill-word", "\x7f": "kill-word-back"}.get(n)
        if alt:
            events.append(("key", alt))
            return 2
        events.append(("key", "esc"))
        return 1


class Editor:
    """Multi-line input with its own redraw. Nothing it draws touches the scrollback above it."""

    def __init__(self, style: Style, write, flush):
        self.s = style
        self.write = write
        self.flush = flush
        self.buf = ""
        self.pos = 0
        self.prompt = "› "
        self.drawn = False
        self.cursor_row = 0  # row of the cursor inside the drawn block
        self.drawn_width = 0
        self.kill = ""
        self.history = []
        self.hist_at = None
        self.draft = ""

    # ---- layout and drawing -------------------------------------------------------------
    def _layout(self, width: int):
        """Wrap the buffer into rows. Returns (rows, cursor_row, cursor_col); col excludes the prefix."""
        room = max(10, width - 1 - text_width(self.prompt))
        rows, row, col = [], [], 0
        cur = (0, 0)
        for i, c in enumerate(self.buf):
            if i == self.pos:
                cur = (len(rows), col)
            if c == "\n":
                rows.append("".join(row))
                row, col = [], 0
                continue
            w = cell_width(c)
            if col + w > room:
                rows.append("".join(row))
                row, col = [], 0
                if i == self.pos:
                    cur = (len(rows), 0)
            row.append("    " if c == "\t" else c)
            col += w
        if self.pos >= len(self.buf):
            cur = (len(rows), col)
        rows.append("".join(row))
        return rows, cur[0], cur[1]

    def draw(self):
        size = shutil.get_terminal_size((80, 24))
        rows, cr, cc = self._layout(size.columns)
        limit = max(1, size.lines - 2)
        top = 0
        if len(rows) > limit:
            top = max(0, min(cr - limit // 2, len(rows) - limit))
        shown = rows[top:top + limit]
        pad = " " * text_width(self.prompt)
        more = "⋮ ".rjust(len(pad))
        lines = []
        for i, row in enumerate(shown):
            if i == 0 and top == 0:
                prefix = self.prompt
            elif (i == 0 and top > 0) or (i == len(shown) - 1 and top + limit < len(rows)):
                prefix = more
            else:
                prefix = pad
            lines.append(f"{self.s.you}{prefix}{row}{self.s.off}")
        self.clear()
        self.write("\n".join(lines))
        up = len(shown) - 1 - (cr - top)
        if up:
            self.write(f"\x1b[{up}A")
        self.write(f"\r\x1b[{len(pad) + cc}C" if len(pad) + cc else "\r")
        self.cursor_row = cr - top
        self.drawn = True
        self.drawn_width = size.columns
        self.flush()

    def clear(self):
        if self.drawn:
            if self.cursor_row:
                self.write(f"\x1b[{self.cursor_row}A")
            self.write("\r\x1b[J")
        self.drawn = False
        self.cursor_row = 0

    def finish(self):
        """Leave the submitted text in the scrollback; long pastes are collapsed."""
        self.clear()
        width = shutil.get_terminal_size((80, 24)).columns
        rows, _, _ = self._layout(width)
        hidden = 0
        if len(rows) > COLLAPSE_ROWS:
            hidden = len(rows) - 8
            rows = rows[:8]
        pad = " " * text_width(self.prompt)
        for i, row in enumerate(rows):
            self.write(f"{self.s.you}{self.prompt if i == 0 else pad}{row}{self.s.off}\n")
        if hidden:
            self.write(f"{pad}{self.s.dim}… +{hidden} more lines{self.s.off}\n")
        self.flush()

    def reset(self):
        self.buf, self.pos = "", 0
        self.hist_at = None
        self.draft = ""

    # ---- editing ------------------------------------------------------------------------
    def insert(self, text: str):
        self.buf = self.buf[:self.pos] + text + self.buf[self.pos:]
        self.pos += len(text)
        self.hist_at = None

    def paste(self, text: str):
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        self.insert(sanitize(text))

    def _line_start(self) -> int:
        return self.buf.rfind("\n", 0, self.pos) + 1

    def _line_end(self) -> int:
        end = self.buf.find("\n", self.pos)
        return len(self.buf) if end < 0 else end

    def _word_left(self) -> int:
        i = self.pos
        while i > 0 and self.buf[i - 1].isspace():
            i -= 1
        while i > 0 and not self.buf[i - 1].isspace():
            i -= 1
        return i

    def _word_right(self) -> int:
        i = self.pos
        n = len(self.buf)
        while i < n and self.buf[i].isspace():
            i += 1
        while i < n and not self.buf[i].isspace():
            i += 1
        return i

    def _vertical(self, delta: int) -> bool:
        """Move between logical lines. False if already on the first or last one."""
        start = self._line_start()
        col = self.pos - start
        if delta < 0:
            if start == 0:
                return False
            prev = self.buf.rfind("\n", 0, start - 1) + 1
            self.pos = min(prev + col, start - 1)
        else:
            end = self._line_end()
            if end == len(self.buf):
                return False
            next_end = self.buf.find("\n", end + 1)
            next_end = len(self.buf) if next_end < 0 else next_end
            self.pos = min(end + 1 + col, next_end)
        return True

    def _history(self, delta: int):
        if not self.history:
            return
        if self.hist_at is None:
            if delta > 0:
                return
            self.draft = self.buf
            at = len(self.history) - 1
        else:
            at = self.hist_at + delta
            if at < 0:
                return
        if at >= len(self.history):
            self.buf, self.hist_at = self.draft, None
        else:
            self.buf, self.hist_at = self.history[at], at
        self.pos = len(self.buf)

    def key(self, name: str) -> str | None:
        """Apply a key. Returns "submit" when the buffer should be sent."""
        b, p = self.buf, self.pos
        if name == "enter":
            if p == self._line_end() and b[:p].endswith("\\"):
                self.buf = b[:p - 1] + "\n" + b[p:]
                return None
            return "submit"
        if name == "newline":
            self.insert("\n")
        elif name == "left" or name == "ctrl-b":
            self.pos = max(0, p - 1)
        elif name == "right" or name == "ctrl-f":
            self.pos = min(len(b), p + 1)
        elif name == "home" or name == "ctrl-a":
            self.pos = self._line_start()
        elif name == "end" or name == "ctrl-e":
            self.pos = self._line_end()
        elif name == "word-left":
            self.pos = self._word_left()
        elif name == "word-right":
            self.pos = self._word_right()
        elif name == "up" or name == "ctrl-p":
            if not self._vertical(-1):
                self._history(-1)
        elif name == "down" or name == "ctrl-n":
            if not self._vertical(1):
                self._history(1)
        elif name == "backspace":
            if p:
                self.buf, self.pos = b[:p - 1] + b[p:], p - 1
        elif name == "delete" or name == "ctrl-d":
            self.buf = b[:p] + b[p + 1:]
        elif name == "ctrl-w" or name == "kill-word-back":
            i = self._word_left()
            self.kill, self.buf, self.pos = b[i:p], b[:i] + b[p:], i
        elif name == "kill-word":
            i = self._word_right()
            self.kill, self.buf = b[p:i], b[:p] + b[i:]
        elif name == "ctrl-u":
            i = self._line_start()
            self.kill, self.buf, self.pos = b[i:p], b[:i] + b[p:], i
        elif name == "ctrl-k":
            i = self._line_end()
            i = i + 1 if i == p and i < len(b) else i  # at end of line, join the next one
            self.kill, self.buf = b[p:i], b[:p] + b[i:]
        elif name == "ctrl-y":
            self.insert(self.kill)
        return None


class Renderer:
    """Streaming markdown-lite: wraps at word boundaries, styles fences, headings, bold and code.

    Deltas split anywhere, so it works character by character and holds only what it can't decide
    yet: the start of a line (fence or heading?), a lone `*`, and the word being built.
    Fenced code stays at column 0 and unwrapped so it copies clean.
    """

    HEAD = re.compile(r" {0,3}(?:`{1,6}|#{1,6})?")
    INDENT = "  "

    def __init__(self, style: Style, write, rich: bool):
        self.s = style
        self.write = write
        self.rich = rich
        self.open = False
        self._reset()

    def _reset(self):
        self.started = False
        self.col = 0
        self.pending_nl = 0
        self.in_head = True
        self.head = ""
        self.word = []
        self.word_w = 0
        self.star = False
        self.opening = False  # saw ** while not bold: it's markup only if text follows directly
        self.bold = False
        self.code = False
        self.heading = False
        self.fence = False
        self.fence_len = 0
        self.fence_info = None

    def text(self, s: str):
        self.open = True
        if not self.rich:
            self.write(s)
            return
        for ch in s:
            self._ch(ch)

    def end(self):
        if not self.open:
            return
        self.open = False
        if not self.rich:
            self.write("\n")
            return
        head, self.head = self.head, ""
        self.in_head = False
        if self.fence_info is not None:
            self._open_fence()
        if head:
            if self.fence and head.strip().startswith("`") and len(head.strip()) >= self.fence_len:
                self._close_fence()
            else:
                for c in head:
                    self._ch(c)
        if self.star:
            self.star = False
            self._emit("*")
        if self.opening:
            self.opening = False
            self._emit("*")
            self._emit("*")
        self._flush_word()
        if self.fence:
            self._close_fence()
        self.write(self.s.off + "\n")
        self._reset()

    def settle(self):
        """The stream paused: show the word being held instead of hiding it."""
        if self.open and self.rich:
            self._flush_word()

    def break_line(self):
        """Something else needs the screen mid-reply: finish this row so the next one starts clean."""
        if self.open and self.rich:
            self._flush_word()
            self.write(self.s.off + "\n")
            self.col = 0
            self.pending_nl = 0

    def _width(self) -> int:
        return shutil.get_terminal_size((80, 24)).columns - 1

    def _ch(self, ch: str):
        if self.in_head:
            candidate = self.head + ch
            if ch != "\n" and self.HEAD.fullmatch(candidate):
                self.head = candidate
                return
            head, self.head = self.head, ""
            self.in_head = False
            self._resolve_head(head, ch)
        elif self.fence_info is not None:
            if ch == "\n":
                self._open_fence()
                self.in_head = True
            else:
                self.fence_info += ch
        elif self.fence:
            self._fence_ch(ch)
        else:
            self._inline(ch)

    def _resolve_head(self, head: str, ch: str):
        mark = head.strip()
        if self.fence:
            if mark.startswith("`") and len(mark) >= self.fence_len and ch == "\n":
                self._close_fence()
                self.in_head = True
                return
            for c in head:
                self._fence_ch(c)
            self._fence_ch(ch)
            return
        if len(mark) >= 3 and mark[0] == "`":
            self.fence_len = len(mark)
            self.fence_info = ""
            if ch == "\n":
                self._open_fence()
                self.in_head = True
            else:
                self.fence_info = ch
            return
        if mark.startswith("#") and ch == " ":
            self.heading = True
            self.word.append(self.s.head)
            return
        for c in head:
            self._inline(c)
        self._inline(ch)

    # ---- inline text --------------------------------------------------------------------
    def _sgr(self) -> str:
        return self.s.off + (self.s.head if self.heading else "") + (
            self.s.bold if self.bold else "") + (self.s.code if self.code else "")

    def _inline(self, ch: str):
        if self.opening:
            self.opening = False
            if ch.isspace():  # `2 ** 10` is arithmetic, not bold
                self._emit("*")
                self._emit("*")
            else:
                self.bold = True
                self.word.append(self._sgr())
        if ch == "*" and not self.code:
            if self.star:
                self.star = False
                if self.bold:
                    self.bold = False
                    self.word.append(self._sgr())
                else:
                    self.opening = True
            else:
                self.star = True
            return
        if self.star:
            self.star = False
            self._emit("*")
        if ch == "`":
            self.code = not self.code
            self.word.append(self._sgr())
            return
        self._emit(ch)

    def _emit(self, ch: str):
        if ch == "\n":
            self._flush_word()
            if self.bold or self.code or self.heading:
                self.bold = self.code = self.heading = False
                self.write(self.s.off)
            self.pending_nl += 1
            self.in_head = True
        elif ch in " \t":
            self._flush_word()
            self._begin_line()
            if self.col + 1 < self._width():
                self.write(ch)
                self.col += 1
        else:
            self.word.append(ch)
            self.word_w += cell_width(ch)

    def _begin_line(self):
        if not self.started:
            self.write(f"\n{self.s.mark}◆{self.s.off} ")
            self.started = True
            self.col = 2
            self.pending_nl = 0
        elif self.pending_nl:
            self.write("\n" * self.pending_nl)
            self.pending_nl = 0
            self.col = 0
        if self.col == 0:
            self.write(self.INDENT)
            self.col = len(self.INDENT)

    def _flush_word(self):
        if not self.word:
            return
        self._begin_line()
        width = self._width()
        if self.col > len(self.INDENT) and self.col + self.word_w > width:
            self.write("\n" + self.INDENT)
            self.col = len(self.INDENT)
        self.write("".join(self.word))
        self.col += self.word_w
        if self.col > width:  # one token longer than the line: the terminal wrapped it
            self.col = self.col % max(1, width)
        self.word = []
        self.word_w = 0

    # ---- fences -------------------------------------------------------------------------
    def _open_fence(self):
        info, self.fence_info = self.fence_info, None
        self._flush_word()
        if not self.started:
            self.write(f"\n{self.s.mark}◆{self.s.off}")
            self.started = True
            self.pending_nl = 1
        self.write("\n" * self.pending_nl)
        self.write(f"{self.s.dim}╭ {info.strip()}{self.s.off}".rstrip())
        self.pending_nl = 1
        self.col = 1
        self.fence = True

    def _close_fence(self):
        self.write("\n" * self.pending_nl)
        self.write(f"{self.s.off}{self.s.dim}╰{self.s.off}")
        self.pending_nl = 1
        self.col = 1
        self.fence = False
        self.fence_len = 0

    def _fence_ch(self, ch: str):
        if ch == "\n":
            self.pending_nl += 1
            self.in_head = True
            return
        if self.pending_nl:
            self.write("\n" * self.pending_nl + self.s.code)
            self.pending_nl = 0
        self.write(ch)


class App:
    def __init__(self, argv: list):
        self.argv = argv
        self.interactive = sys.stdin.isatty() and sys.stdout.isatty()
        color = sys.stdout.isatty() and "NO_COLOR" not in os.environ
        self.s = Style(color)
        self.editor = Editor(self.s, self.w, self.flush)
        self.render = Renderer(self.s, self.w, self.interactive)
        self.parser = KeyParser()
        self.stdin_fd = sys.stdin.fileno()
        self.saved_tty = None
        self.child = None
        self.out_buf = b""
        self.err_buf = b""
        self.err_open = True
        self.busy = False
        self.quitting = False
        self.child_gone = False
        self.interrupting = False
        self.queue = []
        self.perms = []  # pending approval requests, oldest first
        self.perm_shown_at = 0.0
        self.spinner_on = False
        self.spin_at = 0.0
        self.label = "thinking"
        self.activity_key = None
        self.activity_start = 0.0
        self.running = {}  # tool_use_id -> label, for tools still in flight
        self.block_kind = None
        self.thought = ""
        self.turn_tools = 0
        self.detailed = os.environ.get("CAC_VIEW") == "detailed"
        self.thinking_flag = True  # dropped if this claude doesn't know --thinking-display
        self.restart_child = False
        self.first_message = None
        self.turn_start = 0.0
        self.turn_text = False
        self.seen_tools = set()
        self.last_was_tool = False
        self.last_delta = 0.0
        self.last_event = 0.0
        self.last_key_at = 0.0
        self.prev_key_at = 0.0
        self.interrupt_at = 0.0
        self.woken = False  # busy because of output outside a turn, not because of a message
        self.resized_at = None
        self.cost = 0.0
        self.cost_seen = False
        self.turns = 0
        self.sid = None
        self.mode = None
        self.req = 0
        self.lines = []  # line mode only
        self.stdin_eof = False
        self.failed = False
        self.history_path = os.path.expanduser("~/.local/state/cac/history.jsonl")

    # ---- output -------------------------------------------------------------------------
    def w(self, s: str):
        sys.stdout.write(s)

    def flush(self):
        sys.stdout.flush()

    def info(self, text: str):
        """A message that isn't part of the reply. Safe to call in any state."""
        if not self.interactive:
            print(text, file=sys.stderr, flush=True)
            return
        was_drawn = self.editor.drawn
        self.editor.clear()
        self._clear_spinner()
        self.render.break_line()
        self.w(text + "\n")
        if was_drawn:
            self.editor.draw()
        self.flush()

    def activity(self, key, label: str):
        """Say what's happening now. The clock restarts only when the activity really changes."""
        if key != self.activity_key:
            self.activity_key = key
            self.activity_start = time.monotonic()
        self.label = label

    def _idle_activity(self):
        if self.running:
            key = next(reversed(self.running))
            self.activity(key, self.running[key])
        else:
            self.activity("thinking", "thinking")

    def _clear_spinner(self):
        if self.spinner_on:
            self.w("\r\x1b[K")
            self.spinner_on = False

    def _spin(self, now: float):
        if not (self.interactive and self.busy) or self.perms or self.render.open:
            return
        if now - self.spin_at < 0.1:
            return
        self.spin_at = now
        frame = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"[int(now * 10) % 10]
        held = " · input held" if self.queue else ""
        rest = f" {int(now - self.activity_start)}s · ctrl-c stops{held}"
        width = shutil.get_terminal_size((80, 24)).columns
        room = width - 3 - text_width(rest)
        if room < 12:  # narrow: what's happening matters more than the hint
            rest = f" {int(now - self.activity_start)}s"
            room = max(4, width - 3 - text_width(rest))
        self.w(f"\r{self.s.dim}{frame} {fit(self.label, room)}{rest}{self.s.off}\x1b[K")
        self.spinner_on = True
        self.flush()

    # ---- history ------------------------------------------------------------------------
    def load_history(self):
        try:
            with open(self.history_path, encoding="utf-8") as f:
                lines = f.readlines()[-HISTORY_MAX:]
            self.editor.history = [json.loads(line) for line in lines]
        except (OSError, ValueError):
            pass

    def save_history(self, text: str):
        h = self.editor.history
        if h and h[-1] == text:
            return
        if len(text) > HISTORY_ENTRY_MAX:
            return
        h.append(text)
        try:
            os.makedirs(os.path.dirname(self.history_path), exist_ok=True)
            fd = os.open(self.history_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8") as f:
                f.write(json.dumps(text) + "\n")
        except OSError:
            pass

    # ---- claude -------------------------------------------------------------------------
    def _has(self, *names) -> bool:
        return any(a in names or a.split("=", 1)[0] in names for a in self.argv)

    def _arg(self, *names):
        for i, a in enumerate(self.argv):
            if a in names and i + 1 < len(self.argv) and not self.argv[i + 1].startswith("-"):
                return self.argv[i + 1]
            if "=" in a and a.split("=", 1)[0] in names:
                return a.split("=", 1)[1]
        return None

    def start_child(self):
        cmd = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
               "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio"]
        self.sid = self._arg("--resume", "-r", "--session-id")
        if not self.sid and not self._has("--continue", "-c", "--resume", "-r"):
            self.sid = str(uuid.uuid4())
            cmd += ["--session-id", self.sid]
        self.mode = self._arg("--permission-mode")
        if self._has("--dangerously-skip-permissions"):
            self.mode = "bypassPermissions"
        if not self.mode:
            self.mode = DEFAULT_MODE
            cmd += ["--permission-mode", DEFAULT_MODE]
        if not self._has("--append-system-prompt"):
            cmd += ["--append-system-prompt", SYSTEM_NOTE]
        if self.thinking_flag and not self._has("--thinking-display"):
            cmd += ["--thinking-display", "summarized"]  # default streams empty thinking text
        self.child = subprocess.Popen(
            cmd + self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,  # no controlling tty: the keyboard belongs to cac
        )

    def send(self, obj: dict):
        try:
            self.child.stdin.write((json.dumps(obj) + "\n").encode())
            self.child.stdin.flush()
        except (BrokenPipeError, OSError, ValueError):
            pass  # the stdout EOF path reports this

    def control(self, prefix: str, request: dict):
        self.req += 1
        self.send({"type": "control_request", "request_id": f"{prefix}-{self.req}", "request": request})

    def send_user(self, text: str):
        self.send({"type": "user", "message": {"role": "user", "content": text}})
        if self.turns == 0:
            self.first_message = text
        self.turns += 1
        self.begin_turn()

    def begin_turn(self):
        self.busy = True
        self.interrupting = False
        self.woken = False
        self.turn_start = time.monotonic()
        self.turn_text = False
        self.turn_tools = 0
        self.running = {}
        self.activity_key = None
        self.activity("thinking", "thinking")
        self.last_was_tool = False
        if self.interactive:
            self.w("\x1b[?25l")

    def set_mode(self, mode: str):
        self.control("mode", {"subtype": "set_permission_mode", "mode": mode})

    def interrupt(self):
        now = time.monotonic()
        if self.interrupting:
            if now - self.interrupt_at < FORCE_AFTER_SECONDS:
                return
            self.info(f"{self.s.warn}⚠ claude isn't stopping; killing it{self.s.off}")
            self.quitting = True
            self.stop_child(force=True)
            return
        self.interrupting = True
        self.interrupt_at = now
        self.activity("stopping", "stopping")
        self.control("int", {"subtype": "interrupt"})

    def stop_child(self, force: bool = False):
        if not self.child or self.child.poll() is not None:
            return
        try:
            self.child.stdin.close()
        except OSError:
            pass
        try:
            if force:
                raise subprocess.TimeoutExpired("claude", 0)
            self.child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.child.pid, signal.SIGTERM)
                self.child.wait(timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    os.killpg(self.child.pid, signal.SIGKILL)
                except OSError:
                    pass

    # ---- events from claude -------------------------------------------------------------
    def on_line(self, raw: bytes):
        try:
            e = json.loads(raw)
        except ValueError:
            text = sanitize(raw.decode("utf-8", "replace")).strip()
            if text:
                self.info(f"{self.s.dim}{fit(text, 200)}{self.s.off}")
            return
        self.last_event = time.monotonic()
        kind = e.get("type") if isinstance(e, dict) else None
        handler = {
            "system": self.on_system, "stream_event": self.on_stream, "assistant": self.on_assistant,
            "user": self.on_tool_result, "result": self.on_result, "control_request": self.on_request,
            "control_response": self.on_response, "control_cancel_request": self.on_cancel,
        }.get(kind)
        if handler:
            try:
                handler(e)
            except Exception as err:  # an event we don't understand must not end the session
                text = fit(f"{type(err).__name__} on a {kind} event: {raw[:120].decode('utf-8', 'replace')}", 200)
                self.info(f"{self.s.dim}{text}{self.s.off}")

    def _wake(self):
        """Output arrived while idle, e.g. from a background task: give it the screen."""
        if not self.busy:
            self.editor.clear()
            self.begin_turn()
            self.woken = True

    def on_system(self, e: dict):
        if e.get("session_id"):
            self.sid = e["session_id"]
        if e.get("permissionMode"):
            self.mode = e["permissionMode"]
            self._sync_prompt()
        if e.get("subtype") == "api_retry":
            self.activity("retrying", "retrying")
        elif e.get("subtype") == "thinking_tokens" and self.block_kind == "thinking" and not self.thought:
            self.activity("thinking", f"thinking · ~{human(e.get('estimated_tokens') or 0)} tokens")

    def _sync_prompt(self):
        self.editor.prompt = "› " if self.mode == DEFAULT_MODE else f"{self.mode} › "
        if self.editor.drawn:
            self.editor.draw()

    def on_stream(self, e: dict):
        if e.get("parent_tool_use_id"):
            return  # a subagent's text isn't the reply
        ev = e.get("event") or {}
        t = ev.get("type")
        if t == "content_block_start":
            block = ev.get("content_block") or {}
            self.block_kind = block.get("type")
            if self.block_kind in ("thinking", "redacted_thinking"):
                self.thought = ""
                self.activity("thinking", "thinking")
            elif self.block_kind == "tool_use":
                self.activity(block.get("id"), sanitize(block.get("name") or "tool"))
        elif t == "content_block_delta" and (ev.get("delta") or {}).get("type") == "thinking_delta":
            self.thought += sanitize(ev["delta"].get("thinking") or "")
            latest = sentences(self.thought)
            if latest:
                self.activity("thinking", "thinking: " + latest[-1])
        elif t == "content_block_delta" and (ev.get("delta") or {}).get("type") == "text_delta":
            self._wake()
            self._clear_spinner()
            self.turn_text = True
            self.last_was_tool = False
            self.render.text(sanitize(ev["delta"].get("text") or ""))
            self.last_delta = time.monotonic()
        elif t == "content_block_stop":
            if self.block_kind == "thinking":
                self._show_thought()
            self.block_kind = None
            self.render.end()

    def _show_thought(self):
        thought, self.thought = self.thought.strip(), ""
        if not thought or not self.interactive:
            return
        self._clear_spinner()
        self.render.end()
        width = max(20, shutil.get_terminal_size((80, 24)).columns - 5)
        gap = "" if self.last_was_tool else "\n"
        if self.detailed:
            rows = []
            for line in re.sub(r"[*#`]+", "", thought).split("\n"):
                rows += textwrap.wrap(line, width) or [""]
        else:
            rows = [fit(gist_of(thought), width)]
        for i, row in enumerate(rows):
            lead = "  ✻ " if i == 0 else "    "
            self.w(f"{gap if i == 0 else ''}{self.s.dim}{lead}{row}{self.s.off}\n")
        self.last_was_tool = True
        self.activity("thinking", "thinking")

    def _tool_label(self, name: str, block: dict) -> str:
        i = block.get("input") if isinstance(block.get("input"), dict) else {}
        what = i.get("description") or self._summary(block)
        return f"{name}: {what}" if what else name

    def _summary(self, tool: dict) -> str:
        i = tool.get("input") or {}
        for k in ("file_path", "command", "pattern", "url", "query", "description", "prompt"):
            if i.get(k):
                return str(i[k])
        return ""

    def on_assistant(self, e: dict):
        content = (e.get("message") or {}).get("content")
        for block in content if isinstance(content, list) else []:
            if not isinstance(block, dict):
                continue
            if block.get("type") != "tool_use" or block.get("id") in self.seen_tools:
                continue
            self.seen_tools.add(block.get("id"))
            self._wake()
            self._clear_spinner()
            self.render.end()
            name = sanitize(block.get("name") or "tool")
            sub = bool(e.get("parent_tool_use_id"))
            pad = "      " if sub else "  "
            width = shutil.get_terminal_size((80, 24)).columns
            room = width - len(pad) - 4
            target = self._summary(block)
            if (block.get("input") or {}).get("file_path"):
                line = f"{name} {fit_path(target, room - text_width(name) - 1)}"
            else:
                line = fit(f"{name} {target}".strip(), room)
            if self.interactive:
                gap = "" if self.last_was_tool else "\n"
                self.w(f"{gap}{pad}{self.s.dim}⏺ {line}{self.s.off}\n")
                self.last_was_tool = True
            else:
                print(f"{pad}⏺ {line}", file=sys.stderr, flush=True)
            if not sub:
                self.turn_tools += 1
                label = sanitize(self._tool_label(name, block))
                self.running[block.get("id")] = label
                self.activity(block.get("id"), label)

    def on_tool_result(self, e: dict):
        if e.get("parent_tool_use_id"):
            return
        content = (e.get("message") or {}).get("content")
        if not isinstance(content, list):
            return
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_result":
                continue
            self.running.pop(block.get("tool_use_id"), None)
            body = block.get("content")
            if isinstance(body, list):
                body = " ".join(str(p.get("text", "")) for p in body if isinstance(p, dict))
            width = shutil.get_terminal_size((80, 24)).columns
            if block.get("is_error"):
                text = fit(str(body or "failed"), width - 8)
                self.info(f"    {self.s.err}✗ {text}{self.s.off}")
            elif self.detailed and self.interactive and body:
                lines = sanitize(str(body)).split("\n")
                shown = lines[:DETAIL_RESULT_LINES]
                if len(lines) > len(shown):
                    shown.append(f"… +{len(lines) - len(shown)} more lines")
                self.info("\n".join(f"    {self.s.dim}{fit(x, width - 6)}{self.s.off}" for x in shown))
        self._idle_activity()

    def on_result(self, e: dict):
        total = e.get("total_cost_usd")
        delta = None
        if isinstance(total, (int, float)):  # cumulative across this process
            delta = max(0.0, total - self.cost)
            self.cost = total
            self.cost_seen = True
        if not self.busy:
            return
        self._clear_spinner()
        self.render.end()
        error = e.get("is_error") and not self.interrupting
        self.failed = bool(error)
        if not self.interactive:
            if error:
                print(f"⚠ {sanitize(str(e.get('result') or e.get('subtype')))}", file=sys.stderr, flush=True)
            elif not self.turn_text and e.get("result"):
                self.render.text(sanitize(str(e["result"])))
                self.render.end()
            self.busy = False
            return
        if error:
            detail = e.get("result") or "; ".join(map(str, e.get("errors") or [])) or e.get("subtype")
            self.w(f"\n{self.s.err}⚠ {sanitize(str(detail))}{self.s.off}\n")
        elif not self.turn_text and not self.interrupting and e.get("result"):
            self.render.text(sanitize(str(e["result"])))  # e.g. output of a local /command
            self.render.end()
        self.w(f"\n{self.s.dim}{self._footer(e, delta)}{self.s.off}\n\n")
        self.finish_turn()

    def _footer(self, e: dict, delta) -> str:
        parts = []
        if self.interrupting:
            parts.append("stopped")
        if delta is not None:
            # A stopped turn reports nothing yet; its cost lands in the next total.
            parts.append(f"session ${self.cost:.4f}" if self.interrupting and not delta
                         else f"${delta:.4f} · session ${self.cost:.4f}")
        usage = e.get("usage") or {}
        tokens_in = sum(usage.get(k) or 0 for k in
                        ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
        if tokens_in or usage.get("output_tokens"):
            parts.append(f"{human(tokens_in)} in · {human(usage.get('output_tokens') or 0)} out")
        if self.turn_tools:
            parts.append(f"{self.turn_tools} tool{'' if self.turn_tools == 1 else 's'}")
        parts.append(f"{time.monotonic() - self.turn_start:.1f}s")
        parts.append(self.mode or "")
        width = shutil.get_terminal_size((80, 24)).columns
        return "  " + fit(" · ".join(p for p in parts if p), width - 3)

    def finish_turn(self):
        self.busy = False
        self.interrupting = False
        self.woken = False
        self.w("\x1b[?25h")
        self.settle_idle()

    def settle_idle(self):
        """Give the keyboard back, unless a turn or an approval still holds it."""
        if self.busy or self.perms or self.quitting:
            return
        self.editor.draw()
        self.replay()

    def replay(self):
        while self.queue and not self.busy and not self.perms and not self.quitting:
            self.on_key(self.queue.pop(0))

    def on_response(self, e: dict):
        r = e.get("response") or {}
        rid = str(r.get("request_id") or "")
        if not rid.startswith("mode-"):
            return
        if r.get("subtype") == "success":
            self.mode = (r.get("response") or {}).get("mode") or self.mode
            self._sync_prompt()
            self.info(f"  {self.s.dim}mode → {self.mode}{self.s.off}")
        else:
            self.info(f"  {self.s.err}⚠ {sanitize(str(r.get('error')))}{self.s.off}")

    # ---- approvals ----------------------------------------------------------------------
    def on_request(self, e: dict):
        req = e.get("request") or {}
        rid = e.get("request_id")
        if req.get("subtype") != "can_use_tool":
            self.send({"type": "control_response", "response": {
                "subtype": "error", "request_id": rid, "error": "cac doesn't handle this request"}})
            return
        tool = req.get("tool_name")
        if tool == "AskUserQuestion":
            self.answer(rid, {"behavior": "deny", "message":
                              "cac has no question UI. Ask in plain text and wait for the user's reply."})
            return
        if not self.interactive:
            self.answer(rid, {"behavior": "deny", "message":
                              "No one is at the keyboard to approve this tool call."})
            return
        self.editor.clear()  # may be idle: approvals don't need a turn, and don't start one
        self.perms.append({"id": rid, "req": req})
        if len(self.perms) == 1:
            self.show_perm()

    def _perm_detail(self, req: dict) -> list:
        i = req.get("input") or {}
        tool = req.get("tool_name")
        if not isinstance(i, dict):
            text = str(i)
        elif tool == "ExitPlanMode" and i.get("plan"):
            text = str(i["plan"])
        elif tool == "Edit" and i.get("file_path"):
            old = "\n".join("- " + x for x in str(i.get("old_string", "")).split("\n"))
            new = "\n".join("+ " + x for x in str(i.get("new_string", "")).split("\n"))
            text = f"{i['file_path']}\n{old}\n{new}"
        elif tool == "Write" and i.get("file_path"):
            text = f"{i['file_path']}\n{i.get('content', '')}"
        elif tool == "Bash" and i.get("command"):
            text = str(i["command"])
        else:
            text = json.dumps(i, ensure_ascii=False, indent=2)
        # Never truncate here: this is what the user approves, and the tail may be the dangerous part.
        width = max(20, shutil.get_terminal_size((80, 24)).columns - 5)
        rows = []
        for line in sanitize(text).split("\n"):
            rows += wrap_cells(line, width)
        return rows

    def show_perm(self):
        self._clear_spinner()
        self.render.end()
        req = self.perms[0]["req"]
        tool = sanitize(str(req.get("display_name") or req.get("tool_name") or "tool"))
        self.w(f"\n  {self.s.warn}⏵ Allow {tool}?{self.s.off}\n")
        for line in self._perm_detail(req):
            self.w(f"    {line}\n")
        self.w(f"  {self.s.warn}[y] yes   [n] no{self.s.off}   {self.s.dim}ctrl-c stops{self.s.off}\n")
        grant = self._grant(req)
        if grant:
            width = max(20, shutil.get_terminal_size((80, 24)).columns - 5)
            for i, row in enumerate(wrap_cells(f"[a] this session: {grant}", width)):
                self.w(f"  {self.s.warn}{row}{self.s.off}\n" if i == 0 else f"    {self.s.warn}{row}{self.s.off}\n")
        self.perm_shown_at = time.monotonic()
        self.flush()

    def _suggestions(self, req: dict) -> list:
        found = req.get("permission_suggestions")
        return [x for x in found if isinstance(x, dict)] if isinstance(found, list) else []

    def _grant(self, req: dict) -> str:
        """Say exactly what [a] would hand over. An unlabeled "always" can flip the whole mode."""
        parts = []
        for item in self._suggestions(req):
            kind = item.get("type")
            if kind == "setMode":
                parts.append(f"switch to {item.get('mode')} mode")
            elif kind == "addRules":
                for rule in item.get("rules") or []:
                    if isinstance(rule, dict):
                        body = rule.get("ruleContent")
                        parts.append(f"allow {rule.get('toolName')}" + (f"({body})" if body else ""))
            elif kind == "addDirectories":
                parts.append("allow directories " + ", ".join(map(str, item.get("directories") or [])))
            else:
                parts.append(str(kind))
        return sanitize("; ".join(parts)).replace("\n", " ")

    def answer(self, rid, response: dict):
        self.send({"type": "control_response", "response": {
            "subtype": "success", "request_id": rid, "response": response}})

    def on_perm_key(self, ev: tuple):
        kind, value = ev
        perm = self.perms[0]
        req = perm["req"]
        if ev == ("key", "ctrl-c"):
            for p in self.perms:
                self.answer(p["id"], {"behavior": "deny", "message": "The user stopped this.", "interrupt": True})
            self.perms = []
            self.w(f"  {self.s.dim}→ stopped{self.s.off}\n")
            if self.busy:
                self.interrupt()
            else:
                self.settle_idle()
            return
        # A single deliberate key only: not one in flight when the prompt appeared, and not the
        # next letter of a sentence someone is still typing with the editor hidden.
        now = time.monotonic()
        deliberate = now - self.perm_shown_at >= GATE_SECONDS and now - self.prev_key_at >= PAUSE_SECONDS
        choice = value.lower() if kind == "char" else ""
        if not deliberate or choice not in ("y", "n", "a"):
            if kind in ("char", "paste"):
                self.queue.append(ev)
            return
        suggestions = self._suggestions(req)
        if choice == "a" and not suggestions:
            return
        if choice == "n":
            self.answer(perm["id"], {"behavior": "deny", "message": "The user declined this tool call."})
            note = "declined"
        else:
            response = {"behavior": "allow", "updatedInput": req.get("input") or {}}
            note = "allowed"
            if choice == "a":
                # Only ever for this session: never write to the project's or the user's settings.
                response["updatedPermissions"] = [{**x, "destination": "session"} for x in suggestions]
                note = "allowed for this session"
            self.answer(perm["id"], response)
        self.w(f"  {self.s.dim}→ {note}{self.s.off}\n")
        self.perms.pop(0)
        if self.perms:
            self.show_perm()
        else:
            self._idle_activity()
            self.settle_idle()
        self.flush()

    def on_cancel(self, e: dict):
        rid = e.get("request_id")
        was_first = bool(self.perms) and self.perms[0]["id"] == rid
        self.perms = [p for p in self.perms if p["id"] != rid]
        if was_first:
            self.w(f"  {self.s.dim}→ no longer needed{self.s.off}\n")
            if self.perms:
                self.show_perm()
            else:
                self.settle_idle()

    # ---- keyboard -----------------------------------------------------------------------
    def tty_key(self, ev: tuple):
        """A key straight from the keyboard, as opposed to one replayed from the queue."""
        self.prev_key_at, self.last_key_at = self.last_key_at, time.monotonic()
        self.on_key(ev)

    def on_key(self, ev: tuple):
        kind, value = ev
        if ev == ("key", "ctrl-o"):
            self.set_view(not self.detailed)
        elif self.perms:
            self.on_perm_key(ev)
        elif self.busy:
            if ev == ("key", "ctrl-c"):
                self.interrupt()
            elif ev == ("key", "shift-tab"):
                self.cycle_mode()
            else:
                self.queue.append(ev)
        elif kind == "char":
            self.editor.insert(value)
            self.editor.draw()
        elif kind == "paste":
            self.editor.paste(value)
            self.editor.draw()
        else:
            self.on_idle_key(value)

    def on_idle_key(self, name: str):
        ed = self.editor
        if name == "ctrl-c":
            if ed.buf:
                ed.reset()
                ed.draw()
            else:
                self.info(f"  {self.s.dim}ctrl-d or /exit to quit{self.s.off}")
        elif name == "ctrl-d" and not ed.buf:
            self.quitting = True
        elif name == "ctrl-l":
            self.w("\x1b[2J\x1b[H")
            ed.drawn = False
            ed.cursor_row = 0
            ed.draw()
        elif name == "shift-tab":
            self.cycle_mode()
        elif ed.key(name) == "submit":
            self.submit()
        else:
            ed.draw()

    def set_view(self, detailed: bool):
        self.detailed = detailed
        self.info(f"  {self.s.dim}view → {'detailed' if detailed else 'concise'}{self.s.off}")

    def cycle_mode(self):
        at = CYCLE.index(self.mode) if self.mode in CYCLE else -1
        self.set_mode(CYCLE[(at + 1) % len(CYCLE)])

    def submit(self):
        ed = self.editor
        text = ed.buf.strip()
        if not text:
            ed.reset()
            ed.draw()
            return
        ed.finish()
        ed.reset()
        self.save_history(text)
        if self.run_command(text):
            if not self.quitting:
                ed.draw()
            return
        self.send_user(text)

    def run_command(self, text: str) -> bool:
        """Handle cac's own commands. Everything else goes to claude."""
        parts = text.split()
        if parts[0] in ("/exit", "/quit"):
            self.quitting = True
        elif parts[0] == "/help":
            for line in HELP.split("\n"):
                self.info(f"  {self.s.dim}{line}{self.s.off}")
        elif parts[0] == "/view":
            if len(parts) == 2 and parts[1] in ("concise", "detailed"):
                self.set_view(parts[1] == "detailed")
            else:
                self.set_view(not self.detailed)
        elif parts[0] == "/mode":
            if len(parts) == 2:
                self.set_mode(parts[1])
            else:
                self.info(f"  {self.s.dim}mode: {self.mode} · /mode <{'|'.join(MODES)}>{self.s.off}")
        else:
            return False
        return True

    # ---- loops --------------------------------------------------------------------------
    def setup_tty(self):
        self.saved_tty = termios.tcgetattr(self.stdin_fd)
        t = termios.tcgetattr(self.stdin_fd)
        t[0] &= ~(termios.ICRNL | termios.IXON | termios.INLCR | termios.IGNCR)
        t[3] &= ~(termios.ICANON | termios.ECHO | termios.ISIG | termios.IEXTEN)
        t[6][termios.VMIN] = 1
        t[6][termios.VTIME] = 0
        termios.tcsetattr(self.stdin_fd, termios.TCSADRAIN, t)
        self.w("\x1b[?2004h")

    def restore_tty(self):
        if self.saved_tty is None:
            return
        self.w(f"\x1b[?2004l\x1b[?25h{self.s.off}")
        try:
            self.flush()
        except OSError:
            pass
        termios.tcsetattr(self.stdin_fd, termios.TCSADRAIN, self.saved_tty)
        self.saved_tty = None

    def pump_child(self, ready: list) -> None:
        for fd, name in ((self.child.stdout.fileno(), "out"), (self.child.stderr.fileno(), "err")):
            if fd not in ready:
                continue
            chunk = os.read(fd, 65536)
            if name == "err":
                if not chunk:  # a closed pipe stays readable forever: stop watching it or we spin
                    self.err_open = False
                    continue
                self.err_buf += chunk
                *lines, self.err_buf = self.err_buf.split(b"\n")
                for line in lines:
                    text = sanitize(line.decode("utf-8", "replace")).strip()
                    if self.thinking_flag and "thinking-display" in text:
                        self.restart_child = True  # an older or newer claude: run without the flag
                    elif text and NOISE not in text:
                        self.info(f"{self.s.dim}{text}{self.s.off}")
                continue
            if not chunk:
                self.child_gone = True
                continue
            self.out_buf += chunk
            *lines, self.out_buf = self.out_buf.split(b"\n")
            for line in lines:
                if line.strip():
                    self.on_line(line)

    def maybe_restart_child(self):
        """Thinking text is a nicety. If claude rejects the flag, keep working without it."""
        if not (self.restart_child and self.child_gone):
            return
        self.restart_child = False
        self.thinking_flag = False
        self.child_gone = False
        self.err_open = True
        self.out_buf = self.err_buf = b""
        self.child.wait()
        self.start_child()
        if self.first_message is not None:
            self.send({"type": "user", "message": {"role": "user", "content": self.first_message}})

    def child_fds(self) -> list:
        return [self.child.stdout.fileno()] + ([self.child.stderr.fileno()] if self.err_open else [])

    def run_interactive(self):
        self.load_history()
        self.setup_tty()
        s = self.s
        self.w(f"{s.dim}session {self.sid or '(from claude)'} · {self.mode} · shift+tab or /mode · "
               f"ctrl-o details · /help · /exit{s.off}\n\n")
        self.editor.prompt = "› " if self.mode == DEFAULT_MODE else f"{self.mode} › "
        self.editor.draw()
        while not self.quitting and not self.child_gone:
            fds = self.child_fds() + [self.stdin_fd]
            timeout = 0.05 if self.parser.pending_since else 0.1
            ready = select.select(fds, [], [], timeout)[0]
            if self.stdin_fd in ready:
                data = os.read(self.stdin_fd, 65536)
                if not data:
                    break
                for ev in self.parser.feed(data):
                    self.tty_key(ev)
            elif self.parser.pending_since and time.monotonic() - self.parser.pending_since > 0.05:
                for ev in self.parser.flush():
                    self.tty_key(ev)
            self.pump_child(ready)
            self._drain_on_exit()
            self.maybe_restart_child()
            now = time.monotonic()
            if self.render.open and now - self.last_delta > 0.2:
                self.render.settle()
            if self.woken and self.busy and not self.perms and now - self.last_event > WAKE_RELEASE_SECONDS:
                self._clear_spinner()
                self.render.end()
                self.finish_turn()
            self._spin(now)
            self._check_resize(now)
            self.flush()
        self.editor.clear()
        self._clear_spinner()
        self.render.end()
        self.flush()

    def _drain_on_exit(self):
        """A dying child may close stdout first; its error line must still be read."""
        if not self.child_gone or not self.err_open:
            return
        fd = self.child.stderr.fileno()
        while self.err_open and select.select([fd], [], [], 0.5)[0]:
            self.pump_child([fd])

    def _check_resize(self, now: float):
        ed = self.editor
        if not ed.drawn or shutil.get_terminal_size((80, 24)).columns == ed.drawn_width:
            self.resized_at = None
        elif self.resized_at is None:
            self.resized_at = now
        elif now - self.resized_at > 0.2:
            # The terminal has already reflowed the old rows, so their positions are unknown.
            # Redraw below them; a stale row beats overwriting the reply above.
            self.resized_at = None
            self.w("\n")
            ed.drawn = False
            ed.cursor_row = 0
            ed.draw()

    def run_lines(self):
        """stdin or stdout isn't a terminal: one line is one message, sent after the last reply."""
        pending = b""
        while not self.child_gone:
            if not self.busy and not self.quitting:
                if self.lines:
                    line = self.lines.pop(0)
                    if not self.run_command(line):
                        self.send_user(line)
                    continue
                if self.stdin_eof:
                    break
            elif self.quitting:
                break
            fds = self.child_fds() + ([] if self.stdin_eof else [self.stdin_fd])
            ready = select.select(fds, [], [], 0.1)[0]
            if self.stdin_fd in ready:
                data = os.read(self.stdin_fd, 65536)
                if not data:
                    self.stdin_eof = True
                    if pending.strip():
                        self.lines.append(pending.decode("utf-8", "replace"))
                    pending = b""
                else:
                    *got, pending = (pending + data).split(b"\n")
                    self.lines += [g.decode("utf-8", "replace") for g in got if g.strip()]
            self.pump_child(ready)
            self._drain_on_exit()
            self.maybe_restart_child()
            self.flush()

    def main(self) -> int:
        def stop(_sig, _frame):
            raise SystemExit(130)
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGHUP, stop)
        if self.interactive:
            signal.signal(signal.SIGINT, signal.SIG_IGN)  # ctrl-c arrives as a key; never die mid-draw
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
        if self._has("--resume", "-r") and not self._arg("--resume", "-r"):
            print("cac: --resume needs a session id", file=sys.stderr)
            return 2
        try:
            self.start_child()
        except FileNotFoundError:
            print("cac: claude not found on PATH", file=sys.stderr)
            return 127
        code = 0
        try:
            if self.interactive:
                self.run_interactive()
            else:
                self.run_lines()
            if self.child_gone and not self.quitting and not (self.stdin_eof and not self.busy):
                rc = self.child.wait()
                if rc:
                    code = rc
                    print(f"\ncac: claude exited with code {rc}", file=sys.stderr)
            elif self.failed:
                code = 1
        except KeyboardInterrupt:
            code = 130
        except BrokenPipeError:  # e.g. `cac | head`: the reader left, which isn't an error here
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
            code = 141
        finally:
            self.restore_tty()
            self.stop_child()
            if self.interactive:
                total = f" · ${self.cost:.4f}" if self.cost_seen else ""
                self.w(f"{self.s.dim}{self.turns} turn{'' if self.turns == 1 else 's'}{total}{self.s.off}\n")
                self.flush()
            if self.sid and (self.turns or self._has("--resume", "-r")):
                print(f"resume: cac --resume {self.sid}", file=sys.stderr, flush=True)
        return code


if __name__ == "__main__":
    sys.exit(App(sys.argv[1:]).main())
