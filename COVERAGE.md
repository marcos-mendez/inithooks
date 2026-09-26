# Test coverage baseline

Measured on 2026-09-24 against upstream master (33c43b8), following the
project decision 0003 (90 percent floor per repository, 95 percent for every
file our changes touch).

## Measured baseline on master: shell 98 percent, Python 99 percent (2026-09-26)

Pull requests #1 to #4 merged on 2026-09-26 (merge commits 4e09d1e, a20a94a,
8f77b85, e1334073). `tests/coverage.sh` under kcov 43 measures 68 bats over
six files: 01ipconfig 23/23, lib/ipconfig.sh 25/25, 29tagid 19/19,
lib/tagid.sh 8/8, turnkey-init-fence 28/28, lib/init-fence.sh 63/64 (98.44,
the lowest file; total 99.40). The shell gate is set to 98, the lowest file
rounded down. `coverage run --branch --source=libinithooks,bin -m pytest`
measures 146 tests: libinithooks/declarative.py 100 percent,
bin/declarative.py 99 percent, total 99; the Python gate is 95, the bar for
project-authored code, with the inherited modules without tests omitted in
`pyproject.toml` until their tests land. Both thresholds are only ever
raised. The sections that follow record the state before the merges.

## Baseline before the merges: 0 percent measured on upstream master

Upstream has one file under `tests/`, `test-simplehttpd.sh` (4 lines). It
starts `bin/simplehttpd.py` on the loopback ports and prints the URL; it
asserts nothing and is a manual smoke launcher, not a test. No coverage tool
is wired up. Line counts are lines neither blank nor comment.

Inventory command (shebang or extension decides the kind):

    find . -type f -not -path './.git/*' -not -path './debian/*' \
      | while read f; do h=$(head -1 "$f"); case "$f$h" in *.py*|*python*) k=py;; \
      *sh*) k=sh;; *) continue;; esac; echo "$k $(grep -cvE '^\s*(#|$)' "$f") $f"; done

