# Tests

## Layout

- `test-*.bats`: bats tests, one file per shell script under test. The
  logic of each script lives in a sourceable library under `lib/`; the tests
  call those functions directly and run the script itself against scratch
  paths, with external commands (`ip`, `ifup`, `systemctl`, `iptables`,
  `ip6tables`, `turnkey-version`, `head`) replaced by stubs placed first in
  `PATH`. Nothing in a test touches the live system.
- `helpers.bash`: the stub helpers (`setup_stubs`, `stub`, `calls`).
- `coverage.sh`: runs the bats tests under kcov and fails when a measured
  file is below 95 percent of executed lines.
- `test_declarative*.py`: pytest tests of `libinithooks/declarative.py` and
  `bin/declarative.py`; `helpers.py` holds the helpers they share.
- `test-simplehttpd.sh`: manual launcher of the fence mini server.

## Running the shell tests

Dependencies: `bats` (1.11 in Trixie) and, for coverage, `kcov` (43).

    apt-get install -y bats kcov

Run the tests from the repository root:

    bats tests

Run one file, or one test by name:

    bats tests/test-ipconfig.bats
    bats --filter 'static' tests/test-ipconfig.bats

## Shell coverage

    tests/coverage.sh

The report is written to `coverage/` (pass another directory as the first
argument); `coverage/index.html` shows the executed lines per file and the
script prints a table per file and exits 1 when any file is below the
threshold (`COVERAGE_THRESHOLD`, default 95).

## Running the Python tests

The declarative reader (`libinithooks/declarative.py`) and its CLI
(`bin/declarative.py`) are project authored code and must keep at least
95 percent line and branch coverage, with every option, exit code and
error path exercised. The inherited hooks and helpers are not under the
threshold yet; their measured state is tracked in `COVERAGE.md`.

Run the suite from the top of the source tree. It needs Python 3 with
PyYAML, pytest and coverage, no network, no root and no installed
inithooks package. Both runners run the same tests:

    PYTHONPATH=. python3 -m pytest
    PYTHONPATH=. python3 -m unittest discover tests

Measure and check the coverage. The threshold, the branch setting and the
two measured files live in `pyproject.toml` (`[tool.coverage.run]` and
`[tool.coverage.report]`), so the third command exits non zero when either
file falls under the bar:

    PYTHONPATH=. python3 -m coverage run -m pytest
    python3 -m coverage report
    python3 -m coverage report --fail-under=95

The commands that inspect the running host (`turnkey-version` and `ip`)
and the inithooks log are replaced at the subprocess boundary in the
tests, so the suite gives the same answer on every host.

## On the build host

The tests need no root and no network, but bats and kcov are Debian
packages, so the reference run is on a TKLDev host. Copy the checkout to a
scratch directory there and run the script; `BUILD_HOST` is the host's
address, for example `2001:db8:1::10`:

    export TERM=dumb
    rsync -a --delete --exclude .git ./ "root@[$BUILD_HOST]:/root/inithooks-tests/inithooks/"
    ssh root@$BUILD_HOST 'export TERM=dumb; cd /root/inithooks-tests/inithooks && tests/coverage.sh' | cat

The percentages printed by `coverage.sh` are the numbers quoted in a pull
request.
