#!/usr/bin/env python3
"""Build the Compose --env-file for this recipe, and verify the pinned source.

    pinned upstream .env.example   (the operator's own checkout, never copied here)
  + config/profile.env             (this recipe's constants)
  + config/site.env                (the operator's site values)
  = one merged env file, used unchanged on both nodes

No env file is ever sourced by a shell: they are parsed with a strict line
parser, and values that could change the meaning of the rendered serve line
($, backtick, quotes, #, whitespace) are rejected rather than escaped.

Stdlib only, Python 3.8+.

    verify-source   pinned upstream commit, tracked+clean, exact file hashes
    merge           emit the merged env file (implies verify-source)
    delta           print merged-vs-upstream-example differences
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys
import tempfile

RECIPE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

UPSTREAM_REPO = "https://github.com/technigmaai/glm-5.3-flash-nvfp4-2x-dgx-sparks"
UPSTREAM_COMMIT = "74b42ffd9ef58ee80781db98c17aecfbdfccd6d5"

# The upstream project has no repository-wide (root) license and therefore no
# blanket grant; selected files there retain their own scoped licenses. This
# recipe distributes none of its files and binds them by commit and content.
UPSTREAM_SHA256 = {
    ".env.example":
        "3a95bd1b969244811ed2d353d7fe4f086123ee2bafe3359dd2f84a2fdec51e93",
    "compose.head.yaml":
        "56f93ce18c12319a6a0e355bf1abf62bec3732abac57367ffd1ab98e1479d64f",
    "compose.worker.yaml":
        "a8d4509445c733ea57e390f5ac13f8b97210bbe5ad4a44f68097dea8c5134b5a",
    "compose.display-kv.override.yaml":
        "f19390f05d3e4c23cd221a3ce65c5ecea338ef1a30191fbc86a737667b4efc67",
    "files/chat_template.jinja":
        "7a5a0dda1331a7c40d930961cc1cb3b57c3b52625250c13372fe006ba2e9dfdb",
}

# Files each role consumes; verification is scoped to these.
ROLE_FILES = {
    "head": [".env.example", "compose.head.yaml",
             "compose.display-kv.override.yaml", "files/chat_template.jinja"],
    "worker": [".env.example", "compose.worker.yaml",
               "compose.display-kv.override.yaml", "files/chat_template.jinja"],
}
ROLE_FILES["both"] = sorted(UPSTREAM_SHA256)

# Keys this recipe sets. Anything else in profile.env or site.env is rejected.
PROFILE_KEYS = (
    "IMAGE",
    "MODEL_PATH", "MODEL_REVISION", "SERVED_MODEL_NAME",
    "PORT",
    "KV_CACHE_MEMORY_BYTES", "MAX_NUM_SEQS", "MAX_NUM_BATCHED_TOKENS",
    "GLM53_SPLIT_TARGET_BLOCK_SIZE",
    "B12X_ROCE_SPIN_LIMIT",
    "WORKER_DIR", "WORKER_SSH_TARGET", "WORKER_ROCE_SSH_TARGET",
)
SITE_KEYS = (
    "HEAD_ROCE_IP", "WORKER_ROCE_IP", "MASTER_ADDR",
    "NCCL_IB_HCA", "NCCL_SOCKET_IFNAME", "CONTROL_IF",
    "HF_CACHE", "DRM_CARD_GID",
)
# The only key this recipe adds to the upstream key set.
ADDED_KEYS = ("B12X_ROCE_SPIN_LIMIT",)
# Upstream SSH-helper keys blanked on purpose; no compose file reads them.
DISCARDED_KEYS = ("WORKER_DIR", "WORKER_SSH_TARGET", "WORKER_ROCE_SSH_TARGET")
# Single-valued on purpose: see README, "Why a single HCA".
SINGLE_DEVICE_KEYS = ("NCCL_IB_HCA", "NCCL_SOCKET_IFNAME", "CONTROL_IF")
# Recipe-authored files whose *content* defines the profile. Key and syntax
# checks cannot catch a valid-looking edit to an image digest, a model revision
# or a capacity value, so these are also matched against their published
# SHA256SUMS entry. The expected hashes live only in that manifest.
PINNED_RECIPE_FILES = ("config/profile.env", "compose.phase1.override.yaml")

KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
PLACEHOLDER_RE = re.compile(r"<[A-Za-z0-9_][A-Za-z0-9_ .-]*>")
FORBIDDEN_VALUE_CHARS = "$`\"'\\#"


class Fail(Exception):
    pass


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_env(path, label):
    """Strict KEY=VALUE parser. Never executes anything."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except OSError as exc:
        raise Fail("%s: cannot read %s: %s" % (label, path, exc))
    values, order = {}, []
    for lineno, line in enumerate(raw.splitlines(), 1):
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        where = "%s:%d" % (label, lineno)
        if text.startswith("export "):
            raise Fail("%s: 'export' is not accepted in an env file" % where)
        match = KEY_RE.match(text)
        if not match:
            raise Fail("%s: not a KEY=VALUE line: %r" % (where, line))
        key, value = match.group(1), match.group(2)
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key in values:
            raise Fail("%s: duplicate key %s" % (where, key))
        for char in value:
            if not 0x20 <= ord(char) <= 0x7E:
                raise Fail("%s: %s has a control or non-ASCII character"
                           % (where, key))
        values[key] = value
        order.append(key)
    return values, order


