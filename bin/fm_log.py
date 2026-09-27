#!/usr/bin/env python3
"""fm_log.py - the captain's log renderer, run only by bin/fm-log.sh.

bin/fm-log.sh owns configuration, the lock, and the command surface;
docs/captains-log.md owns the reader-facing layout. This module owns only how
fleet activity ledger records (docs/fleet-ledger.md) and one bearings snapshot
become Markdown files under the log root, and how the derived recall index
(state/.log-index.db) is built from those same records and read back by recall.

Rules it keeps:
  - Every entry carries a hidden `%% fm:<id> %%` anchor, an Obsidian comment,
    and is written only when that anchor is absent from its target file, so a
    replay from an older cursor is a no-op.
  - An entry lands in the day note of its record's timestamp (local time), so
    work after midnight belongs to the new day by construction.
  - Past days are only ever amended by inserting lines; only the current day's
    board link and "Open at close" section are recomputed.
  - Worker status text is untrusted: it is flattened to one line, stripped of
    link and comment syntax, capped, and only terminal or decision states are
    rendered. Worker report bodies are never copied.
  - Every file is written through a temporary file and a rename.
"""
import datetime
import hashlib
import json
import os
import re
import sys
import time

SECTIONS = ("Carried over", "Worked through", "Asked and answered", "Open at close")
BOARD_LINE = re.compile(r"^\[Captain's board\]\(")
ANCHOR = "%% fm:{} %%"
STATUS_STATES = ("done", "failed", "blocked", "needs-decision")
TEXT_CAP = 200
QUEUED_SHOWN = 15
DONE_SHOWN = 12


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.fm-log-tmp-%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        return None


class Config:
    """Optional per-home patterns: ticket links, people allowlist, redaction."""

    def __init__(self, config_dir):
        self.tickets = []
        for line in (read(os.path.join(config_dir, "log-tickets")) or "").splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            pattern, _, template = line.partition("\t")
            try:
                rx = re.compile(pattern)
            except re.error as err:
                sys.stderr.write("fm-log: ignoring invalid ticket pattern %r: %s\n" % (pattern, err))
                continue
            self.tickets.append((rx, template.strip()))
        people = read(os.path.join(config_dir, "log-people"))
        self.people = None if people is None else {
            p.strip() for p in people.splitlines() if p.strip() and not p.startswith("#")}
        self.redact = []
        for line in (read(os.path.join(config_dir, "log-redact")) or "").splitlines():
            if line.strip() and not line.lstrip().startswith("#"):
                try:
                    self.redact.append(re.compile(line))
                except re.error as err:
                    sys.stderr.write("fm-log: ignoring invalid redact pattern %r: %s\n" % (line, err))

    def ticket_ids(self, *texts):
        found = []
        for rx, _ in self.tickets:
            for text in texts:
                for m in rx.finditer(text or ""):
                    tid = (m.group(1) if m.groups() else m.group(0)).upper()
                    if tid not in found:
                        found.append(tid)
        return found

    def ticket_url(self, tid):
        for rx, template in self.tickets:
            if template and rx.search(tid):
                return template.replace("{id}", tid)
        return ""

    def person_ok(self, name):
        return self.people is None or name in self.people


def clean(text, cfg, cap=TEXT_CAP):
    """Untrusted text flattened to one safe Markdown line."""
    text = re.sub(r"\s+", " ", text or "").strip()
    text = text.replace("%%", "%").replace("[[", "[").replace("]]", "]")
    for rx in cfg.redact:
        text = rx.sub("[redacted]", text)
    if len(text) > cap:
        text = text[: cap - 1].rstrip() + "…"
    return text


def safe_name(name):
    return re.sub(r"[\\/:*?\"<>|#^\[\]]", "-", name).strip(" .") or "unnamed"


