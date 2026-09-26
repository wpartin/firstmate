#!/usr/bin/env python3
"""fm_log.py - the captain's log renderer, run only by bin/fm-log.sh.

bin/fm-log.sh owns configuration, the lock, and the command surface;
docs/captains-log.md owns the reader-facing layout. This module owns only how
fleet activity ledger records (docs/fleet-ledger.md) and one bearings snapshot
become Markdown files under the log root.

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


def main(argv):
    cmds = {"sync": (cmd_sync, 8), "add": (cmd_add, 6), "ticket": (cmd_ticket, 4),
            "learn": (cmd_learn, 3), "unresolved": (cmd_unresolved, 1)}
    if len(argv) < 2 or argv[1] not in cmds or len(argv) - 2 != cmds[argv[1]][1]:
        sys.stderr.write("fm_log.py: internal usage error; run bin/fm-log.sh\n")
        return 2
    cmds[argv[1]][0](argv[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
