"""Transport-independent admission and durable delivery for one Matrix agent.

No network, provider invocation, or device trust decisions live here. The Matrix
adapter must authenticate/decrypt events before setting ``decrypted=True``.
Each account owns one private directory and one process for the lifetime of Store.
"""
from dataclasses import dataclass
import fcntl
import hashlib
import re
import json
import os
from pathlib import Path
import sqlite3
import stat
from types import MappingProxyType


MAX_TEXT_BYTES = 16_384
MAX_REPLY_BYTES = 65_536


def HANDLE_RE(account):
    """Whole-token @localpart of a Matrix account, case-insensitive (e.g. @fambot for @fambot:hs)."""
    localpart = account[1:].split(":", 1)[0]
    return re.compile(r"(?<![\w.@-])@" + re.escape(localpart) + r"(?![\w.:-])", re.IGNORECASE)


def identifier(value, prefix):
    return (isinstance(value, str) and value.startswith(prefix)
            and 1 < len(value) <= 255 and not any(ord(c) < 33 for c in value))


def bounded_text(value, limit):
    if not isinstance(value, str) or not value.strip() or "\x00" in value:
        raise ValueError("invalid text")
    try:
        if len(value.encode("utf-8")) > limit:
            raise ValueError("text too large")
    except UnicodeError:
        raise ValueError("invalid text encoding") from None
    return value


@dataclass(frozen=True)
class Request:
    event_id: str
    room_id: str
    sender: str
    body: str
    scope: str


@dataclass(frozen=True)
class Policy:
    account: str
    users: frozenset
    bots: frozenset
    rooms: dict
    not_before_ms: int

    def __post_init__(self):
        users, bots, rooms = frozenset(self.users), frozenset(self.bots), dict(self.rooms)
        if (not identifier(self.account, "@") or not users or not rooms
                or self.account not in bots or users & bots
                or any(not identifier(u, "@") for u in users | bots)
                or any(not identifier(r, "!") or mode not in {"direct", "mention"}
                       for r, mode in rooms.items())
                or type(self.not_before_ms) is not int or self.not_before_ms < 0):
            raise ValueError("invalid route policy")
        object.__setattr__(self, "users", users)
        object.__setattr__(self, "bots", bots)
        object.__setattr__(self, "rooms", MappingProxyType(rooms))

    def admit(self, room_id, event, *, decrypted, now_ms):
        """Reject plaintext, edits, bots, old events and unaddressed group messages."""
        if decrypted is not True or room_id not in self.rooms or not isinstance(event, dict):
            return None
        sender = event.get("sender")
        if not isinstance(sender, str) or sender not in self.users or sender in self.bots:
            return None
        stamp = event.get("origin_server_ts")
        if (event.get("type") != "m.room.message" or not identifier(event.get("event_id"), "$")
                or type(stamp) is not int or type(now_ms) is not int
                or stamp < max(self.not_before_ms, now_ms - 86_400_000)
                or stamp > now_ms + 60_000):
            return None
        content = event.get("content")
        if not isinstance(content, dict) or content.get("msgtype") != "m.text":
            return None
        relation = content.get("m.relates_to", {})
        if not isinstance(relation, dict) or "rel_type" in relation:
            return None
        try:
            body = bounded_text(content.get("body"), MAX_TEXT_BYTES)
        except ValueError:
            return None
        if self.rooms[room_id] == "mention" and not self.addressed(content, body):
            return None
        scope = hashlib.sha256(json.dumps([self.account, room_id, sender]).encode()).hexdigest()
        return Request(event["event_id"], room_id, sender, body, scope)


    def addressed(self, content, body):
        """Family-room gate: spec'd m.mentions, or a typed @localpart handle in the body.

        Element X only emits m.mentions for pill mentions; family members on
        the phone type "@fambot" as plain text (owner request 2026-09-17).
        The handle must match the bot's own localpart as a whole token —
        display names and partial matches still do not count.
        """
        mentions = content.get("m.mentions", {})
        if isinstance(mentions, dict):
            ids = mentions.get("user_ids", [])
            if isinstance(ids, list) and self.account in ids:
                return True
        return bool(HANDLE_RE(self.account).search(body))