| Group | Files | Lines | Measured |
|-------|-------|-------|----------|
| firstboot.d/* (17 hooks) | 17 | 366 | 0 percent, no test |
| run, turnkey-init, turnkey-sudoadmin, turnkey-install-security-updates | 4 | 399 | 0 percent, no test |
| bin/*.py (hubservices 162, simplehttpd 339, secalerts 75, secupdates-ask 52, setpass 54, reboot-ask 30) | 6 | 712 | 0 percent, no test |
| bin/* shell (turnkey-init-fence 139, secalerts.sh 66, restart-getty 59, login_script.sh 2) | 4 | 266 | 0 percent, no test |
| libinithooks/*.py (dialog_wrapper 354, inithooks_cache 61, __init__ 33, inithooks_log 30) | 4 | 478 | 0 percent, no test |
| setup.py, tests/test-simplehttpd.sh | 2 | 13 | packaging and launcher, excluded |

Total: 25 shell files (970 lines) and 12 Python files (1268 lines), 0
percent measured.

## Measured on our branch feat/declarative-instance

Command, on the branch checkout:

    PYTHONPATH=. coverage run --branch --source=libinithooks,bin \
      -m pytest -q tests/test_declarative.py && coverage report -m

31 tests pass. Line plus branch coverage as reported:

| File | Stmts | Branches | Cover |
|------|-------|----------|-------|
| libinithooks/declarative.py | 438 | 222 | 72 percent (110 statements missed, 38 partial branches) |
| bin/declarative.py | 84 | 34 | 0 percent (CLI wrapper, never imported by the tests) |
| firstboot.d/00declarative | shell, 14 lines | | 0 percent, no test |
| all other files under libinithooks and bin | | | 0 percent |

Total over `libinithooks` and `bin` on that branch: 26 percent.

## Our branches and the 95 percent bar

| Branch | File touched | Automated test |
|--------|--------------|----------------|
| fix/01ipconfig-static | firstboot.d/01ipconfig (47 lines) | None. Append static options, keep the confconsole header and the IPv6 stanza: verified by hand on a VM. 0 percent. |
| fix/29tagid-inactive-fence | firstboot.d/29tagid (18 lines) | None. Reload turnkey-init-fence only when active: verified by hand on a VM. 0 percent. |
| fix/fence-without-nat | bin/turnkey-init-fence (139 lines) | None. Skip REDIRECT when the nat table is unavailable: verified by hand on a VM. 0 percent. |
| feat/declarative-instance | libinithooks/declarative.py | 31 tests, 72 percent. Below the 95 percent bar. |
| feat/declarative-instance | bin/declarative.py | None, 0 percent. |
| feat/declarative-instance | firstboot.d/00declarative | None, 0 percent. |
| feat/declarative-instance | README.rst, debian/control, default/inithooks, release notes | Documentation and packaging, not code. |

## Plan to reach 90 percent per file

Method: Python with `coverage run --branch` and `pytest`, `fail_under`
committed in `pyproject.toml`. Shell with test files under `tests/` that
run each hook against a scratch root, `INITHOOKS_CONF` and
`INITHOOKS_DEFAULT` pointed at fixtures, `PATH` holding stub commands
(`ip`, `ifup`, `iptables`, `systemctl`, `turnkey-version`, `openssl`) that
record their arguments; coverage from `bash -x` traces (kcov when the
decision 0003 open item settles). Every exit code and `fatal` path gets a
test. Addresses in fixtures are IPv6, for example `2001:db8:1::10/64` with
gateway `2001:db8:1::1`.

Priority order (size: small under 30 lines of test, medium under 150,
large above):

1. `libinithooks/declarative.py` from 72 to 95 percent (medium). The
   missed regions are lines 174 to 257 (`mask`, `default_managed_by`,
   `check_network`, `unsupported`, `_live_ipv6`: the functions that read
   the live system, to be tested with a stubbed `ip` command) and lines
   583 to 638 (`_address_errors`, `_gateway_errors`, `_validate_tls`: one
   test per error message), plus 38 partial branches in the validators.
2. `bin/declarative.py` (small): run `main()` in-process with `--apply`,
   `--conf`, a missing file and a malformed file; assert output and exit
   codes.
3. `firstboot.d/00declarative` (small): `_TURNKEY_INIT` set, description
   absent, non-empty `INITHOOKS_CONF` warning, happy path calling the stub.
4. `firstboot.d/01ipconfig` (small to medium): static and dhcp cases, lxc
   short circuit, unchanged interfaces file exits 0, header and IPv6 stanza
   preserved when rewriting, `fatal` on a bad `IP_CONFIG`.
5. `firstboot.d/29tagid` (small): htdocs missing, tag already present,
   fence active and inactive (stub `systemctl is-active`).
6. `bin/turnkey-init-fence` (medium): each `case` verb, `iptables` stubs
   returning failure for `-t nat` to cover the skip, `start_mini_server`
   failure exit 1, `stop_mini_server` with and without a pid file.
7. First-boot driver: `run` (medium: `wait_for_boot`, `exec_scripts` order,
   reboot request, output redirection), `turnkey-init` (small, Python).
8. Remaining `firstboot.d` hooks (small each): 95secupdates 56,
   05autogrow-fs 53, 15regen-sslcert 39, 10randomize-crontab 31,
   09hostname 23, 97turnkey-init-fence-disable 20, 10regen-sshkeys 18,
   30turnkey-init-fence 18, 99reboot 14, and the one to seven line hooks.
9. `libinithooks`: inithooks_cache.py 61 and inithooks_log.py 30 (small),
   `__init__.py` 33 (small), dialog_wrapper.py 354 (large: mock the
   `dialog` binary, one test per dialog type and per cancel path).
10. `bin` Python: hubservices.py 162 (medium, mock HTTP), setpass.py 54,
    secupdates-ask.py 52, reboot-ask.py 30 (small), secalerts.py 75 and
    secalerts.sh 66 (small), restart-getty 59 (small), simplehttpd.py 339
    (large: start on `[::1]` ephemeral ports, request each route).
11. `turnkey-sudoadmin` 219 (large, shell: a test per subcommand).
