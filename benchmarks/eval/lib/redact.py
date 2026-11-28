#!/usr/bin/env python3
"""redact.py <command> ...   find the staged credential in what the harness PERSISTS, and take it out.

The SECRET SET is built by the harness at staging time (add-stdin / add-json-file, into a 0600 file in the cell root that run.sh
removes at exit) and handed to every scan on a FILE DESCRIPTOR (`3<file`): never in argv, never in the helper's environment, never
printed. Every message names files and counts only. Matching is exact byte search (bytes.find, no regex over a secret).
For each secret the variants searched are: the raw bytes, lowercase and uppercase contiguous hex, base64 and URL-safe base64 (padded and unpadded) and,
when it differs, its JSON-escaped form (so a row serialised as JSON cannot hide it).

  add-stdin SECRETS             append the whole of stdin as one secret (the value of an authentication variable, passed through a
                                pipe: the caller runs this with that variable removed from the environment). Ignored under 8 bytes.
  add-json-file SECRETS FILE    FILE (opened O_NOFOLLOW, regular, <= 1 MiB; a staged credential): append its full bytes (and the
                                bytes without trailing whitespace), and when it parses as JSON every string VALUE of 16 or more
                                characters found anywhere inside it (recursive; keys and shorter values are not secrets).
  scan-file FD PATH...          each PATH that is a regular file (a symlink / FIFO / missing name is skipped) is rewritten in place
                                with every hit replaced by [REDACTED]; a clean file is not touched. Prints `redacted <n> <path>`
                                per changed file and `total <n>`. Exit 0 clean, 3 something was redacted, other = error.
  scan-tree FD ROOT             walk ROOT by directory descriptors (no symlink followed, regular files read, nothing else opened,
                                other devices not crossed). A regular file holding a secret in its content OR its name is
                                DELETED (never rewritten: binary and text alike); an entry whose name holds it is removed.
                                Prints `deleted <relative path>` per file, `survivor <path>` for one that could not be removed,
                                `total <n>`. Exit 0 clean, 3 deleted, 1 a survivor, 2 bad ROOT.
  filter FD                     stdin -> stdout with every hit replaced by [REDACTED]; stderr gets `redacted <n>`.
                                Exit 0 clean, 3 something was redacted.
  annotate [--error-before TEXT] [--paths-file FILE]
                                stdin is one JSON row: add the string field `error_before` and the array field `credential_paths`
                                (one relative path per line of FILE) and print it (sort_keys, like row.py). Both inputs have
                                already passed the filter.

Files are read in CHUNK pieces and consecutive chunks overlap by the longest variant minus one byte, so a secret that spans a chunk
boundary is found. A file over MAXFILE bytes is not scanned: scan-tree deletes it, scan-file fails.
"""
import base64
import json
import os
import stat
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I removes the script dir; scrub.py lives beside this file
import scrub  # noqa: E402

REDACTED = b"[REDACTED]"
CHUNK = 1 << 20
MAXFILE = 1 << 30
WHOLE_MIN = 8
JSON_MIN = 16
MAXSET = 4096


def variants(s):
    out = {s, s.hex().encode(), s.hex().upper().encode()}
    for enc in (base64.b64encode, base64.urlsafe_b64encode):
        b = enc(s)
        out.add(b)
        out.add(b.rstrip(b"="))
    try:
        t = s.decode("utf-8")
        out.add(json.dumps(t)[1:-1].encode())
        out.add(json.dumps(t, ensure_ascii=False)[1:-1].encode())
    except UnicodeDecodeError:
        pass
    return {v for v in out if v}


def load(fd):
    """the variant list (longest first) from the secrets descriptor"""
    f = os.fdopen(fd, "rb", closefd=False)
    f.seek(0)
    allv = set()
    for line in f.read().splitlines():
        line = line.strip()
        if line:
            allv |= variants(bytes.fromhex(line.decode()))
    return sorted(allv, key=lambda v: (-len(v), v))