class QueueFull(RuntimeError):
    pass


def private_directory(path):
    """Open every component without following links; return a pinned directory fd."""
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("state directory must be an absolute path without traversal")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for i, part in enumerate(path.parts[1:]):
            if i == len(path.parts) - 2:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        st = os.fstat(fd)
        if st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
            raise ValueError("state directory must be owned by this user with mode 0700")
        return fd
    except BaseException:
        os.close(fd)
        raise


def private_file(directory_fd, name):
    fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                 0o600, dir_fd=directory_fd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_nlink != 1:
            raise ValueError("invalid state file")
        os.fchmod(fd, 0o600)
        return fd
    except BaseException:
        os.close(fd)
        raise


class Store:
    """Single-process inbox/outbox; uncertain execution is never automatically replayed."""

    def __init__(self, directory, account, *, total_cap=128, scope_cap=32):
        self.db = self.directory_fd = self.lock_fd = None
        if (not identifier(account, "@") or type(total_cap) is not int or type(scope_cap) is not int
                or not 1 <= scope_cap <= total_cap <= 1000):
            raise ValueError("invalid store settings")
        self.account, self.total_cap, self.scope_cap = account, total_cap, scope_cap
        try:
            self.directory_fd = private_directory(directory)
            self.lock_fd = private_file(self.directory_fd, "inbox.lock")
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            # SQLite may recover a rollback journal. Reject unsafe preexisting
            # journal/sidecar files before SQLite sees any of their paths.
            for name in ("inbox.sqlite3", "inbox.sqlite3-journal", "inbox.sqlite3-wal", "inbox.sqlite3-shm"):
                try:
                    os.stat(name, dir_fd=self.directory_fd, follow_symlinks=False)
                except FileNotFoundError:
                    continue
                fd = private_file(self.directory_fd, name)
                os.close(fd)
            fd = private_file(self.directory_fd, "inbox.sqlite3")
            os.close(fd)
            self.db = sqlite3.connect(f"/proc/self/fd/{self.directory_fd}/inbox.sqlite3")
            self.db.row_factory = sqlite3.Row
            self.db.execute("PRAGMA journal_mode=DELETE")
            self.db.execute("PRAGMA synchronous=FULL")
            self.db.executescript('''
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS jobs (
                    seq INTEGER PRIMARY KEY, event_id TEXT NOT NULL UNIQUE,
                    room_id TEXT NOT NULL, sender TEXT NOT NULL, scope TEXT NOT NULL,
                    body TEXT NOT NULL, digest TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('queued','running','uncertain','ready','done')),
                    reply TEXT, txn_id TEXT NOT NULL UNIQUE);
                CREATE TABLE IF NOT EXISTS sessions (scope TEXT PRIMARY KEY, session_id TEXT NOT NULL);
            ''')
            with self.db:
                for key, value in (("account", account), ("schema", "1")):
                    old = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
                    if old and old[0] != value:
                        raise ValueError("state identity/schema mismatch")
                    self.db.execute("INSERT OR IGNORE INTO meta VALUES (?,?)", (key, value))
                self.db.execute("UPDATE jobs SET state='uncertain' WHERE state='running'")
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.db is not None:
            self.db.close()
            self.db = None
        for name in ("lock_fd", "directory_fd"):
            fd = getattr(self, name)
            if fd is not None:
                os.close(fd)
                setattr(self, name, None)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def token(self):
        row = self.db.execute("SELECT value FROM meta WHERE key='sync_token'").fetchone()
        return row[0] if row else None

    def accept_batch(self, requests, next_token):
        """Commit admitted input and the /sync token together, or neither."""
        if next_token is not None:
            bounded_text(next_token, 4096)
        with self.db:
            for req in requests:
                if (not isinstance(req, Request) or not identifier(req.event_id, "$")
                        or not identifier(req.room_id, "!") or not identifier(req.sender, "@")):
                    raise ValueError("invalid request")
                bounded_text(req.body, MAX_TEXT_BYTES)
                expected_scope = hashlib.sha256(json.dumps([self.account, req.room_id, req.sender]).encode()).hexdigest()
                if req.scope != expected_scope:
                    raise ValueError("request belongs to another scope/account")
                digest = hashlib.sha256(json.dumps([req.room_id, req.sender, req.body]).encode()).hexdigest()
                old = self.db.execute("SELECT digest FROM jobs WHERE event_id=?", (req.event_id,)).fetchone()
                if old:
                    if old[0] != digest:
                        raise ValueError("event identity conflict")
                    continue
                count, scoped = self.db.execute(
                    "SELECT count(*), coalesce(sum(scope=?),0) FROM jobs WHERE state!='done'", (req.scope,)
                ).fetchone()
                if count >= self.total_cap or scoped >= self.scope_cap:
                    raise QueueFull("inbox capacity reached; sync token unchanged")
                txn = hashlib.sha256(json.dumps([self.account, req.event_id, "reply-v1"]).encode()).hexdigest()
                self.db.execute("INSERT INTO jobs(event_id,room_id,sender,scope,body,digest,state,txn_id) "
                                "VALUES (?,?,?,?,?,?,'queued',?)",
                                (req.event_id, req.room_id, req.sender, req.scope, req.body, digest, txn))
            if next_token is not None:
                self.db.execute("INSERT OR REPLACE INTO meta VALUES ('sync_token',?)", (next_token,))

    def claim(self):
        with self.db:
            row = self.db.execute("SELECT * FROM jobs q WHERE state='queued' AND NOT EXISTS "
                "(SELECT 1 FROM jobs p WHERE p.scope=q.scope AND p.seq<q.seq AND p.state!='done') "
                "ORDER BY seq LIMIT 1").fetchone()
            if row:
                self.db.execute("UPDATE jobs SET state='running' WHERE event_id=?", (row['event_id'],))
        return dict(row) if row else None

    def finish(self, event_id, reply, session_id=None):
        bounded_text(reply, MAX_REPLY_BYTES)
        if session_id is not None:
            bounded_text(session_id, 255)
        with self.db:
            row = self.db.execute("SELECT scope,state FROM jobs WHERE event_id=?", (event_id,)).fetchone()
            if row is None or row['state'] != 'running':
                raise ValueError("only running work can finish")
            self.db.execute("UPDATE jobs SET state='ready',reply=? WHERE event_id=?", (reply, event_id))
            if session_id is not None:
                self.db.execute("INSERT OR REPLACE INTO sessions VALUES (?,?)", (row['scope'], session_id))

    def session(self, scope):
        row = self.db.execute("SELECT session_id FROM sessions WHERE scope=?", (scope,)).fetchone()
        return row[0] if row else None

    def outbox(self):
        return [dict(row) for row in self.db.execute("SELECT * FROM jobs WHERE state='ready' ORDER BY seq")]

    def delivered(self, event_id):
        with self.db:
            if self.db.execute("UPDATE jobs SET state='done' WHERE event_id=? AND state='ready'", (event_id,)).rowcount != 1:
                raise ValueError("only a pending reply can be acknowledged")

    def uncertain(self):
        return [dict(row) for row in self.db.execute("SELECT * FROM jobs WHERE state='uncertain' ORDER BY seq")]

    def resolve_uncertain(self, event_id, reply):
        """Operator reconciliation result; never rerun an uncertain operation."""
        bounded_text(reply, MAX_REPLY_BYTES)
        with self.db:
            if self.db.execute("UPDATE jobs SET state='ready',reply=? WHERE event_id=? AND state='uncertain'",
                               (reply, event_id)).rowcount != 1:
                raise ValueError("no uncertain work to resolve")