class Log:
    def __init__(self, root, config_dir, snapshot, board_target, today, carry_limit=None):
        self.root = root
        self.cfg = Config(config_dir)
        self.snapshot = snapshot or {}
        self.board_target = board_target
        self.today = today
        self.rows = {r["id"]: r for r in self.snapshot.get("queue", []) or []}
        self.inflight = {r["id"]: r for r in self.snapshot.get("in_flight", []) or []}
        self.files = {}
        self.carry_limit = carry_limit
        self._disk_paths = None

    # ---- file cache -------------------------------------------------------
    def load(self, path):
        if path not in self.files:
            text = read(path)
            self.files[path] = None if text is None else text.split("\n")
        return self.files[path]

    def store(self, path, lines):
        self.files[path] = lines

    def flush(self):
        for path, lines in self.files.items():
            if lines is None:
                continue
            text = "\n".join(lines)
            if not text.endswith("\n"):
                text += "\n"
            if read(path) != text:
                write_atomic(path, text)

    def has_anchor(self, path, aid):
        lines = self.load(path)
        needle = ANCHOR.format(aid)
        return lines is not None and any(needle in line for line in lines)

    # ---- day notes --------------------------------------------------------
    def day_path(self, day):
        base = os.path.join(self.root, day[0:4], day[5:7], day[8:10])
        for cand in (os.path.join(base, day + ".md"), os.path.join(base, "log.md"), base + ".md"):
            if os.path.isfile(cand):
                return cand
        return os.path.join(base, day + ".md")

    def previous_day(self, day):
        day_rx = re.compile(r"^(\d{4})/(\d{2})/(\d{2})(?:\.md|/log\.md|/(\d{4})-(\d{2})-(\d{2})\.md)$")
        best = None
        for top, dirs, files in os.walk(self.root):
            dirs[:] = [d for d in dirs if not d.startswith(".") and (d.isdigit())]
            for name in files:
                rel = os.path.relpath(os.path.join(top, name), self.root).replace(os.sep, "/")
                m = day_rx.match(rel)
                if not m or (m.group(4) and m.group(4, 5, 6) != m.group(1, 2, 3)):
                    continue
                d = "%s-%s-%s" % m.group(1, 2, 3)
                if d < day and (best is None or d > best[0]):
                    best = (d, os.path.join(top, name))
        for path in self.files:
            m = re.search(r"(\d{4})-(\d{2})-(\d{2})\.md$", path)
            if m and self.files[path] is not None:
                d = "%s-%s-%s" % m.group(1, 2, 3)
                if d < day and (best is None or d > best[0]):
                    best = (d, path)
        return best[1] if best else None

    def day(self, day):
        path = self.day_path(day)
        lines = self.load(path)
        if lines is None:
            carried = []
            prev = self.previous_day(day)
            if prev:
                carried = [l for l in self.section(self.load(prev), "Open at close")
                           if l.startswith("- ") and l != "- (nothing open)"]
            lines = [self.board_line(), ""]
            for name in SECTIONS:
                lines += ["## " + name, ""]
                if name == "Carried over":
                    lines += (carried or ["- (nothing carried over)"]) + [""]
            self.store(path, lines)
        return path

    def board_line(self):
        return "[Captain's board](%s)" % self.board_target

    @staticmethod
    def section_bounds(lines, name):
        head = "## " + name
        if head not in lines:
            return None
        start = lines.index(head)
        end = len(lines)
        for k in range(start + 1, len(lines)):
            if lines[k].startswith("## "):
                end = k
                break
        return start, end

    def section(self, lines, name):
        b = self.section_bounds(lines or [], name)
        return [] if b is None else lines[b[0] + 1: b[1]]

    def ensure_section(self, lines, name):
        if self.section_bounds(lines, name) is None:
            order = list(SECTIONS)
            after = [s for s in order[order.index(name) + 1:] if ("## " + s) in lines] if name in order else []
            at = lines.index("## " + after[0]) if after else len(lines)
            lines[at:at] = ["## " + name, "", ""]
        return self.section_bounds(lines, name)

    def append_bullet(self, path, name, line):
        lines = self.load(path)
        start, end = self.ensure_section(lines, name)
        last = None
        for k in range(start + 1, end):
            if lines[k].lstrip().startswith("- "):
                last = k
        if last is None:
            at = start + 2 if start + 1 < len(lines) and lines[start + 1] == "" else start + 1
        else:
            at = last + 1
            while at < end and lines[at].startswith((" ", "\t")) and lines[at].strip():
                at += 1
        lines.insert(at, "- " + line)
        if at + 1 < len(lines) and lines[at + 1].startswith("## "):
            lines.insert(at + 1, "")
        self.store(path, lines)

    def insert_child(self, path, parent_index, line):
        """Nest `line` one level under the bullet at parent_index, after its existing children."""
        lines = self.load(path)
        parent = lines[parent_index]
        indent = len(parent) - len(parent.lstrip())
        child = " " * (indent + 2)
        at = parent_index + 1
        while at < len(lines):
            cur = lines[at]
            if not cur.strip():
                break
            if len(cur) - len(cur.lstrip()) <= indent:
                break
            at += 1
        lines.insert(at, child + "- " + line)
        self.store(path, lines)

    def find_anchor(self, needle):
        """(path, index) of the newest line carrying the anchor, searching day notes newest first."""
        if self._disk_paths is None:
            self._disk_paths = set()
            for top, dirs, files in os.walk(self.root):
                dirs[:] = [d for d in dirs if not d.startswith(".")]
                for name in files:
                    if name.endswith(".md"):
                        self._disk_paths.add(os.path.join(top, name))
        paths = self._disk_paths | set(self.files)
        for path in sorted(paths, reverse=True):
            lines = self.load(path)
            if not lines:
                continue
            for k in range(len(lines) - 1, -1, -1):
                if needle in lines[k]:
                    return path, k
        return None

    # ---- links ------------------------------------------------------------
    def title(self, task):
        row = self.rows.get(task) or {}
        name = row.get("title") or (self.inflight.get(task) or {}).get("name") or task
        return clean(name, self.cfg, 90)

    def linked(self, text):
        for tid in self.cfg.ticket_ids(text):
            text = re.sub(r"(?<!\[)\b%s\b(?!\])" % re.escape(tid), "[[%s]]" % tid, text, flags=re.I)
        return text

    def people(self, task):
        row = self.rows.get(task) or {}
        return [p for p in row.get("people") or [] if self.cfg.person_ok(p)]

    # ---- side notes: tickets, projects, people, learnings ---------------
    def side_note(self, folder, name, header, line, aid):
        path = os.path.join(self.root, folder, safe_name(name) + ".md")
        lines = self.load(path)
        if lines is None:
            lines = header + [""]
            self.store(path, lines)
        if not self.has_anchor(path, aid):
            while lines and lines[-1] == "":
                lines.pop()
            if lines and not lines[-1].startswith("- "):
                lines.append("")
            lines.append("- " + line + " " + ANCHOR.format(aid))
            lines.append("")
            self.store(path, lines)

    def fan_out(self, task, project, stamp, text, aid, extra_ids=()):
        row = self.rows.get(task) or {}
        for tid in self.cfg.ticket_ids(task, row.get("title") or "", *extra_ids):
            url = self.cfg.ticket_url(tid)
            header = ["# " + tid, ""] + (["[Open in the tracker](%s)" % url, ""] if url else [])
            self.side_note("tickets", tid, header, "%s %s" % (stamp, text), aid)
        project = project or row.get("repo")
        if project:
            self.side_note("projects", project, ["# " + clean(project, self.cfg, 80), ""],
                           "%s %s" % (stamp, text), aid)
        for person in self.people(task):
            self.side_note("people", person, ["# " + clean(person, self.cfg, 80), ""],
                           "%s %s" % (stamp, text), aid)

    # ---- events -----------------------------------------------------------
    def render(self, rec, eid):
        event = rec.get("event")
        ts = rec.get("ts")
        if not isinstance(ts, int):
            return
        when = datetime.datetime.fromtimestamp(ts)
        day = when.strftime("%Y-%m-%d")
        stamp = when.strftime("%H:%M")
        task = rec.get("task") or ""
        handler = getattr(self, "on_" + str(event).replace(".", "_"), None)
        if handler is None:
            return  # readers ignore events they do not know
        handler(rec, eid, day, stamp, task, when)

    def worked(self, day, stamp, text, eid):
        path = self.day(day)
        if not self.has_anchor(path, eid):
            self.append_bullet(path, "Worked through", "%s %s %s" % (stamp, text, ANCHOR.format(eid)))

    def people_suffix(self, task):
        names = self.people(task)
        return (" with " + ", ".join("[[%s]]" % safe_name(n) for n in names)) if names else ""

    def on_task_dispatched(self, rec, eid, day, stamp, task, when):
        project = rec.get("project") or ""
        where = " in [[%s]]" % safe_name(project) if project else ""
        text = "Started %s%s%s" % (self.linked(self.title(task)), where, self.people_suffix(task))
        self.worked(day, stamp, text, eid)
        self.fan_out(task, project, when.strftime("%Y-%m-%d %H:%M"), "Started " + self.title(task), eid)

    def on_task_status(self, rec, eid, day, stamp, task, when):
        state = rec.get("state")
        if state not in STATUS_STATES:
            return
        label = {"done": "Finished", "failed": "Failed", "blocked": "Blocked",
                 "needs-decision": "Needs a decision"}[state]
        detail = clean(rec.get("text"), self.cfg)
        text = "%s: %s%s" % (label, self.linked(self.title(task)), (" - " + detail) if detail else "")
        self.worked(day, stamp, text, eid)
        self.fan_out(task, None, when.strftime("%Y-%m-%d %H:%M"), "%s: %s" % (label, detail or self.title(task)), eid)

    def on_task_pr_ready(self, rec, eid, day, stamp, task, when):
        url = clean(rec.get("pr"), self.cfg, 300)
        text = "Ready for review: %s %s" % (self.linked(self.title(task)), url)
        self.worked(day, stamp, text, eid)
        self.fan_out(task, None, when.strftime("%Y-%m-%d %H:%M"), "Ready for review: " + url, eid, (url,))

    def on_task_merged(self, rec, eid, day, stamp, task, when):
        url = clean(rec.get("pr"), self.cfg, 300) if rec.get("via") == "pr" else ""
        text = "Landed %s%s" % (self.linked(self.title(task)), (" " + url) if url else " on the local branch")
        self.worked(day, stamp, text, eid)
        self.fan_out(task, None, when.strftime("%Y-%m-%d %H:%M"), "Landed" + ((" " + url) if url else ""), eid)

    def on_captain_held(self, rec, eid, day, stamp, task, when):
        path = self.day(day)
        if self.has_anchor(path, eid):
            return
        reason = clean(rec.get("reason"), self.cfg)
        question = "%s: %s" % (self.linked(self.title(task)), reason) if reason else self.linked(self.title(task))
        self.append_bullet(path, "Asked and answered", "%s %s %s" % (
            question, ANCHOR.format("hold:" + task), ANCHOR.format(eid)))
        if rec.get("until"):
            found = self.find_anchor(ANCHOR.format(eid))
            if found:
                self.insert_child(found[0], found[1], "deferred to [[%s]]" % clean(rec["until"], self.cfg, 10))
        self.fan_out(task, None, when.strftime("%Y-%m-%d %H:%M"), "Asked: " + reason, eid)

    def on_captain_answered(self, rec, eid, day, stamp, task, when):
        if self.find_anchor(ANCHOR.format(eid)):
            return
        words = clean(rec.get("words"), self.cfg, 1000)
        mode = rec.get("mode")
        source = clean(rec.get("source"), self.cfg, 60)
        if mode == "reconciled":
            line = "checked: moot - %s" % words
        elif mode == "released":
            line = "Captain (released the hold): %s" % words
        else:
            line = "Captain%s: %s" % ((" via " + source) if source else "", words)
        line += " " + ANCHOR.format(eid)
        found = self.find_anchor(ANCHOR.format("hold:" + task))
        if found:
            self.insert_child(found[0], found[1], line)
        else:
            path = self.day(day)
            self.append_bullet(path, "Asked and answered", "re: %s" % self.linked(self.title(task)))
            found = self.find_anchor("re: %s" % self.linked(self.title(task)))
            self.insert_child(found[0], found[1], line)
        self.fan_out(task, None, when.strftime("%Y-%m-%d %H:%M"), "Answered: " + words, eid)

    def on_inbox_noted(self, rec, eid, day, stamp, task, when):
        log_day = rec.get("log_day")
        if not log_day:
            return  # plain notes stay in chat
        note = rec.get("note") or ""
        if task and self.find_anchor(ANCHOR.format("hold:" + task)):
            return  # the answer arrives as the hold's own record
        if self.find_anchor(ANCHOR.format("note:" + note)):
            return
        body = [l for l in (rec.get("text") or "").splitlines()
                if not re.match(r"^(log_day|task|thread|question|log_note)=", l)]
        text = clean(" ".join(body), self.cfg, 1000)
        line = "%s %s" % (text, ANCHOR.format("note:" + note))
        thread = rec.get("thread")
        parent = self.find_anchor(ANCHOR.format("note:" + thread)) if thread else None
        if parent:
            self.insert_child(parent[0], parent[1], line)
        else:
            self.append_bullet(self.day(log_day), "Asked and answered", line)

    def on_inbox_replied(self, rec, eid, day, stamp, task, when):
        if self.find_anchor(ANCHOR.format(eid)):
            return
        found = self.find_anchor(ANCHOR.format("note:" + (rec.get("note") or "")))
        if not found:
            return
        self.insert_child(found[0], found[1], "firstmate: %s %s" % (
            clean(rec.get("text"), self.cfg, 1000), ANCHOR.format(eid)))

    def on_learning_filed(self, rec, eid, day, stamp, task, when):
        slug = safe_name(rec.get("slug") or "")
        title = clean(rec.get("title"), self.cfg, 120)
        self.worked(day, stamp, "Learned [[%s|%s]]" % (slug, title), eid)

    # ---- computed views ---------------------------------------------------
    def open_items(self):
        rows = list(self.rows.values())
        out = []
        for r in rows:
            if r.get("state") == "done":
                continue
            if r.get("hold_kind") == "captain" and r.get("hold_bucket") == "live":
                out.append("- Waiting on you: %s" % self.row_text(r))
        for r in rows:
            if r.get("state") != "done" and r.get("blocked_by") and r.get("hold_bucket") in (None, "blocked"):
                out.append("- Blocked: %s (by %s)" % (self.row_text(r), ", ".join(r["blocked_by"])))
        for r in self.snapshot.get("in_flight", []) or []:
            out.append("- In flight: %s" % self.linked(clean(r.get("name") or r.get("id"), self.cfg, 90)))
        return out

    def row_text(self, r):
        return self.linked(clean(r.get("title") or r.get("id"), self.cfg, 90))

    def refresh_today(self):
        path = self.day(self.today)
        lines = self.load(path)
        start, end = self.ensure_section(lines, "Carried over")
        if [l for l in lines[start + 1: end] if l.strip()] == ["- (nothing carried over)"]:
            prev = self.previous_day(self.today)
            carried = [l for l in self.section(self.load(prev), "Open at close")
                       if l.startswith("- ") and l != "- (nothing open)"] if prev else []
            if carried:
                lines[start + 1: end] = [""] + carried + [""]
        if lines and BOARD_LINE.match(lines[0]):
            lines[0] = self.board_line()
        else:
            lines[0:0] = [self.board_line(), ""]
        if self.snapshot.get("queue") is not None:
            start, end = self.ensure_section(lines, "Open at close")
            manual = [l for l in lines[start + 1: end] if "%% fm:manual:" in l]
            items = (self.open_items() + manual) or ["- (nothing open)"]
            lines[start + 1: end] = [""] + items + [""]
        self.store(path, lines)
        return path

    def queue_md(self, generated):
        rows = list(self.rows.values())
        prs = {p["id"]: p["url"] for p in self.snapshot.get("recorded_prs", []) or []}
        live = [r for r in rows if r.get("state") != "done" and r.get("hold_kind") == "captain"
                and r.get("hold_bucket") == "live"]
        blocked = [r for r in rows if r.get("state") != "done" and r.get("blocked_by")
                   and r.get("hold_bucket") in (None, "blocked") and r not in live]
        dated = sorted([r for r in rows if r.get("state") != "done" and r.get("hold_until")
                        and r not in live and r not in blocked], key=lambda r: r["hold_until"])
        parked = [r for r in rows if r.get("state") != "done" and r.get("hold_reason")
                  and r not in live and r not in blocked and r not in dated]
        queued = [r for r in rows if r.get("state") == "queued" and r not in live + blocked + dated + parked]
        done = sorted([r for r in rows if r.get("state") == "done"],
                      key=lambda r: (r.get("done") or "", r["id"]), reverse=True)[:DONE_SHOWN]
        out = ["# Work queue", "",
               "Generated %s from firstmate's fleet snapshot. Edits here are overwritten; steer firstmate in chat or on the board." % generated,
               ""]

        def section(title, items):
            out.extend(["## %s (%d)" % (title, len(items)), ""])
            out.extend(items or ["- (none)"])
            out.append("")

        section("Waiting on you", ["- %s\n  %s" % (self.row_text(r), clean(r.get("hold_reason"), self.cfg))
                                   for r in live])
        section("Blocked", ["- %s\n  blocked by %s" % (self.row_text(r), ", ".join(r["blocked_by"])) for r in blocked])
        flight = []
        for r in self.snapshot.get("in_flight", []) or []:
            extra = " ".join(x for x in (clean(r.get("doing"), self.cfg), prs.get(r["id"], "")) if x)
            flight.append("- %s%s" % (self.linked(clean(r.get("name") or r["id"], self.cfg, 90)),
                                      ("\n  " + extra) if extra else ""))
        section("In flight", flight)
        section("Deferred", ["- until [[%s]]: %s" % (r["hold_until"], self.row_text(r)) for r in dated])
        section("Parked", ["- %s\n  %s" % (self.row_text(r), clean(r.get("hold_reason"), self.cfg)) for r in parked])
        items = ["- %s" % self.row_text(r) for r in queued[:QUEUED_SHOWN]]
        if len(queued) > QUEUED_SHOWN:
            items.append("- and %d more on the board" % (len(queued) - QUEUED_SHOWN))
        out.extend(["## Queued (%d)" % len(queued), ""] + (items or ["- (none)"]) + [""])
        section("Done recently", ["- %s%s" % (self.row_text(r), (" " + r["pr_url"]) if r.get("pr_url") else "")
                                  for r in done])
        return "\n".join(out)