def check_value(key, value, where):
    for char in value:
        if char in FORBIDDEN_VALUE_CHARS:
            raise Fail("%s: %s value contains %r; this recipe refuses values "
                       "that could change the rendered serve line"
                       % (where, key, char))
        if char.isspace():
            raise Fail("%s: %s value contains whitespace; the compose serve "
                       "line expands several of these unquoted" % (where, key))
    found = PLACEHOLDER_RE.search(value)
    if found:
        raise Fail("%s: %s still holds the placeholder %s - fill in a real "
                   "value from your own node" % (where, key, found.group(0)))


def verify_recipe_pins():
    """Match the profile and the overlay against their SHA256SUMS entries."""
    manifest = os.path.join(RECIPE, "SHA256SUMS")
    listed = {}
    try:
        with open(manifest, encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    digest, name = line.split(None, 1)
                    listed[name.strip().lstrip("*")] = digest
    except OSError as exc:
        raise Fail("cannot read %s: %s" % (manifest, exc))
    for rel in PINNED_RECIPE_FILES:
        want = listed.get(rel)
        if not want:
            raise Fail("SHA256SUMS does not list %s" % rel)
        got = sha256_file(os.path.join(RECIPE, rel))
        if got != want:
            raise Fail("%s does not match its SHA256SUMS entry (%s != %s). If "
                       "the edit was deliberate, regenerate SHA256SUMS."
                       % (rel, got, want))


def load_profile():
    """config/profile.env, with the recipe's content and key guards applied."""
    verify_recipe_pins()
    profile, _ = parse_env(os.path.join(RECIPE, "config/profile.env"),
                           "profile.env")
    if set(profile) != set(PROFILE_KEYS):
        raise Fail("profile.env key set mismatch: extra=%s missing=%s"
                   % (sorted(set(profile) - set(PROFILE_KEYS)),
                      sorted(set(PROFILE_KEYS) - set(profile))))
    for key in DISCARDED_KEYS:
        if profile[key] != "":
            raise Fail("profile.env: %s must stay blank; it is an upstream SSH "
                       "helper key and this recipe never uses SSH" % key)
    for key, value in sorted(profile.items()):
        check_value(key, value, "profile.env")
    return profile


def load_site(path):
    site, _ = parse_env(path, "site.env")
    unknown = sorted(set(site) - set(SITE_KEYS))
    if unknown:
        raise Fail("site.env sets keys this recipe does not accept: %s. "
                   "Profile constants belong in config/profile.env and may not "
                   "be overridden per site." % ", ".join(unknown))
    missing = sorted(set(SITE_KEYS) - set(site))
    if missing:
        raise Fail("site.env is missing: %s (copy config/site.env.example)"
                   % ", ".join(missing))
    for key, value in sorted(site.items()):
        check_value(key, value, "site.env")
    for key in SINGLE_DEVICE_KEYS:
        if "," in site[key]:
            raise Fail("site.env: %s=%r lists more than one device. This "
                       "recipe pins a single RoCE port: the GID probe in the "
                       "upstream compose command keeps the first RoCEv2 IPv4 "
                       "GID it finds and can bind the wrong twin."
                       % (key, site[key]))
    if site["MASTER_ADDR"] != site["HEAD_ROCE_IP"]:
        raise Fail("site.env: MASTER_ADDR (%s) must equal HEAD_ROCE_IP (%s); "
                   "rank 0 owns the rendezvous"
                   % (site["MASTER_ADDR"], site["HEAD_ROCE_IP"]))
    if site["HEAD_ROCE_IP"] == site["WORKER_ROCE_IP"]:
        raise Fail("site.env: HEAD_ROCE_IP and WORKER_ROCE_IP are the same "
                   "address; this is a two-node recipe")
    if not site["HF_CACHE"].startswith("/"):
        raise Fail("site.env: HF_CACHE=%r must be an absolute path"
                   % site["HF_CACHE"])
    if ":" in site["HF_CACHE"]:
        raise Fail("site.env: HF_CACHE=%r contains ':', which would split the "
                   "compose bind mount" % site["HF_CACHE"])
    return site


def git(upstream, *args):
    try:
        proc = subprocess.run(["git", "-C", upstream] + list(args),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        raise Fail("git is required to verify the upstream checkout: %s" % exc)
    return (proc.returncode,
            proc.stdout.decode("utf-8", "replace"),
            proc.stderr.decode("utf-8", "replace"))


def verify_source(upstream, role, verbose=True):
    def say(message):
        if verbose:
            print("  " + message)

    upstream = os.path.abspath(upstream)
    if not os.path.isdir(upstream):
        raise Fail("--upstream %s is not a directory. Clone it first:\n"
                   "    git clone %s && git -C <dir> checkout %s"
                   % (upstream, UPSTREAM_REPO, UPSTREAM_COMMIT))
    code, out, _ = git(upstream, "rev-parse", "--is-inside-work-tree")
    if code != 0 or out.strip() != "true":
        raise Fail("%s is not a git work tree; this recipe binds the upstream "
                   "source by commit, so a plain copy is not accepted" % upstream)
    code, out, err = git(upstream, "rev-parse", "--verify", "HEAD")
    if code != 0:
        raise Fail("cannot read HEAD of %s: %s" % (upstream, err.strip()))
    if out.strip() != UPSTREAM_COMMIT:
        raise Fail("upstream HEAD is %s but this recipe is pinned to %s.\n"
                   "    git -C %s fetch origin && git -C %s checkout %s"
                   % (out.strip(), UPSTREAM_COMMIT, upstream, upstream,
                      UPSTREAM_COMMIT))
    say("HEAD %s matches the pin" % UPSTREAM_COMMIT)

    files = ROLE_FILES[role]
    code, _, err = git(upstream, "ls-files", "--error-unmatch", "--", *files)
    if code != 0:
        raise Fail("not all required files are tracked at %s: %s"
                   % (UPSTREAM_COMMIT, err.strip()))
    code, out, err = git(upstream, "status", "--porcelain", "--", *files)
    if code != 0:
        raise Fail("git status failed in %s: %s" % (upstream, err.strip()))
    if out.strip():
        raise Fail("the upstream files this recipe uses are modified in the "
                   "work tree:\n%s" % out.rstrip())
    for rel in files:
        path = os.path.join(upstream, rel)
        if not os.path.isfile(path):
            raise Fail("missing upstream file %s" % rel)
        got = sha256_file(path)
        if got != UPSTREAM_SHA256[rel]:
            raise Fail("upstream %s sha256 %s != pinned %s"
                       % (rel, got, UPSTREAM_SHA256[rel]))
    say("%d used file(s) tracked, clean, and hash-exact" % len(files))
    return upstream, files


def build_merged(upstream, site_path):
    profile = load_profile()
    example, order = parse_env(os.path.join(upstream, ".env.example"),
                               "upstream .env.example")
    for key in PROFILE_KEYS:
        if key in ADDED_KEYS:
            if key in example:
                raise Fail("the pinned upstream .env.example now defines %s; "
                           "this recipe treats it as its own addition and will "
                           "not silently shadow upstream" % key)
        elif key not in example:
            raise Fail("the pinned upstream .env.example no longer defines %s; "
                       "refusing to invent an upstream key" % key)
    for key in SITE_KEYS:
        if key not in example:
            raise Fail("the pinned upstream .env.example no longer defines the "
                       "site key %s" % key)

    site = load_site(site_path)
    merged = dict(example)
    merged.update(profile)
    merged.update(site)

    overlay = set(PROFILE_KEYS) | set(SITE_KEYS)
    for key in sorted(merged):
        if key not in overlay and merged[key] != example.get(key):
            raise Fail("internal error: %s changed outside the overlay" % key)
    if set(merged) != set(example) | set(ADDED_KEYS):
        raise Fail("internal error: merged key set is not the upstream key set "
                   "plus %s" % ", ".join(ADDED_KEYS))
    out_order = list(order) + [k for k in ADDED_KEYS if k not in order]
    return merged, example, out_order


def render_merged(merged, order, site_path):
    header = [
        "# Generated by tools/envmerge.py - do not edit.",
        "# Regenerate from config/profile.env + config/site.env.",
        "# The same file is used on both nodes; only the compose file differs.",
        "# HF_HUB_OFFLINE / TRANSFORMERS_OFFLINE are inherited from the",
        "# upstream compose files, not set here.",
        "# upstream %s @ %s" % (UPSTREAM_REPO, UPSTREAM_COMMIT),
        "# profile  config/profile.env sha256 %s"
        % sha256_file(os.path.join(RECIPE, "config/profile.env")),
        "# site     %s sha256 %s" % (os.path.basename(site_path),
                                     sha256_file(site_path)),
    ]
    return "\n".join(header + ["%s=%s" % (k, merged[k]) for k in order]) + "\n"


def write_private(path, text):
    directory = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".envmerge.")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    os.chmod(path, 0o600)


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="envmerge.py", description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    sub.required = True

    p = sub.add_parser("verify-source", help="check the pinned upstream checkout")
    p.add_argument("--upstream", required=True)
    p.add_argument("--role", choices=sorted(ROLE_FILES), default="both")

    p = sub.add_parser("merge", help="emit the merged env file")
    p.add_argument("--upstream", required=True)
    p.add_argument("--site", required=True)
    p.add_argument("--role", choices=sorted(ROLE_FILES), default="both")
    p.add_argument("--out", help="write here, mode 0600 (default: stdout)")
    p.add_argument("--quiet", action="store_true")

    p = sub.add_parser("delta", help="merged vs upstream .env.example")
    p.add_argument("--upstream", required=True)
    p.add_argument("--site", required=True)

    args = ap.parse_args(argv)
    try:
        if args.cmd == "verify-source":
            print("== upstream source (%s) ==" % args.role)
            verify_source(args.upstream, args.role)
            return 0

        if args.cmd == "merge":
            upstream, _ = verify_source(args.upstream, args.role,
                                        verbose=not args.quiet)
            merged, _, order = build_merged(upstream, args.site)
            text = render_merged(merged, order, args.site)
            if args.out:
                write_private(args.out, text)
                if not args.quiet:
                    print("  wrote %s (%d keys, mode 0600)"
                          % (args.out, len(order)))
            else:
                sys.stdout.write(text)
            return 0

        if args.cmd == "delta":
            upstream, _ = verify_source(args.upstream, "both", verbose=False)
            merged, example, _ = build_merged(upstream, args.site)
            rows = [(k, example.get(k), merged.get(k),
                     "profile" if k in PROFILE_KEYS else "site")
                    for k in sorted(set(merged) | set(example))
                    if merged.get(k) != example.get(k)]
            print("# key\tupstream\tmerged\tlayer")
            for key, was, now, layer in rows:
                print("%s\t%s\t%s\t%s"
                      % (key, "(absent)" if was is None else was, now, layer))
            print("# %d differing entries (%d changed, %d added)"
                  % (len(rows), sum(1 for r in rows if r[1] is not None),
                     sum(1 for r in rows if r[1] is None)))
            return 0
    except Fail as exc:
        sys.stderr.write("ERROR: %s\n" % exc)
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