def stream(read, vs, write=None, first=False):
    """Scan the byte source read(n) for every variant. write(b) receives the text with each hit replaced; first=True returns at
    the first hit. Returns the number of hits."""
    if not vs:
        if write:
            while True:
                c = read(CHUNK)
                if not c:
                    return 0
                write(c)
        return 0
    keep = max(len(v) for v in vs) - 1
    carry, hits, final = b"", 0, False
    while not final:
        chunk = read(CHUNK)
        buf = carry + chunk
        final = not chunk
        limit = len(buf) if final else max(len(buf) - keep, 0)
        i, out, cache = 0, [], [-2] * len(vs)
        while True:
            best = None
            for k, v in enumerate(vs):
                p = cache[k]
                if p != -1 and p < i:
                    p = cache[k] = buf.find(v, i)
                if p >= 0 and (best is None or p < best[0]):
                    best = (p, len(v))   # vs is longest first: the first variant at a position wins the tie
            if best is None or (best[0] >= limit and not final):
                break
            hits += 1
            if first:
                return hits
            out.append(buf[i:best[0]])
            out.append(REDACTED)
            i = best[0] + best[1]
        cut = len(buf) if final else max(i, limit)
        out.append(buf[i:cut])
        carry = buf[cut:]
        if write:
            write(b"".join(out))
    return hits


def _open_regular(dfd, name, st):
    """a descriptor on the regular file `name` of dfd (lstat st), None when it cannot be proven the same regular file"""
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        try:
            fd = os.open(name, flags, dir_fd=dfd)
        except PermissionError:   # the agent may have chmod 000'd it: it is ours
            os.chmod(name, 0o600, dir_fd=dfd, follow_symlinks=False)
            fd = os.open(name, flags, dir_fd=dfd)
    except OSError:
        return None
    try:
        fs = os.fstat(fd)
        if (fs.st_dev, fs.st_ino) != (st.st_dev, st.st_ino) or not stat.S_ISREG(fs.st_mode):
            os.close(fd)
            return None
    except OSError:
        os.close(fd)
        return None
    return fd


def _writeall(fd, b):
    mv = memoryview(b)
    while mv:
        mv = mv[os.write(fd, mv):]


def _reader(fd):
    return lambda n: os.read(fd, n)


def scan_file(vs, path):
    """redact one file in place; returns hits (0 = untouched), raises OSError when it cannot be done"""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return 0
    if not stat.S_ISREG(st.st_mode):
        return 0
    if st.st_size > MAXFILE:
        raise OSError("larger than %d bytes" % MAXFILE)
    d, n = os.path.dirname(os.path.abspath(path)), os.path.basename(path)
    dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fd = _open_regular(dfd, n, st)
        if fd is None:
            raise OSError("cannot open %s" % n)
        try:
            if not stream(_reader(fd), vs, first=True):
                return 0
            os.lseek(fd, 0, os.SEEK_SET)
            tmp = n + ".redact.tmp"
            wfd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
            try:
                hits = stream(_reader(fd), vs, write=lambda b: _writeall(wfd, b))
                os.fchmod(wfd, stat.S_IMODE(st.st_mode) or 0o600)
                os.fsync(wfd)
            except BaseException:
                os.close(wfd)
                os.unlink(tmp, dir_fd=dfd)
                raise
            os.close(wfd)
            os.rename(tmp, n, src_dir_fd=dfd, dst_dir_fd=dfd)
            return hits
        finally:
            os.close(fd)
    finally:
        os.close(dfd)