def cmd_sync(args):
    root, config_dir, ledger, cursor_path, snapshot_path, board_target, today, generated = args
    snapshot = None
    if snapshot_path and os.path.isfile(snapshot_path):
        try:
            with open(snapshot_path, encoding="utf-8") as fh:
                snapshot = json.load(fh)
        except (OSError, ValueError):
            snapshot = None
    log = Log(root, config_dir, snapshot, board_target, today)
    offset = 0
    try:
        offset = int((read(cursor_path) or "0").strip() or 0)
    except ValueError:
        offset = 0
    size = os.path.getsize(ledger) if os.path.isfile(ledger) else 0
    if size < offset:
        offset = 0
    rendered = 0
    new_offset = offset
    if size > offset:
        with open(ledger, "rb") as fh:
            fh.seek(offset)
            data = fh.read()
        complete = data[: data.rfind(b"\n") + 1]
        for raw in complete.split(b"\n"):
            if not raw.strip():
                continue
            try:
                rec = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                continue
            if not isinstance(rec, dict):
                continue
            eid = hashlib.sha1(raw).hexdigest()[:12]
            log.render(rec, eid)
            rendered += 1
        new_offset = offset + len(complete)
    today_path = log.refresh_today()
    queue_path = os.path.join(root, "queue.md")
    if snapshot is not None and snapshot.get("queue") is not None:
        text = log.queue_md(generated)
        if read(queue_path) != text + "\n":
            write_atomic(queue_path, text + "\n")
    else:
        old = read(queue_path)
        if old is not None and "Stale since" not in old:
            lines = old.split("\n")
            lines.insert(2, "> Stale since %s: the fleet snapshot could not be read." % generated)
            write_atomic(queue_path, "\n".join(lines))
    log.flush()
    # The cursor advances only after every file is written, so a crash replays.
    tmp = cursor_path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write("%d\n" % new_offset)
    os.replace(tmp, cursor_path)
    print(today_path)
    sys.stderr.write("fm-log: rendered %d record(s)\n" % rendered)


