# Tests

The declarative reader (`libinithooks/declarative.py`) and its CLI
(`bin/declarative.py`) are project authored code and must keep at least
95 percent line and branch coverage, with every option, exit code and
error path exercised. The inherited hooks and helpers are not under the
threshold yet; their measured state is tracked separately.

Run the suite from the top of the source tree. It needs Python 3 with
PyYAML, pytest and coverage, no network, no root and no installed
inithooks package. Both runners run the same tests:

```
PYTHONPATH=. python3 -m pytest
PYTHONPATH=. python3 -m unittest discover tests
```

Measure and check the coverage. The threshold, the branch setting and the
two measured files live in `pyproject.toml` (`[tool.coverage.run]` and
`[tool.coverage.report]`), so the third command exits non zero when either
file falls under the bar:

```
PYTHONPATH=. python3 -m coverage run -m pytest
python3 -m coverage report
python3 -m coverage report --fail-under=95
```

The commands that inspect the running host (`turnkey-version` and `ip`)
and the inithooks log are replaced at the subprocess boundary in the
tests, so the suite gives the same answer on every host.

`test-simplehttpd.sh` is the shell test of `bin/simplehttpd.py` and is run
on its own.
