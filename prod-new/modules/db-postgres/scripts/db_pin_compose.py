#!/usr/bin/env python3
"""db_pin_compose.py -- parse ONE compose file and prove its database images match the lock.

Called by db-pin-check.sh (never by hand):

    db_pin_compose.py --pin REPO=TAG@DIGEST [--pin ...] [--platform-digest D ...]
                      [--non-db-build SERVICE ...] FILE

Why a parser: the first version of the gate read compose files line by line, and a
zero-match result was only a WARN. Flow maps, quoted keys, values on the next line,
`build:` + args, `extends:` and an empty `services:` all left the database unpinned
yet exited 0. Here the file is loaded with yaml.safe_load (merge keys and anchors are
resolved by the loader) and `services` is walked.

Rules, in the order they are reported (every finding is one `FAIL <CODE>: ...` line):

  DOC        the file is not exactly one YAML document whose top level is a mapping;
             a duplicate key anywhere is an error (PyYAML alone keeps the last one).
  INCLUDE    top-level `include:` pulls services from files this run does not parse.
  EXTENDS    any service with `extends:`: its image may come from another file.
  BUILD      any service with `build:` is refused UNLESS the INVOKER named it with
             `--non-db-build NAME`. A build's base image is invisible here (args,
             Dockerfile), so the compose file cannot vouch for itself: the exemption
             lives on the command line, outside the file. A service that has BOTH
             `build:` and an image of a database repository is refused even if named.
  VARIABLE   an `image` containing `$` cannot be resolved offline: refused.
  IMAGE      a non-string/missing image on a service without build.
  LATEST     any image (database or not) with no tag or a `latest` tag.
  DIGEST     any image (database or not) with no `@sha256:` digest.
  PIN        an image whose repository is `postgres` or `timescale/timescaledb`
             (any registry host prefix, optional `library/`) must equal the lock's
             `tag@digest` for it. Only the INDEX digest passes; a per-platform digest
             is refused by name.
  NO-DB      the file has no service running a lock image at all: the gate would
             otherwise certify a file that does not contain the database.

Exit: 0 ok, 1 findings, 2 cannot answer (usage, PyYAML missing, unreadable file).
Last stdout line on 0/1: `REFS <n>` (images seen, database or not).
"""
import sys

try:
    import yaml
except ImportError:
    print("FAIL PARSER: PyYAML is not importable -- the compose file cannot be parsed, so it is not proven pinned")
    sys.exit(2)


class UniqueKeyLoader(yaml.SafeLoader):
    """SafeLoader that rejects a key repeated inside one mapping."""

    def construct_mapping(self, node, deep=False):
        if isinstance(node, yaml.MappingNode):
            seen = set()
            for key_node, _ in node.value:
                if key_node.tag == "tag:yaml.org,2002:merge":
                    continue
                key = self.construct_object(key_node, deep=True)
                try:
                    dup = key in seen
                except TypeError:
                    continue  # unhashable: the base class reports it
                if dup:
                    raise yaml.constructor.ConstructorError(
                        None, None, "duplicate key %r" % (key,), key_node.start_mark)
                seen.add(key)
        return super().construct_mapping(node, deep)


def usage(msg):
    print("usage: db_pin_compose.py --pin REPO=TAG@DIGEST... [--platform-digest D...] [--non-db-build S...] FILE (%s)" % msg)
    sys.exit(2)


def split_ref(ref):
    """-> (repo, tag, digest); tag/digest are '' when absent."""
    name, digest = ref, ""
    if "@" in ref:
        name, digest = ref.split("@", 1)
    tag = ""
    last = name.rsplit("/", 1)[-1]
    if ":" in last:
        name, tag = name.rsplit(":", 1)
    return name, tag, digest


def norm_repo(repo):
    """Strip a registry host and `library/`: `docker.io/library/postgres` -> `postgres`."""
    parts = repo.lower().split("/")
    if len(parts) > 1 and ("." in parts[0] or ":" in parts[0] or parts[0] == "localhost"):
        parts = parts[1:]
    if parts[0] == "library" and len(parts) > 1:
        parts = parts[1:]
    return "/".join(parts)


