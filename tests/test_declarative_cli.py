# Copyright (c) 2026 TurnKey GNU/Linux <admin@turnkeylinux.org>
"""bin/declarative.py: every option, every exit code

The script is loaded as a module and driven in process through its main()
so that coverage sees it; the inithooks log is replaced by a recorder and
the SIGINT handler is not touched.
"""

import contextlib
import importlib.util
import io
import os
import runpy
import signal
import sys
import tempfile
import unittest
from os.path import abspath, dirname, join
from unittest import mock

from helpers import declarative, secret_file

ROOT = dirname(dirname(abspath(__file__)))
SCRIPT = join(ROOT, "bin", "declarative.py")

VALID = (
    "version: 1\n"
    "instance:\n"
    "  hostname: blog\n"
    "  fqdn: blog.example.org\n"
    "network:\n"
    "  managed_by: host\n"
    "  interfaces:\n"
    "    eth0:\n"
    "      ipv6:\n"
    "        method: static\n"
    "        address: 2001:db8:1::10/64\n"
    "        gateway: fe80::1\n"
)


def load_script():
    spec = importlib.util.spec_from_file_location("declarative_cli", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cli = load_script()


class Log:
    """Stand-in for InitLog that records instead of writing"""

    def __init__(self, fail: bool = False):
        self.entries: list[tuple[str, str]] = []
        self.fail = fail

    def write(self, msg: str, level: str = "info") -> None:
        if self.fail:
            raise OSError("log file is not writable")
        self.entries.append((level, msg))

    def levels(self) -> set[str]:
        return {level for level, _ in self.entries}


class CLITestCase(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.conf = join(self.tmpdir, "inithooks.conf")
        self.log = Log()

    def write_decl(self, text: str, name: str = "inithooks.yaml") -> str:
        path = join(self.tmpdir, name)
        with open(path, "w") as fob:
            fob.write(text)
        return path

    def run_cli(self, *argv: str, live=None) -> tuple[int, str, str]:
        """Run main() in process and return (exit code, stdout, stderr)"""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(cli, "LOG", self.log))
            stack.enter_context(mock.patch.object(signal, "signal"))
            stack.enter_context(
                mock.patch.object(sys, "argv", ["declarative.py", *argv])
            )
            stack.enter_context(
                mock.patch.object(
                    declarative, "_live_ipv6", return_value=live or []
                )
            )
            stack.enter_context(contextlib.redirect_stdout(out))
            stack.enter_context(contextlib.redirect_stderr(err))
            try:
                cli.main()
            except SystemExit as raised:
                code = int(raised.code or 0)
            else:
                code = 0
        return code, out.getvalue(), err.getvalue()


class TestCheck(CLITestCase):
    def test_valid_file_prints_ok_and_exits_0(self):
        path = self.write_decl(VALID)
        code, out, err = self.run_cli("--check", path)
        self.assertEqual((code, out, err), (0, f"{path}: ok\n", ""))

    def test_short_option_is_accepted(self):
        path = self.write_decl(VALID)
        self.assertEqual(self.run_cli("-c", path)[0], 0)

    def test_absent_file_is_a_no_op_that_exits_0(self):
        path = join(self.tmpdir, "absent.yaml")
        for option in ("--check", "--render", "--apply"):
            with self.subTest(option=option):
                code, out, _ = self.run_cli(
                    option, path, f"--conf={self.conf}"
                )
                self.assertEqual((code, out), (0, ""))
        self.assertFalse(os.path.exists(self.conf))
        self.assertIn("not found, nothing to do", self.log.entries[0][1])
        self.assertEqual(self.log.levels(), {"debug"})

    def test_malformed_yaml_exits_1_and_is_logged(self):
        path = self.write_decl("version: 1\ninstance: [unclosed\n")
        code, _, err = self.run_cli("--check", path)
        self.assertEqual(code, 1)
        self.assertIn(f"Error: {path}: not valid YAML", err)
        self.assertEqual(self.log.levels(), {"err"})

    def test_unreadable_path_exits_1(self):
        code, _, err = self.run_cli("--check", self.tmpdir)
        self.assertEqual(code, 1)
        self.assertIn("Error:", err)

    def test_every_validation_error_is_printed_with_the_path(self):
        path = self.write_decl("version: 2\nnonsense: true\n")
        code, _, err = self.run_cli("--check", path)
        self.assertEqual(code, 1)
        self.assertIn(f"Error: {path}: version: must be 1\n", err)
        self.assertIn(f"Error: {path}: nonsense: unknown top level key\n", err)
        self.assertEqual(len(self.log.entries), 2)

    def test_log_that_cannot_be_written_falls_back_to_stderr(self):
        self.log = Log(fail=True)
        path = self.write_decl("version: 2\n")
        code, _, err = self.run_cli("--check", path)
        self.assertEqual(code, 1)
        self.assertIn(f"err: {path}: version: must be 1\n", err)
        self.assertIn(f"Error: {path}: version: must be 1\n", err)


class TestRender(CLITestCase):
    def test_render_prints_the_conf_with_secrets_masked(self):
        secret = secret_file(self.tmpdir, "s3cret\n")
        apikey = secret_file(self.tmpdir, "ABCDEF123456\n", "apikey")
        path = self.write_decl(
            VALID
            + f"secrets:\n  root_password:\n    file: {secret}\n"
            + f"hub:\n  api_key:\n    file: {apikey}\n"
        )

        code, out, _ = self.run_cli("--render", path)

        self.assertEqual(code, 0)
        self.assertIn("export HOSTNAME=blog\n", out)
        self.assertIn(f"export ROOT_PASS={declarative.MASK}\n", out)
        self.assertIn(f"export HUB_APIKEY={declarative.MASK}\n", out)
        self.assertNotIn("s3cret", out)
        self.assertNotIn("ABCDEF123456", out)
        self.assertFalse(os.path.exists(self.conf))

    def test_render_of_a_file_without_secrets_prints_it_verbatim(self):
        path = self.write_decl("version: 1\nhub:\n  api_key: skip\n")
        code, out, _ = self.run_cli("-r", path)
        self.assertEqual((code, out), (0, "export HUB_APIKEY=SKIP\n"))


class TestApply(CLITestCase):
    def test_apply_writes_the_conf_0600_and_logs_it(self):
        path = self.write_decl(VALID)
        code, _, err = self.run_cli(
            "--apply", f"--conf={self.conf}", path, live=["2001:db8:1::10"]
        )
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(os.stat(self.conf).st_mode & 0o777, 0o600)
        with open(self.conf) as fob:
            self.assertIn("export HOSTNAME=blog\n", fob.read())
        self.assertEqual(
            self.log.entries, [("info", f"{path} applied to {self.conf}")]
        )

    def test_paths_default_to_the_environment(self):
        path = self.write_decl(VALID)
        environment = {"INITHOOKS_DECL": path, "INITHOOKS_CONF": self.conf}
        with mock.patch.dict(os.environ, environment):
            code = self.run_cli("-a", live=["2001:db8:1::10"])[0]
        self.assertEqual(code, 0)
        self.assertTrue(os.path.exists(self.conf))

    def test_missing_secret_file_exits_1_before_writing(self):
        path = self.write_decl(
            "version: 1\n"
            "secrets:\n"
            "  db_password:\n"
            f"    file: {join(self.tmpdir, 'absent')}\n"
        )
        code, _, err = self.run_cli("--apply", f"--conf={self.conf}", path)
        self.assertEqual(code, 1)
        self.assertIn("secret file not found", err)
        self.assertFalse(os.path.exists(self.conf))

    def test_secret_that_disappears_after_validation_exits_1(self):
        path = self.write_decl(VALID)
        with mock.patch.object(
            declarative,
            "resolve_secrets",
            side_effect=declarative.DeclarativeError("gone: not found"),
        ):
            code, _, err = self.run_cli("--apply", f"--conf={self.conf}", path)
        self.assertEqual(code, 1)
        self.assertEqual(err, "Error: gone: not found\n")
        self.assertFalse(os.path.exists(self.conf))

    def test_unwritable_conf_raises_instead_of_pretending(self):
        path = self.write_decl(VALID)
        conf = join(self.tmpdir, "absent-directory", "inithooks.conf")
        with self.assertRaises(FileNotFoundError):
            self.run_cli("--apply", f"--conf={conf}", path)

    def test_warnings_are_logged_as_errors_but_do_not_fail_the_run(self):
        path = self.write_decl(VALID + "tls:\n  acme:\n    enabled: true\n")
        code, _, err = self.run_cli("--apply", f"--conf={self.conf}", path)
        self.assertEqual((code, err), (0, ""))
        self.assertTrue(os.path.exists(self.conf))
        logged = [msg for level, msg in self.log.entries if level == "err"]
        self.assertEqual(len(logged), 2)
        self.assertIn("network.interfaces.eth0", logged[0])
        self.assertIn("found: none", logged[0])
        self.assertIn("tls.acme", logged[1])


class TestUsage(CLITestCase):
    def assert_usage(self, *argv: str, message: str = "") -> None:
        code, out, err = self.run_cli(*argv)
        self.assertEqual((code, out), (1, ""))
        self.assertIn("Syntax: declarative.py [options] [file]", err)
        self.assertIn("--check", err)
        if message:
            self.assertIn(f"Error: {message}", err)
        else:
            self.assertNotIn("Error:", err)

    def test_unknown_option(self):
        self.assert_usage("--nonsense", message="option --nonsense")

    def test_more_than_one_file(self):
        self.assert_usage("--check", "one.yaml", "two.yaml")

    def test_help(self):
        self.assert_usage("--help")
        self.assert_usage("-h")

    def test_no_action(self):
        self.assert_usage(
            "inithooks.yaml",
            message="one of --check, --render or --apply is required",
        )


class TestEntryPoint(CLITestCase):
    def test_running_the_script_hands_the_exit_code_to_the_shell(self):
        path = join(self.tmpdir, "absent.yaml")
        with (
            mock.patch.object(cli.InitLog, "write", autospec=True),
            mock.patch.object(signal, "signal"),
            mock.patch.object(sys, "argv", ["declarative.py", "-c", path]),
            self.assertRaises(SystemExit) as raised,
        ):
            runpy.run_path(SCRIPT, run_name="__main__")
        self.assertEqual(raised.exception.code, 0)


if __name__ == "__main__":
    unittest.main()