def cmd_add(args):
    root, config_dir, board_target, today, section, text = args
    log = Log(root, config_dir, None, board_target, today)
    name = {"worked": "Worked through", "open": "Open at close", "carried": "Carried over",
            "asked": "Asked and answered"}[section]
    path = log.day(today)
    stamp = datetime.datetime.now().strftime("%H:%M") if section == "worked" else ""
    aid = "manual:" + hashlib.sha1((today + section + text).encode()).hexdigest()[:12]
    if not log.has_anchor(path, aid):
        body = clean(text, log.cfg, 1000)
        log.append_bullet(path, name, ("%s %s" % (stamp, body)).strip() + " " + ANCHOR.format(aid))
    log.flush()
    print(path)


def cmd_ticket(args):
    root, config_dir, tid, text = args
    log = Log(root, config_dir, None, "", "")
    url = log.cfg.ticket_url(tid)
    header = ["# " + tid, ""] + (["[Open in the tracker](%s)" % url, ""] if url else [])
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    aid = "manual:" + hashlib.sha1((tid + text).encode()).hexdigest()[:12]
    log.side_note("tickets", tid, header, "%s %s" % (stamp, clean(text, log.cfg, 1000)), aid)
    log.flush()
    print(os.path.join(root, "tickets", safe_name(tid) + ".md"))


def cmd_learn(args):
    root, slug, title = args
    body = sys.stdin.read()
    path = os.path.join(root, "learnings", safe_name(slug) + ".md")
    text = "# %s\n\n%s" % (title.strip(), body if body.endswith("\n") or not body else body + "\n")
    if read(path) != text:
        write_atomic(path, text)
    print(path)


def cmd_unresolved(args):
    root, = args
    names = set()
    for top, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in files:
            names.add(os.path.splitext(name)[0])
            names.add(os.path.relpath(os.path.join(top, os.path.splitext(name)[0]), root).replace(os.sep, "/"))
    missing = set()
    for top, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in files:
            if not name.endswith(".md"):
                continue
            for link in re.findall(r"\[\[([^\]|#]+)", read(os.path.join(top, name)) or ""):
                # A day link names a day note that exists once that day is logged.
                if link.strip() not in names and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", link.strip()):
                    missing.add(link.strip())
    for link in sorted(missing):
        print(link)


# ---- recall index: derived and disposable, `index --rebuild` recreates it ----

INDEX_SCHEMA = "1"
GROUP_WEIGHT = {"decision": 5.0, "learning": 4.0, "outcome": 3.0, "report": 3.0, "timeline": 1.0}
HALF_LIFE_DAYS = 60.0
DEFAULT_LINES = 40
DEFAULT_BYTES = 2500
ENTITIES_SHOWN = 6
OPEN_SHOWN = 8
STOPWORDS = frozenset(
    "a about an and any at by did do does for from how in is it last me my of on or our show "
    "tell that the this time to us was we what when which who why with".split())
DAY_NOTE = re.compile(r"^(\d{4})/(\d{2})/(\d{2})(?:\.md|/log\.md|/(\d{4})-(\d{2})-(\d{2})\.md)$")
LINE_DATE = re.compile(r"^(\d{4}-\d{2}-\d{2})(?: (\d{2}):(\d{2}))?\b")
LINE_TIME = re.compile(r"^(\d{2}):(\d{2})\b")
FM_ANCHOR = re.compile(r"%%\s*fm:([^%]*?)\s*%%")
ANY_COMMENT = re.compile(r"%%.*?%%")
NOTE_FOLDERS = {"tickets": "ticket", "projects": "project", "people": "person"}


def index_connect(db):
    import sqlite3
    conn = sqlite3.connect(db, timeout=5)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    return conn