def main(argv):
    pins, platform, nodb, files = {}, set(), set(), []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--pin", "--platform-digest", "--non-db-build"):
            if i + 1 >= len(argv):
                usage("%s needs a value" % a)
            v = argv[i + 1]
            i += 2
            if a == "--pin":
                repo, sep, want = v.partition("=")
                if not sep or "@" not in want:
                    usage("bad --pin %r" % v)
                pins[repo] = want
            elif a == "--platform-digest":
                platform.add(v)
            else:
                nodb.add(v)
        elif a.startswith("--"):
            usage("unknown option %s" % a)
        else:
            files.append(a)
            i += 1
    if len(files) != 1 or not pins:
        usage("need exactly one FILE and at least one --pin")
    path = files[0]

    fails = []

    def fail(code, msg):
        fails.append("FAIL %s: %s: %s" % (code, path, msg))

    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError) as e:
        print("FAIL USAGE: cannot read %s: %s" % (path, e))
        return 2

    try:
        docs = list(yaml.load_all(text, Loader=UniqueKeyLoader))
    except yaml.YAMLError as e:
        fail("DOC", "not parseable YAML: %s" % str(e).replace("\n", " "))
        docs = None
    if docs is not None and len(docs) != 1:
        fail("DOC", "%d YAML documents, expected exactly 1" % len(docs))
        docs = None
    refs = 0
    db_services = 0
    if docs is not None:
        top = docs[0]
        if not isinstance(top, dict):
            fail("DOC", "top level is not a mapping")
        else:
            if "include" in top:
                fail("INCLUDE", "`include:` pulls in services this gate does not parse")
            services = top.get("services")
            if not isinstance(services, dict) or not services:
                fail("DOC", "`services` is missing, empty or not a mapping")
                services = {}
            for name, svc in services.items():
                if not isinstance(svc, dict):
                    fail("DOC", "service %s is not a mapping" % name)
                    continue
                image = svc.get("image")
                is_db = False
                if isinstance(image, str):
                    is_db = norm_repo(split_ref(image)[0]) in pins
                if "extends" in svc:
                    fail("EXTENDS", "service %s uses extends: its image may come from another file" % name)
                if "build" in svc:
                    if is_db:
                        fail("BUILD", "service %s builds an image named %s: the database must be the pinned image itself" % (name, image))
                    elif name not in nodb:
                        fail("BUILD", "service %s has build: its base image is not visible here; the invoker must name it with --non-db-build" % name)
                    if "image" not in svc:
                        continue
                if image is None or not isinstance(image, str) or not image.strip():
                    if "build" not in svc and "extends" not in svc:
                        fail("IMAGE", "service %s has no usable image" % name)
                    continue
                refs += 1
                if "$" in image:
                    fail("VARIABLE", "service %s image '%s' is a variable: cannot be proven pinned" % (name, image))
                    continue
                repo, tag, digest = split_ref(image)
                if not tag:
                    fail("LATEST", "service %s image '%s' has no tag" % (name, image))
                elif "latest" in tag:
                    fail("LATEST", "service %s image '%s' uses a floating tag" % (name, image))
                if not digest:
                    fail("DIGEST", "service %s image '%s' has no @sha256 digest" % (name, image))
                key = norm_repo(repo)
                if key in pins:
                    db_services += 1
                    want = pins[key]
                    want_tag, want_digest = want.split("@", 1)
                    if tag and tag != want_tag:
                        fail("PIN", "service %s image '%s' tag differs from the lock (%s)" % (name, image, want_tag))
                    if digest and digest != want_digest:
                        if digest in platform:
                            fail("PIN", "service %s image '%s' uses a per-platform digest; pin the INDEX digest of the lock" % (name, image))
                        else:
                            fail("PIN", "service %s image '%s' digest is not the lock's %s digest" % (name, image, key))
            if db_services == 0:
                fail("NO-DB", "no service runs a lock image (%s)" % ", ".join(sorted(pins)))
    elif not fails:
        fail("DOC", "unreadable")

    for line in fails:
        print(line)
    print("REFS %d" % refs)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