class Tree:
    def __init__(self, vs, dev):
        self.vs, self.dev = vs, dev
        self.deleted, self.surv = [], []
        self.names = [v for v in vs]

    def name_hit(self, name):
        b = os.fsencode(name)
        return any(v in b for v in self.names)

    def walk(self, dfd, prefix, depth):
        try:
            names = os.listdir(dfd)
        except OSError:
            self.surv.append(prefix.rstrip("/") or ".")
            return
        for n in sorted(names):
            rel = prefix + n
            try:
                st = os.stat(n, dir_fd=dfd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            except OSError:
                self.surv.append(rel)
                continue
            hit_name = self.name_hit(n)
            if stat.S_ISDIR(st.st_mode):
                if hit_name:   # the whole subtree goes: its name is the leak
                    w = scrub._Walk(self.dev, set())
                    w.entry(dfd, n, rel, depth, False)
                    (self.surv if w.surv else self.deleted).append(rel)
                    continue
                if st.st_dev != self.dev or depth >= scrub.MAXDEPTH:
                    continue
                cfd = scrub._open_child_dir(dfd, n, st)
                if cfd is None:
                    self.surv.append(rel)
                    continue
                try:
                    self.walk(cfd, rel + "/", depth + 1)
                finally:
                    os.close(cfd)
            elif stat.S_ISREG(st.st_mode):
                bad = hit_name
                if not bad:
                    if st.st_size > MAXFILE:
                        bad = True
                    else:
                        fd = _open_regular(dfd, n, st)
                        if fd is None:
                            self.surv.append(rel)   # unreadable: it cannot be proven clean
                            continue
                        try:
                            bad = stream(_reader(fd), self.vs, first=True) > 0
                        finally:
                            os.close(fd)
                if bad:
                    (self.deleted if scrub._unlink(dfd, n) else self.surv).append(rel)
            elif hit_name:   # a link / FIFO / socket is never opened; only a name that holds the secret is removed
                (self.deleted if scrub._unlink(dfd, n) else self.surv).append(rel)


def cmd_add_stdin(secrets):
    data = sys.stdin.buffer.read()
    if len(data) >= WHOLE_MIN:
        _append(secrets, [data])
    return 0


def _strings(o, out):
    if isinstance(o, str):
        if len(o) >= JSON_MIN:
            out.append(o.encode("utf-8", "surrogatepass"))
    elif isinstance(o, dict):
        for v in o.values():
            _strings(v, out)
    elif isinstance(o, list):
        for v in o:
            _strings(v, out)


def cmd_add_json_file(secrets, path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            print("add-json-file: not a regular file", file=sys.stderr)
            return 2
        data = b""
        while True:
            c = os.read(fd, 65536)
            if not c:
                break
            data += c
            if len(data) > (1 << 20):
                print("add-json-file: larger than 1 MiB", file=sys.stderr)
                return 2
    finally:
        os.close(fd)
    items = [data, data.rstrip()]
    try:
        _strings(json.loads(data.decode("utf-8")), items)
    except ValueError:
        pass
    _append(secrets, [s for s in items if len(s) >= (WHOLE_MIN if s in (data, data.rstrip()) else JSON_MIN)])
    return 0


def _append(secrets, items):
    fd = os.open(secrets, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        for s in dict.fromkeys(items):
            os.write(fd, s.hex().encode() + b"\n")
    finally:
        os.close(fd)


def main():
    a = sys.argv[1:]
    try:
        c = a[0]
        if c == "add-stdin" and len(a) == 2:
            return cmd_add_stdin(a[1])
        if c == "add-json-file" and len(a) == 3:
            return cmd_add_json_file(a[1], a[2])
        if c in ("scan-file", "scan-tree", "filter"):
            vs = load(int(a[1]))
            if len(vs) > MAXSET:
                print("redact: secret set too large", file=sys.stderr)
                return 2
            if c == "scan-file":
                total = 0
                for p in a[2:]:
                    n = scan_file(vs, p)
                    if n:
                        print("redacted %d %s" % (n, scrub._q(p)))
                    total += n
                print("total %d" % total)
                return 3 if total else 0
            if c == "scan-tree" and len(a) == 3:
                scrub._raise_nofile()
                r = scrub._open_root(a[2])
                if r is None:
                    print("scan-tree: %s is not a real directory owned by this user" % scrub._q(a[2]), file=sys.stderr)
                    return 2
                fd, fs = r
                t = Tree(vs, fs.st_dev)
                try:
                    t.walk(fd, "", 0)
                finally:
                    os.close(fd)
                for p in t.deleted:
                    print("deleted " + scrub._q(p))
                for p in t.surv:
                    print("survivor " + scrub._q(p))
                print("total %d" % len(t.deleted))
                return 1 if t.surv else (3 if t.deleted else 0)
            if c == "filter" and len(a) == 2:
                out = sys.stdout.buffer
                n = stream(lambda k: sys.stdin.buffer.read1(k), vs, write=out.write)
                out.flush()
                print("redacted %d" % n, file=sys.stderr)
                return 3 if n else 0
        if c == "annotate":
            eb, pf, i = None, None, 1
            while i + 1 < len(a) and a[i] in ("--error-before", "--paths-file"):
                if a[i] == "--error-before":
                    eb = a[i + 1]
                else:
                    pf = a[i + 1]
                i += 2
            if i != len(a):
                raise IndexError
            row = json.loads(sys.stdin.read())
            if eb:
                row["error_before"] = eb
            if pf:
                with open(pf, encoding="utf-8", errors="replace") as f:
                    row["credential_paths"] = [l.rstrip("\n") for l in f if l.strip()]
            sys.stdout.write(json.dumps(row, sort_keys=True) + "\n")
            return 0
    except (IndexError, ValueError):
        pass
    except OSError as e:
        print("redact: %s" % scrub._q(str(e)), file=sys.stderr)
        return 2
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
