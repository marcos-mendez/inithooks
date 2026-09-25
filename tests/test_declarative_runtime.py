# Copyright (c) 2026 TurnKey GNU/Linux <admin@turnkeylinux.org>
"""What the running machine says, with the host commands stood in for

The two commands the reader runs (turnkey-version and ip) are replaced at
the subprocess boundary, so the tests pass on any host and cover both the
found and the not found answer of each one.
"""

import os
import subprocess
import unittest
from unittest import mock

from helpers import declarative, doc

IP_OUTPUT = (
    "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP\n"
    "    inet6 2001:db8:1::10/64 scope global\n"
    "       valid_lft forever preferred_lft forever\n"
    "    inet6 2001:db8:1::11/64 scope global dynamic\n"
    "       valid_lft 86400sec preferred_lft 14400sec\n"
)

HOST_MANAGED = (
    "version: 1\n"
    "network:\n"
    "  managed_by: host\n"
    "  interfaces:\n"
    "    eth0:\n"
    "      ipv6:\n"
    "        method: static\n"
    "        address: 2001:db8:1::10/64\n"
)


def completed(stdout: str, returncode: int = 0) -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(
        args=[], returncode=returncode, stdout=stdout, stderr=""
    )


def marker_present(present: bool):
    """os.path.exists that answers for the LXC marker and nothing else"""
    real_exists = os.path.exists

    def exists(path):
        if path == declarative.LXC_MARKER:
            return present
        return real_exists(path)

    return mock.patch.object(declarative.os.path, "exists", side_effect=exists)


class TestDefaultManagedBy(unittest.TestCase):
    def test_lxc_marker_means_the_host_owns_the_network(self):
        with (
            marker_present(True),
            mock.patch.object(declarative.subprocess, "run") as run,
        ):
            self.assertEqual(declarative.default_managed_by(), "host")
        run.assert_not_called()

    def test_turnkey_version_reporting_lxc_means_host(self):
        with (
            marker_present(False),
            mock.patch.object(
                declarative.subprocess, "run", return_value=completed("lxc\n")
            ),
        ):
            self.assertEqual(declarative.default_managed_by(), "host")

    def test_any_other_build_type_means_file(self):
        with (
            marker_present(False),
            mock.patch.object(
                declarative.subprocess, "run", return_value=completed("kvm\n")
            ),
        ):
            self.assertEqual(declarative.default_managed_by(), "file")

    def test_missing_turnkey_version_means_file(self):
        with (
            marker_present(False),
            mock.patch.object(
                declarative.subprocess, "run", side_effect=FileNotFoundError
            ),
        ):
            self.assertEqual(declarative.default_managed_by(), "file")

    def test_declared_managed_by_wins_over_the_default(self):
        with mock.patch.object(declarative, "default_managed_by") as default:
            found = declarative._managed_by({"managed_by": "file"})
        self.assertEqual(found, "file")
        default.assert_not_called()

    def test_default_is_used_when_nothing_is_declared(self):
        with marker_present(True):
            self.assertEqual(declarative._managed_by({}), "host")


class TestLiveIPv6(unittest.TestCase):
    def test_global_addresses_are_listed_without_prefix_length(self):
        with mock.patch.object(
            declarative.subprocess, "run", return_value=completed(IP_OUTPUT)
        ) as run:
            found = declarative._live_ipv6("eth0")
        self.assertEqual(found, ["2001:db8:1::10", "2001:db8:1::11"])
        command = run.call_args.args[0]
        self.assertEqual(command[:5], ["ip", "-6", "addr", "show", "eth0"])

    def test_unknown_interface_has_no_addresses(self):
        with mock.patch.object(
            declarative.subprocess,
            "run",
            return_value=completed("", returncode=1),
        ):
            self.assertEqual(declarative._live_ipv6("eth9"), [])

    def test_missing_ip_command_means_no_addresses(self):
        with mock.patch.object(
            declarative.subprocess, "run", side_effect=FileNotFoundError
        ):
            self.assertEqual(declarative._live_ipv6("eth0"), [])


class TestCheckNetwork(unittest.TestCase):
    def check(self, text: str, live: list[str]) -> list[str]:
        with mock.patch.object(declarative, "_live_ipv6", return_value=live):
            return declarative.check_network(doc(text))

    def test_declared_address_that_is_live_is_silent(self):
        self.assertEqual(self.check(HOST_MANAGED, ["2001:db8:1::10"]), [])

    def test_address_that_is_not_live_is_reported_with_the_live_ones(self):
        found = self.check(HOST_MANAGED, ["2001:db8:2::1"])
        self.assertEqual(len(found), 1)
        self.assertIn("network.interfaces.eth0", found[0])
        self.assertIn("2001:db8:1::10/64", found[0])
        self.assertIn("found: 2001:db8:2::1", found[0])

    def test_interface_without_any_live_address_says_none(self):
        found = self.check(HOST_MANAGED, [])
        self.assertIn("found: none", found[0])

    def test_file_managed_network_is_not_compared(self):
        text = HOST_MANAGED.replace("managed_by: host", "managed_by: file")
        with mock.patch.object(declarative, "_live_ipv6") as live:
            self.assertEqual(declarative.check_network(doc(text)), [])
        live.assert_not_called()

    def test_interfaces_without_a_declared_address_are_skipped(self):
        text = (
            "version: 1\n"
            "network:\n"
            "  managed_by: host\n"
            "  interfaces:\n"
            "    eth0:\n"
            "    eth1:\n"
            "      ipv6:\n"
            "        method: auto\n"
        )
        with mock.patch.object(declarative, "_live_ipv6") as live:
            self.assertEqual(declarative.check_network(doc(text)), [])
        live.assert_not_called()

    def test_description_without_a_network_section_is_not_compared(self):
        with marker_present(True):
            self.assertEqual(
                declarative.check_network(doc("version: 1\n")), []
            )


class TestUnsupported(unittest.TestCase):
    def test_acme_enabled_is_reported_as_not_acted_on(self):
        found = declarative.unsupported(
            doc("version: 1\ntls:\n  acme:\n    enabled: true\n")
        )
        self.assertEqual(len(found), 1)
        self.assertIn("tls.acme", found[0])

    def test_acme_disabled_is_silent(self):
        found = declarative.unsupported(
            doc("version: 1\ntls:\n  acme:\n    enabled: false\n")
        )
        self.assertEqual(found, [])


if __name__ == "__main__":
    unittest.main()
