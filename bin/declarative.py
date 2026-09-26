#!/usr/bin/python3
# Copyright (c) 2026 TurnKey GNU/Linux <admin@turnkeylinux.org>
"""Translate a declarative instance description into inithooks.conf

Arguments:
    file            declarative file to read; defaults to $INITHOOKS_DECL
                    or /etc/inithooks.yaml

Options:
    -c --check      validate the file and exit
    -r --render     print the rendered conf with the secrets masked
    -a --apply      write the rendered conf
    --conf=         conf file to write; defaults to $INITHOOKS_CONF
                    or /etc/inithooks.conf

Exits 0 when the file does not exist, so that an image without a
declarative description behaves exactly as it does today.
"""

import getopt
import os
import signal
import sys
from typing import NoReturn

from libinithooks import declarative
from libinithooks.inithooks_log import InitLog

LOG = InitLog("00declarative")


def log(msg: str, level: str = "info") -> None:
    try:
        LOG.write(msg, level)
    except OSError:
        print(f"{level}: {msg}", file=sys.stderr)


def fatal(msg: str) -> NoReturn:
    log(str(msg), "err")
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


def usage(msg: str | getopt.GetoptError = "") -> NoReturn:
    if msg:
        print(f"Error: {msg}", file=sys.stderr)
    print(f"Syntax: {sys.argv[0]} [options] [file]", file=sys.stderr)
    print(__doc__, file=sys.stderr)
    sys.exit(1)


def read(path: str) -> dict:
    try:
        doc = declarative.load(path)
    except declarative.DeclarativeError as e:
        fatal(e)

    errors = declarative.validate(doc)
    if errors:
        for error in errors:
            log(f"{path}: {error}", "err")
            print(f"Error: {path}: {error}", file=sys.stderr)
        sys.exit(1)
    return doc


def apply(doc: dict, path: str, conf: str) -> None:
    try:
        secrets = declarative.resolve_secrets(doc)
    except declarative.DeclarativeError as e:
        fatal(e)

    declarative.write_conf(declarative.render_env(doc, secrets), conf)
    log(f"{path} applied to {conf}")

    for msg in declarative.check_network(doc) + declarative.unsupported(doc):
        log(msg, "err")


def main():
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        l_opts = ["help", "check", "render", "apply", "conf="]
        opts, args = getopt.gnu_getopt(sys.argv[1:], "hcra", l_opts)
    except getopt.GetoptError as e:
        usage(e)

    if len(args) > 1:
        usage()

    action = ""
    conf = os.environ.get("INITHOOKS_CONF", declarative.CONF_DEFAULT)
    for opt, val in opts:
        if opt in ("-h", "--help"):
            usage()
        elif opt in ("-c", "--check"):
            action = "check"
        elif opt in ("-r", "--render"):
            action = "render"
        elif opt in ("-a", "--apply"):
            action = "apply"
        elif opt == "--conf":
            conf = val

    if not action:
        usage("one of --check, --render or --apply is required")

    path = args[0] if args else os.environ.get(
        "INITHOOKS_DECL", declarative.DECL_DEFAULT
    )
    if not os.path.exists(path):
        log(f"{path} not found, nothing to do", "debug")
        sys.exit(0)

    doc = read(path)
    if action == "check":
        print(f"{path}: ok")
    elif action == "render":
        declared = doc.get("secrets") or {}
        secrets = {
            var: declarative.MASK
            for name, var in declarative.SECRET_VARS.items()
            if name in declared
        }
        if isinstance((doc.get("hub") or {}).get("api_key"), dict):
            secrets["HUB_APIKEY"] = declarative.MASK
        print(declarative.mask(declarative.render_env(doc, secrets)), end="")
    else:
        apply(doc, path, conf)


if __name__ == "__main__":
    main()