def index_schema(conn):
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
        CREATE TABLE IF NOT EXISTS files(key TEXT PRIMARY KEY, mtime REAL, size INTEGER);
        CREATE TABLE IF NOT EXISTS tasks(task TEXT PRIMARY KEY, title TEXT, project TEXT, people TEXT);
        CREATE TABLE IF NOT EXISTS rows(id INTEGER PRIMARY KEY, uid TEXT UNIQUE, kind TEXT, ts INTEGER,
            task TEXT, what TEXT, answer TEXT, state TEXT, cite TEXT, src TEXT, private INTEGER);
        CREATE INDEX IF NOT EXISTS rows_task ON rows(task, ts);
        CREATE INDEX IF NOT EXISTS rows_ts ON rows(ts);
        CREATE INDEX IF NOT EXISTS rows_src ON rows(src);
        CREATE TABLE IF NOT EXISTS links(row INTEGER, kind TEXT, name TEXT COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS links_name ON links(kind, name);
        CREATE INDEX IF NOT EXISTS links_row ON links(row);
        CREATE TABLE IF NOT EXISTS ents(kind TEXT, name TEXT COLLATE NOCASE, task TEXT, note TEXT);
        CREATE INDEX IF NOT EXISTS ents_name ON ents(kind, name);
        CREATE INDEX IF NOT EXISTS ents_task ON ents(task);
        CREATE TABLE IF NOT EXISTS open(task TEXT, state TEXT, since TEXT);
        CREATE VIRTUAL TABLE IF NOT EXISTS rows_fts USING fts5(body, tokenize='porter unicode61', prefix='2 3');
        CREATE VIRTUAL TABLE IF NOT EXISTS tasks_fts USING fts5(task, title, tokenize='porter unicode61', prefix='2 3');
    """)


def index_drop(conn):
    for name in ("meta", "files", "tasks", "rows", "links", "ents", "open", "rows_fts", "tasks_fts"):
        conn.execute("DROP TABLE IF EXISTS %s" % name)


def config_digest(config_dir):
    h = hashlib.sha1()
    for name in ("log-tickets", "log-people", "log-redact"):
        h.update(((read(os.path.join(config_dir, name)) or "") + "\0").encode())
    return h.hexdigest()


def day_of(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d")


def epoch_of(day, hour=0, minute=0):
    try:
        return int(time.mktime(datetime.datetime.strptime(day, "%Y-%m-%d").replace(
            hour=hour, minute=minute).timetuple()))
    except ValueError:
        return 0


class Indexer:
    def __init__(self, conn, root, config_dir, data_dir):
        self.conn = conn
        self.root = root
        self.data = data_dir
        self.cfg = Config(config_dir)
        self.days = Log(root, config_dir, None, "", "")

    def put_row(self, uid, kind, ts, task, what, cite, src, answer="", state="", private=0, links=None):
        if links is None:
            links = [("ticket", t) for t in self.cfg.ticket_ids(what, answer)]
        cur = self.conn.execute(
            "INSERT INTO rows(uid,kind,ts,task,what,answer,state,cite,src,private) VALUES(?,?,?,?,?,?,?,?,?,?)",
            (uid, kind, ts, task, what, answer, state, cite, src, private))
        rid = cur.lastrowid
        self.conn.execute("INSERT INTO rows_fts(rowid, body) VALUES(?,?)", (rid, "%s %s" % (what, answer)))
        for kind_name in links:
            self.conn.execute("INSERT INTO links(row,kind,name) VALUES(?,?,?)", (rid,) + kind_name)
        return rid

    def refresh_fts(self, rid):
        what, answer = self.conn.execute("SELECT what, answer FROM rows WHERE id=?", (rid,)).fetchone()
        self.conn.execute("DELETE FROM rows_fts WHERE rowid=?", (rid,))
        self.conn.execute("INSERT INTO rows_fts(rowid, body) VALUES(?,?)", (rid, "%s %s" % (what, answer)))

    def drop_rows(self, where, args):
        ids = [r[0] for r in self.conn.execute("SELECT id FROM rows WHERE " + where, args)]
        for chunk in range(0, len(ids), 500):
            part = ids[chunk:chunk + 500]
            marks = ",".join("?" * len(part))
            self.conn.execute("DELETE FROM rows_fts WHERE rowid IN (%s)" % marks, part)
            self.conn.execute("DELETE FROM links WHERE row IN (%s)" % marks, part)
            self.conn.execute("DELETE FROM rows WHERE id IN (%s)" % marks, part)

    def day_cite(self, day, anchor):
        rel = os.path.relpath(self.days.day_path(day), self.root).replace(os.sep, "/")
        return "%s#fm:%s" % (rel, anchor)

    def task_seen(self, task, project=None):
        if not task:
            return
        self.conn.execute("INSERT OR IGNORE INTO tasks(task,title,project,people) VALUES(?,?,?,?)",
                          (task, "", "", ""))
        if project:
            self.conn.execute("UPDATE tasks SET project=? WHERE task=?", (project, task))

    # ---- ledger ---------------------------------------------------------
    def ingest_ledger(self, ledger):
        offset = int(self.meta("ledger_offset") or 0)
        size = os.path.getsize(ledger) if os.path.isfile(ledger) else 0
        if size < offset:
            offset = 0
        if size > offset:
            with open(ledger, "rb") as fh:
                fh.seek(offset)
                data = fh.read()
            complete = data[: data.rfind(b"\n") + 1]
            for raw in complete.split(b"\n"):
                if not raw.strip():
                    continue
                try:
                    rec = json.loads(raw.decode("utf-8"))
                except (ValueError, UnicodeDecodeError):
                    continue
                if isinstance(rec, dict) and isinstance(rec.get("ts"), int):
                    self.ledger_record(rec, hashlib.sha1(raw).hexdigest()[:12])
            offset += len(complete)
        self.set_meta("ledger_offset", str(offset))

    def ledger_record(self, rec, eid):
        event = rec.get("event")
        ts = rec["ts"]
        task = str(rec.get("task") or "")
        day = day_of(ts)
        cite = self.day_cite(day, eid)
        c = lambda text, cap=TEXT_CAP: clean(text, self.cfg, cap)
        if self.conn.execute("SELECT 1 FROM rows WHERE uid=?", (eid,)).fetchone():
            return
        if event == "task.dispatched":
            project = c(rec.get("project"), 80)
            self.task_seen(task, project)
            kind = c(rec.get("kind"), 20)
            what = "Started" + ((" " + kind) if kind and kind != "ship" else "") + ((" in " + project) if project else "")
            self.put_row(eid, "timeline", ts, task, what, cite, "ledger")
        elif event == "task.status" and rec.get("state") in STATUS_STATES:
            self.task_seen(task)
            label = {"done": "Finished", "failed": "Failed", "blocked": "Blocked",
                     "needs-decision": "Needs a decision"}[rec["state"]]
            detail = c(rec.get("text"))
            kind = "outcome" if rec["state"] in ("done", "failed") else "timeline"
            self.put_row(eid, kind, ts, task, label + ((" - " + detail) if detail else ""), cite, "ledger")
        elif event == "task.pr_ready":
            self.task_seen(task)
            self.put_row(eid, "outcome", ts, task, "Ready for review " + c(rec.get("pr"), 300), cite, "ledger")
        elif event == "task.merged":
            self.task_seen(task)
            url = c(rec.get("pr"), 300) if rec.get("via") == "pr" else ""
            self.put_row(eid, "outcome", ts, task, "Landed " + (url or "on the local branch"), cite, "ledger")
        elif event == "captain.held":
            self.task_seen(task)
            until = c(rec.get("until"), 10)
            self.put_row(eid, "decision", ts, task, c(rec.get("reason"), 1000), cite, "ledger",
                         state=("deferred to " + until) if until else "held")
        elif event == "captain.answered":
            self.task_seen(task)
            words = c(rec.get("words"), 1000)
            mode = c(rec.get("mode"), 20) or "answered"
            row = self.conn.execute(
                "SELECT id FROM rows WHERE kind='decision' AND task=? AND src='ledger' AND answer='' "
                "ORDER BY ts DESC, id DESC LIMIT 1", (task,)).fetchone()
            if row:
                self.conn.execute("UPDATE rows SET answer=?, state=?, ts=? WHERE id=?", (words, mode, ts, row[0]))
                self.refresh_fts(row[0])
            else:
                self.put_row(eid, "decision", ts, task, "", cite, "ledger", answer=words, state=mode)
        elif event == "inbox.noted" and rec.get("log_day"):
            note = c(rec.get("note"), 80)
            body = [l for l in (rec.get("text") or "").splitlines()
                    if not re.match(r"^(log_day|task|thread|question|log_note)=", l)]
            log_day = c(rec.get("log_day"), 10)
            day_cite = self.day_cite(log_day, "note:" + note) if re.fullmatch(r"\d{4}-\d{2}-\d{2}", log_day) else cite
            self.put_row(eid, "timeline", ts, task, "Noted: " + c(" ".join(body), 1000), day_cite, "ledger", private=1)
        elif event == "inbox.replied":
            self.put_row(eid, "timeline", ts, task, "Replied: " + c(rec.get("text"), 1000), cite, "ledger", private=1)
        elif event == "learning.filed":
            slug = safe_name(rec.get("slug") or "")
            uid = "learning:" + slug
            if self.conn.execute("SELECT 1 FROM rows WHERE uid=?", (uid,)).fetchone():
                self.conn.execute("UPDATE rows SET ts=?, src='ledger' WHERE uid=?", (ts, uid))
            else:
                self.put_row(uid, "learning", ts, "", c(rec.get("title"), 120),
                             "learnings/%s.md#top" % slug, "ledger")

    # ---- notes and reports ------------------------------------------------
    def sources(self):
        found = {}
        if os.path.isdir(self.root):
            for top, dirs, files in os.walk(self.root):
                dirs[:] = [d for d in dirs if not d.startswith(".") and d != "attachments"]
                for name in files:
                    if not name.endswith(".md"):
                        continue
                    path = os.path.join(top, name)
                    rel = os.path.relpath(path, self.root).replace(os.sep, "/")
                    if rel in ("queue.md", "README.md"):
                        continue
                    found["log:" + rel] = path
        if os.path.isdir(self.data):
            for name in sorted(os.listdir(self.data)):
                path = os.path.join(self.data, name, "report.md")
                if not name.startswith(".") and name != "log" and os.path.isfile(path):
                    found["report:" + name] = path
        return found

    def ingest_files(self):
        seen = self.sources()
        known = {k: (m, s) for k, m, s in self.conn.execute("SELECT key, mtime, size FROM files")}
        for key in sorted(set(known) - set(seen)):
            self.forget(key)
            self.conn.execute("DELETE FROM files WHERE key=?", (key,))
        for key in sorted(seen):
            try:
                st = os.stat(seen[key])
            except OSError:
                continue
            if known.get(key) == (st.st_mtime, st.st_size):
                continue
            self.forget(key)
            text = read(seen[key]) or ""
            if key.startswith("report:"):
                self.report(key[len("report:"):], text, st.st_mtime)
            else:
                self.note(key[len("log:"):], text, st.st_mtime)
            self.conn.execute("INSERT OR REPLACE INTO files(key,mtime,size) VALUES(?,?,?)",
                              (key, st.st_mtime, st.st_size))

    def forget(self, key):
        if key.startswith("log:learnings/"):
            slug = os.path.splitext(key[len("log:learnings/"):])[0]
            row = self.conn.execute("SELECT id, src FROM rows WHERE uid=?", ("learning:" + slug,)).fetchone()
            if row and row[1] == "ledger":
                self.conn.execute("UPDATE rows SET answer='' WHERE id=?", (row[0],))
                self.refresh_fts(row[0])
                return
        self.drop_rows("src=?", (key,))

    def report(self, task, text, mtime):
        title, para = "", []
        for line in text.splitlines():
            if not title and line.startswith("# "):
                title = line[2:].strip()
                continue
            if line.startswith("#"):
                if para:
                    break
                continue
            if line.strip():
                para.append(line.strip())
            elif para:
                break
        what = clean("Report: " + title + ((" - " + " ".join(para)) if para else ""), self.cfg, 300)
        self.put_row("report:" + task, "report", int(mtime), task, what,
                     "data/%s/report.md#top" % task, "report:" + task)

    def learning_note(self, rel, text, mtime):
        slug = os.path.splitext(rel[len("learnings/"):])[0]
        lines = text.splitlines()
        title = next((l[2:].strip() for l in lines if l.startswith("# ")), slug)
        body = " ".join(l.strip() for l in lines if l.strip() and not l.startswith("#"))
        title, body = clean(title, self.cfg, 120), clean(body, self.cfg, 600)
        row = self.conn.execute("SELECT id FROM rows WHERE uid=?", ("learning:" + slug,)).fetchone()
        if row:
            self.conn.execute("UPDATE rows SET what=?, answer=? WHERE id=?", (title, body, row[0]))
            self.refresh_fts(row[0])
        else:
            self.put_row("learning:" + slug, "learning", int(mtime), "", title,
                         "learnings/%s.md#top" % slug, "log:" + rel, answer=body)

    def note(self, rel, text, mtime):
        if rel.startswith("learnings/"):
            self.learning_note(rel, text, mtime)
            return
        folder, _, fname = rel.partition("/")
        links = []
        if folder in NOTE_FOLDERS and fname and "/" not in fname:
            links.append((NOTE_FOLDERS[folder], os.path.splitext(fname)[0]))
        m = DAY_NOTE.match(rel)
        note_day = "%s-%s-%s" % m.group(1, 2, 3) if m else day_of(int(mtime))
        section = ""
        for n, line in enumerate(text.splitlines(), 1):
            if line.startswith("#"):
                section = line.lstrip("#").strip()
                continue
            if not line.strip() or BOARD_LINE.match(line) or line.startswith("[Open in the tracker]"):
                continue
            anchors = FM_ANCHOR.findall(line)
            if m and (section == "Carried over" or (section == "Open at close" and not anchors)):
                continue
            if any(not a.startswith("manual:") for a in anchors):
                continue
            body = ANY_COMMENT.sub("", line).strip()
            body = re.sub(r"^[-*+]\s+", "", body)
            if not body or re.fullmatch(r"\((nothing|none)[^)]*\)", body):
                continue
            day, hour, minute = note_day, 0, 0
            dm = LINE_DATE.match(body)
            tm = LINE_TIME.match(body)
            if dm:
                day = dm.group(1)
                hour, minute = int(dm.group(2) or 0), int(dm.group(3) or 0)
                body = body[dm.end():].strip()
            elif tm:
                hour, minute = int(tm.group(1)), int(tm.group(2))
                body = body[tm.end():].strip()
            body = clean(body, self.cfg, 300)
            if not body:
                continue
            anchor = ("fm:" + anchors[0]) if anchors else "L%d" % n
            row_links = links + [("ticket", t) for t in self.cfg.ticket_ids(body)]
            self.put_row("md:%s#L%d" % (rel, n), "timeline", epoch_of(day, hour, minute), "", body,
                         "%s#%s" % (rel, anchor), "log:" + rel, private=1 if folder == "people" else 0,
                         links=row_links)

    # ---- entities -------------------------------------------------------
    def apply_snapshot(self, snapshot):
        if not isinstance(snapshot, dict):
            return
        for r in snapshot.get("queue") or []:
            task = str(r.get("id") or "")
            if not task:
                continue
            self.task_seen(task, clean(r.get("repo"), self.cfg, 80))
            people = [clean(p, self.cfg, 80) for p in r.get("people") or [] if self.cfg.person_ok(p)]
            self.conn.execute("UPDATE tasks SET title=?, people=? WHERE task=?",
                              (clean(r.get("title"), self.cfg, 120), "\n".join(people), task))
        for r in snapshot.get("in_flight") or []:
            task = str(r.get("id") or "")
            if task:
                self.task_seen(task, clean(r.get("repo"), self.cfg, 80))
                self.conn.execute("UPDATE tasks SET title=? WHERE task=? AND title=''",
                                  (clean(r.get("name"), self.cfg, 120), task))
        if snapshot.get("queue") is None:
            return
        self.conn.execute("DELETE FROM open")
        opened = []
        for r in snapshot.get("queue") or []:
            if r.get("state") == "done":
                continue
            if r.get("hold_kind") == "captain" and r.get("hold_bucket") == "live":
                opened.append((r.get("id"), "waiting on the captain"))
            elif r.get("blocked_by") and r.get("hold_bucket") in (None, "blocked"):
                opened.append((r.get("id"), "blocked by " + ", ".join(r["blocked_by"])))
        for r in snapshot.get("in_flight") or []:
            opened.append((r.get("id"), "in flight"))
        for task, state in opened:
            if not task:
                continue
            last = self.conn.execute("SELECT max(ts) FROM rows WHERE task=?", (task,)).fetchone()[0]
            self.conn.execute("INSERT INTO open(task,state,since) VALUES(?,?,?)",
                              (task, clean(state, self.cfg, 120), day_of(last) if last else ""))

    def registry_names(self):
        projects = []
        for line in (read(os.path.join(self.data, "projects.md")) or "").splitlines():
            m = re.match(r"^\s*-\s+(\S+)", line)
            if m:
                projects.append(m.group(1))
        return projects

    def rebuild_entities(self):
        conn = self.conn
        conn.execute("DELETE FROM ents")
        conn.execute("DELETE FROM tasks_fts")
        ents = set()
        for task, title, project, people in conn.execute("SELECT task, title, project, people FROM tasks").fetchall():
            ents.add(("task", task, task, ""))
            if project:
                ents.add(("project", project, task, "projects/%s.md" % safe_name(project)))
            for person in (people or "").split("\n"):
                if person:
                    ents.add(("person", person, task, "people/%s.md" % safe_name(person)))
            for tid in self.cfg.ticket_ids(task, title):
                ents.add(("ticket", tid, task, "tickets/%s.md" % safe_name(tid)))
            conn.execute("INSERT INTO tasks_fts(task, title) VALUES(?,?)", (task, title or ""))
        for name in self.registry_names():
            ents.add(("project", name, "", "projects/%s.md" % safe_name(name)))
        for name in sorted(self.cfg.people or ()):
            ents.add(("person", name, "", "people/%s.md" % safe_name(name)))
        for kind, name in conn.execute("SELECT DISTINCT kind, name FROM links").fetchall():
            folder = {v: k for k, v in NOTE_FOLDERS.items()}[kind]
            ents.add((kind, name, "", "%s/%s.md" % (folder, safe_name(name))))
        conn.executemany("INSERT INTO ents(kind,name,task,note) VALUES(?,?,?,?)", sorted(ents))

    def meta(self, key):
        row = self.conn.execute("SELECT v FROM meta WHERE k=?", (key,)).fetchone()
        return row[0] if row else None

    def set_meta(self, key, value):
        self.conn.execute("INSERT OR REPLACE INTO meta(k,v) VALUES(?,?)", (key, value))


def cmd_index(args):
    root, config_dir, data_dir, ledger, db, snapshot_path, rebuild = args
    snapshot = None
    if snapshot_path and os.path.isfile(snapshot_path):
        try:
            with open(snapshot_path, encoding="utf-8") as fh:
                snapshot = json.load(fh)
        except (OSError, ValueError):
            snapshot = None
    try:
        conn = index_connect(db)
        conn.execute("SELECT count(*) FROM sqlite_master").fetchone()
    except Exception:
        for suffix in ("", "-wal", "-shm"):
            try:
                os.remove(db + suffix)
            except OSError:
                pass
        conn = index_connect(db)
    digest = config_digest(config_dir)
    with conn:
        index_schema(conn)
        row = conn.execute("SELECT v FROM meta WHERE k='schema'").fetchone()
        row_cfg = conn.execute("SELECT v FROM meta WHERE k='config'").fetchone()
        if rebuild == "1" or not row or row[0] != INDEX_SCHEMA or not row_cfg or row_cfg[0] != digest:
            index_drop(conn)
            index_schema(conn)
        idx = Indexer(conn, root, config_dir, data_dir)
        idx.set_meta("schema", INDEX_SCHEMA)
        idx.set_meta("config", digest)
        idx.ingest_ledger(ledger)
        idx.ingest_files()
        idx.apply_snapshot(snapshot)
        idx.rebuild_entities()
    conn.close()
    return 0


# ---- recall ---------------------------------------------------------------

def parse_since(value, today):
    m = re.fullmatch(r"(\d+)d", value or "")
    if m:
        return epoch_of(today) - (int(m.group(1)) - 1) * 86400
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value or "") and epoch_of(value):
        return epoch_of(value)
    raise ValueError("--since takes YYYY-MM-DD or <N>d")


def trigrams(word):
    w = "  %s " % word.lower()
    return {w[i:i + 3] for i in range(len(w) - 2)}


def fts_query(terms):
    parts = []
    for term in terms:
        tok = re.sub(r"[^\w]+", " ", term).strip()
        if tok:
            phrase = tok.replace('"', '""')
            parts.append('("%s" OR "%s"*)' % (phrase, phrase) if " " not in tok else '"%s"' % phrase)
    return " AND ".join(parts)


class Recall:
    def __init__(self, conn, cfg, today):
        self.conn = conn
        self.cfg = cfg
        self.today = today
        self.now = epoch_of(today) + 86400

    def names(self):
        out = {}
        for kind, name in self.conn.execute("SELECT DISTINCT kind, name FROM ents"):
            out.setdefault(name.lower(), []).append((kind, name))
        return out

    def resolve(self, words):
        """Split free words into entity filters, leftover search terms, and ambiguity notes."""
        names = self.names()
        order = {"ticket": 0, "task": 1, "project": 2, "person": 3}
        tokens = [w.strip(".,;:!?()'\"") for w in words]
        tokens = [t for t in tokens if t]
        entities, terms, notes = [], [], []
        i = 0
        while i < len(tokens):
            hit = None
            for j in range(min(len(tokens), i + 4), i, -1):
                key = " ".join(tokens[i:j]).lower()
                if key in names:
                    hit = (j, sorted(names[key], key=lambda kn: order[kn[0]]))
                    break
            if hit:
                j, cands = hit
                kinds = {k for k, _ in cands}
                if len(kinds) > 1:
                    notes.append("%s also names %s" % (cands[0][1], ", ".join(
                        "%s %s" % kn for kn in cands[1:])))
                entities.append(cands[0] + ("exact",))
                i = j
                continue
            tok = tokens[i]
            tids = self.cfg.ticket_ids(tok)
            if tids and any(rx.fullmatch(tok) for rx, _ in self.cfg.tickets):
                entities.append(("ticket", tids[0], "pattern"))
            elif tok.lower() not in STOPWORDS:
                terms.append(tok)
            i += 1
        return entities, terms, notes

    def fuzzy(self, terms):
        """Misspelled names: terms with no text hit that resemble one entity name by trigrams."""
        found, left = [], []
        pool = [(kind, name) for kind, name in self.conn.execute(
            "SELECT DISTINCT kind, name FROM ents WHERE kind IN ('person','project','ticket')")]
        for term in terms:
            q = fts_query([term])
            hits = self.conn.execute("SELECT count(*) FROM (SELECT 1 FROM rows_fts WHERE rows_fts MATCH ? LIMIT 1)",
                                     (q,)).fetchone()[0] if q else 0
            if hits or len(term) < 4:
                left.append(term)
                continue
            tg = trigrams(term)
            best = (0.0, None)
            for kind, name in pool:
                for part in [name] + name.split():
                    pg = trigrams(part)
                    score = 2.0 * len(tg & pg) / (len(tg) + len(pg))
                    if score > best[0]:
                        best = (score, (kind, name))
            if best[0] >= 0.5:
                found.append(best[1] + ("near '%s'" % term,))
            else:
                left.append(term)
        return found, left

    def entity_rows(self, kind, name):
        rows = {}
        for (rid,) in self.conn.execute(
                "SELECT id FROM rows WHERE task IN (SELECT task FROM ents WHERE kind=? AND name=? AND task!='') "
                "ORDER BY ts DESC LIMIT 1500", (kind, name)):
            rows[rid] = 1.0
        for (rid,) in self.conn.execute("SELECT row FROM links WHERE kind=? AND name=? LIMIT 500", (kind, name)):
            rows[rid] = 1.0
        if kind != "task":
            q = '"%s"' % re.sub(r"[^\w]+", " ", name).strip()
            if q.strip('"'):
                for (rid,) in self.conn.execute(
                        "SELECT rowid FROM rows_fts WHERE rows_fts MATCH ? ORDER BY rank LIMIT 300", (q,)):
                    rows[rid] = 1.0
        return rows

    def term_rows(self, terms):
        rows = {}
        q = fts_query(terms)
        if not q:
            return rows
        for rid, bm in self.conn.execute(
                "SELECT rowid, bm25(rows_fts) FROM rows_fts WHERE rows_fts MATCH ? ORDER BY rank LIMIT 500", (q,)):
            rows[rid] = 1.0 + min(3.0, max(0.0, -bm))
        for (rid,) in self.conn.execute(
                "SELECT r.id FROM rows r JOIN tasks_fts t ON t.task = r.task WHERE tasks_fts MATCH ? "
                "ORDER BY r.ts DESC LIMIT 500", (q,)):
            rows.setdefault(rid, 1.5)
        return rows

    def fetch(self, ids, since, public_only):
        out = []
        ids = list(ids)
        for chunk in range(0, len(ids), 500):
            part = ids[chunk:chunk + 500]
            sql = ("SELECT id, uid, kind, ts, task, what, answer, state, cite, private FROM rows WHERE id IN (%s)"
                   % ",".join("?" * len(part)))
            for r in self.conn.execute(sql, part):
                if since is not None and r[3] < since:
                    continue
                if public_only and r[9]:
                    continue
                out.append(dict(zip(("id", "uid", "kind", "ts", "task", "what", "answer", "state", "cite", "private"), r)))
        return out

    def score(self, row, relevance, matched):
        age = max(0.0, (self.now - row["ts"]) / 86400.0)
        return GROUP_WEIGHT[row["kind"]] * (0.5 ** (age / HALF_LIFE_DAYS)) * relevance * (2.0 if matched else 1.0)

    def entity_summary(self, kind, name):
        row = self.conn.execute(
            "SELECT min(ts), max(ts), count(*) FROM rows WHERE task IN "
            "(SELECT task FROM ents WHERE kind=? AND name=? AND task!='') OR id IN "
            "(SELECT row FROM links WHERE kind=? AND name=?)", (kind, name, kind, name)).fetchone()
        note = self.conn.execute("SELECT note FROM ents WHERE kind=? AND name=? LIMIT 1", (kind, name)).fetchone()
        canon = self.conn.execute("SELECT name FROM ents WHERE kind=? AND name=? LIMIT 1", (kind, name)).fetchone()
        return {"kind": kind, "name": canon[0] if canon else name,
                "first": day_of(row[0]) if row[0] else "", "last": day_of(row[1]) if row[1] else "",
                "touches": row[2], "note": note[0] if note else ""}


def toon_value(value):
    text = str(value)
    if text == "" or "," in text or '"' in text or "\\" in text or text != text.strip():
        return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')
    return text


GROUPS = (
    ("entities", ("kind", "name", "first", "last", "touches", "note")),
    ("timeline", ("date", "what", "task", "cite")),
    ("decisions", ("date", "question", "answer", "state", "cite")),
    ("learnings", ("slug", "title", "filed", "cite")),
    ("open", ("task", "state", "since")),
)
PATH_FIELDS = ("cite", "note")


def recall_pack(rc, opts):
    public_only = opts.audience == "brief"
    since = parse_since(opts.since, rc.today) if opts.since else None
    entities, terms, notes = rc.resolve(opts.terms)
    for kind, flag in (("ticket", opts.ticket), ("project", opts.project), ("person", opts.person), ("task", opts.task)):
        for name in flag:
            entities.append((kind, name.upper() if kind == "ticket" else name, "flag"))
    if terms:
        extra, terms = rc.fuzzy(terms)
        entities += extra
    candidates, matched = {}, set()
    if opts.recent:
        since = rc.now - opts.days * 86400 if since is None else since
        for (rid,) in rc.conn.execute("SELECT id FROM rows WHERE ts >= ? ORDER BY ts DESC LIMIT 1500", (since,)):
            candidates[rid] = 1.0
    for kind, name, _ in entities:
        for rid, rel in rc.entity_rows(kind, name).items():
            candidates[rid] = max(candidates.get(rid, 0), rel)
            matched.add(rid)
    if terms:
        hits = rc.term_rows(terms)
        if entities:
            for rid, rel in hits.items():
                if rid in candidates:
                    candidates[rid] *= rel
        else:
            candidates.update(hits)
    rows = rc.fetch(candidates, since, public_only)
    for r in rows:
        r["score"] = rc.score(r, candidates[r["id"]], r["id"] in matched)
    rows.sort(key=lambda r: (-r["score"], -r["ts"], r["id"]))
    tasks = {r["task"] for r in rows if r["task"]} | {n for k, n, _ in entities if k == "task"}
    open_rows = []
    for task, state, since_day in rc.conn.execute("SELECT task, state, since FROM open ORDER BY since DESC, task"):
        if opts.recent or task in tasks:
            open_rows.append({"task": task, "state": state, "since": since_day})
    ents, seen = [], set()
    for kind, name, _ in entities:
        if (kind, name.lower()) not in seen:
            seen.add((kind, name.lower()))
            ents.append(rc.entity_summary(kind, name))
    related = {}
    for r in rows[:50]:
        if r["task"]:
            for kind, name in rc.conn.execute("SELECT kind, name FROM ents WHERE task=? AND kind!='task'", (r["task"],)):
                related.setdefault((kind, name), r["ts"])
    for (kind, name), _ in sorted(related.items(), key=lambda kv: -kv[1]):
        if (kind, name.lower()) not in seen and len(ents) < ENTITIES_SHOWN:
            seen.add((kind, name.lower()))
            ents.append(rc.entity_summary(kind, name))
    return entities, notes, ents[:ENTITIES_SHOWN], rows, open_rows[:OPEN_SHOWN], max(0, len(open_rows) - OPEN_SHOWN)


def group_row(r):
    date = day_of(r["ts"])
    if r["kind"] == "decision":
        return "decisions", {"date": date, "question": r["what"], "answer": r["answer"], "state": r["state"], "cite": r["cite"]}
    if r["kind"] == "learning":
        return "learnings", {"slug": r["uid"][len("learning:"):], "title": r["what"], "filed": date, "cite": r["cite"]}
    return "timeline", {"date": date, "what": r["what"], "task": r["task"], "cite": r["cite"]}


def render_pack(opts, query, resolved, notes, stale, ents, rows, open_rows, open_more):
    audience = opts.audience
    drop = PATH_FIELDS if audience in ("brief", "captain") else ()
    fields = {g: tuple(f for f in cols if f not in drop) for g, cols in GROUPS}
    head = ["query: " + query]
    if resolved:
        head.append("resolved: " + "; ".join(
            "%s %s%s" % (k, n, "" if via in ("exact", "flag", "pattern") else " (%s)" % via) for k, n, via in resolved))
    for note in notes:
        head.append("ambiguous: " + note)
    if stale:
        head.append("stale: index stale since " + stale)

    def line(group, rec):
        return "  " + ",".join(toon_value(rec[f]) for f in fields[group])

    groups = {"entities": list(ents), "timeline": [], "decisions": [], "learnings": [], "open": list(open_rows)}
    budget_lines = opts.limit
    budget_bytes = DEFAULT_BYTES * opts.limit // DEFAULT_LINES
    used_lines = len(head) + 1
    used_bytes = sum(len(h) + 1 for h in head)
    for g in ("entities", "open"):
        if groups[g]:
            used_lines += 1 + len(groups[g])
            used_bytes += 40 + sum(len(line(g, rec)) + 1 for rec in groups[g])
    more = open_more
    for r in rows:
        g, rec = group_row(r)
        cost = len(line(g, rec)) + 1 + (40 if not groups[g] else 0)
        extra = 1 if not groups[g] else 0
        if used_lines + 1 + extra > budget_lines or used_bytes + cost > budget_bytes:
            more += 1
            continue
        groups[g].append((r["ts"], r["id"], rec))
        used_lines += 1 + extra
        used_bytes += cost
    for g in ("timeline", "decisions", "learnings"):
        groups[g] = [rec for _, _, rec in sorted(groups[g], key=lambda t: (-t[0], -t[1]))]
    see = {}
    if audience == "captain":
        for g, _ in GROUPS:
            cites = [rec.get("cite") or rec.get("note") for rec in groups[g] if rec.get("cite") or rec.get("note")]
            if cites:
                see[g] = cites[0]
    found = any(groups[g] for g in ("timeline", "decisions", "learnings", "open")) or any(
        e["touches"] for e in groups["entities"])
    if opts.json:
        out = {"query": query, "resolved": [{"kind": k, "name": n, "via": v} for k, n, v in resolved],
               "ambiguous": notes, "stale": stale or None}
        for g, _ in GROUPS:
            out[g] = [{f: rec[f] for f in fields[g]} for rec in groups[g]]
        if see:
            out["see"] = see
        out["more"] = more
        return found, json.dumps(out, ensure_ascii=False, indent=1)
    body = list(head)
    for g, _ in GROUPS:
        if groups[g]:
            body.append("%s[%d]{%s}:" % (g, len(groups[g]), ",".join(fields[g])))
            body.extend(line(g, rec) for rec in groups[g])
            if g in see:
                body.append("%s_see: %s" % (g, see[g]))
    if not found:
        body.append("found: nothing in the log")
    if more:
        body.append("more: %d not shown (narrow with --since or raise --limit)" % more)
    return found, "\n".join(body)


def cmd_recall(args):
    import argparse
    parser = argparse.ArgumentParser(prog="fm-log.sh recall", add_help=False)
    parser.add_argument("root")
    parser.add_argument("config")
    parser.add_argument("db")
    parser.add_argument("stale")
    parser.add_argument("today")
    parser.add_argument("terms", nargs="*")
    for flag in ("ticket", "project", "person", "task"):
        parser.add_argument("--" + flag, action="append", default=[])
    parser.add_argument("--since")
    parser.add_argument("--limit", type=int, default=DEFAULT_LINES)
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--recent", action="store_true")
    parser.add_argument("--for", dest="audience", choices=("brief", "captain", "board"))
    brief = "--for=brief" in args or any(a == "--for" and b == "brief" for a, b in zip(args, args[1:]))
    try:
        opts = parser.parse_args(args)
    except SystemExit:
        return 0 if brief else 2
    try:
        if opts.limit < 5 or opts.days < 1:
            raise ValueError("--limit must be at least 5 and --days at least 1")
        if not (opts.terms or opts.ticket or opts.project or opts.person or opts.task or opts.recent):
            raise ValueError("recall needs terms, an entity flag, or --recent")
        if not os.path.isfile(opts.db):
            raise LookupError("the recall index is not built yet; run fm-log.sh index")
        import sqlite3
        conn = sqlite3.connect("file:%s?mode=ro" % opts.db, uri=True, timeout=2)
        stale = (read(opts.stale) or "").strip() if os.path.exists(opts.stale) else ""
        if os.path.exists(opts.stale) and not stale:
            stale = datetime.datetime.fromtimestamp(os.path.getmtime(opts.stale)).strftime("%Y-%m-%d %H:%M")
        rc = Recall(conn, Config(opts.config), opts.today)
        query = " ".join(opts.terms) or ("recent %dd" % opts.days if opts.recent else "")
        for kind in ("ticket", "project", "person", "task"):
            for name in getattr(opts, kind):
                query = (query + " " if query else "") + "--%s %s" % (kind, name)
        if opts.since:
            query += " --since " + opts.since
        resolved, notes, ents, rows, open_rows, open_more = recall_pack(rc, opts)
        found, text = render_pack(opts, query, resolved, notes, stale, ents, rows, open_rows, open_more)
        conn.close()
    except ValueError as err:
        if brief:
            return 0
        sys.stderr.write("fm-log: %s\n" % err)
        return 2
    except Exception as err:
        if brief:
            return 0
        sys.stderr.write("fm-log: recall failed: %s\n" % (err if isinstance(err, LookupError) else
                         "index unavailable (%s); run fm-log.sh index --rebuild" % err))
        return 1
    if brief and not found:
        return 0
    print(text)
    return 0

def main(argv):
    if len(argv) >= 2 and argv[1] == "recall":
        return cmd_recall(argv[2:])
    cmds = {"sync": (cmd_sync, 8), "add": (cmd_add, 6), "ticket": (cmd_ticket, 4),
            "learn": (cmd_learn, 3), "unresolved": (cmd_unresolved, 1), "index": (cmd_index, 7)}
    if len(argv) < 2 or argv[1] not in cmds or len(argv) - 2 != cmds[argv[1]][1]:
        sys.stderr.write("fm_log.py: internal usage error; run bin/fm-log.sh\n")
        return 2
    return cmds[argv[1]][0](argv[2:]) or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
