#!/usr/bin/python3
"""Tests for libinithooks.declarative

Run from the top of the source tree with:

    python3 -m unittest discover tests

They need no network, no root and no installed inithooks package.
"""

import os
import subprocess
import sys
import tempfile
import unittest
from os.path import dirname, abspath, join

sys.path.insert(0, dirname(dirname(abspath(__file__))))

from libinithooks import declarative  # noqa: E402


def doc(text: str) -> dict:
    """Load a YAML document from a string through declarative.load()"""
    with tempfile.NamedTemporaryFile(
        "w", suffix=".yaml", delete=False
    ) as fob:
        fob.write(text)
        path = fob.name
    try:
        return declarative.load(path)
    finally:
        os.remove(path)


def env(text: str) -> dict:
    """Render a YAML document to a dict of exported variables"""
    document = doc(text)
    errors = declarative.validate(document)
    if errors:
        raise AssertionError(f"unexpected errors: {errors}")
    secrets = declarative.resolve_secrets(document)
    rendered = declarative.render_env(document, secrets)
    exported = {}
    for line in rendered.splitlines():
        if not line.startswith("export "):
            continue
        key, _, value = line[len("export "):].partition("=")
        exported[key] = value
    return exported


def errors(text: str) -> list[str]:
    return declarative.validate(doc(text))


class TestLoad(unittest.TestCase):
    def test_loads_minimal_document(self):
        # Arrange / Act
        exported = env("version: 1\n")

        # Assert
        self.assertEqual(exported, {})

    def test_rejects_malformed_yaml(self):
        with self.assertRaises(declarative.DeclarativeError):
            doc("version: 1\ninstance: [unclosed\n")

    def test_rejects_document_that_is_not_a_mapping(self):
        with self.assertRaises(declarative.DeclarativeError):
            doc("- one\n- two\n")

    def test_rejects_missing_or_wrong_version(self):
        self.assertTrue(errors("instance:\n  hostname: blog\n"))
        self.assertTrue(errors("version: 2\n"))

    def test_rejects_unknown_top_level_key(self):
        found = errors("version: 1\nnonsense: true\n")
        self.assertTrue(any("nonsense" in error for error in found))


class TestMapping(unittest.TestCase):
    def test_maps_instance_and_app_keys_to_env_names(self):
        exported = env(
            "version: 1\n"
            "instance:\n"
            "  hostname: blog\n"
            "  fqdn: blog.example.org\n"
            "app:\n"
            "  email: admin@example.org\n"
            "  domain: blog.example.org\n"
        )
        self.assertEqual(exported["HOSTNAME"], "blog")
        self.assertEqual(exported["FQDN"], "blog.example.org")
        self.assertEqual(exported["APP_EMAIL"], "admin@example.org")
        self.assertEqual(exported["APP_DOMAIN"], "blog.example.org")

    def test_app_options_are_upper_cased_with_app_prefix(self):
        exported = env(
            "version: 1\n"
            "app:\n"
            "  options:\n"
            "    ip_bind: '[::1]'\n"
            "    realm: example\n"
        )
        self.assertEqual(exported["APP_IP_BIND"], "'[::1]'")
        self.assertEqual(exported["APP_REALM"], "example")

    def test_preseed_keys_pass_through_verbatim(self):
        exported = env("version: 1\npreseed:\n  AUTOGROW: ONCE\n")
        self.assertEqual(exported["AUTOGROW"], "ONCE")

    def test_hub_and_security_values_are_upper_cased(self):
        exported = env(
            "version: 1\n"
            "hub:\n"
            "  api_key: skip\n"
            "security:\n"
            "  alerts: skip\n"
            "  updates: force\n"
        )
        self.assertEqual(exported["HUB_APIKEY"], "SKIP")
        self.assertEqual(exported["SEC_ALERTS"], "SKIP")
        self.assertEqual(exported["SEC_UPDATES"], "FORCE")

    def test_security_alerts_email_is_kept_as_is(self):
        exported = env("version: 1\nsecurity:\n  alerts: A@example.org\n")
        self.assertEqual(exported["SEC_ALERTS"], "A@example.org")

    def test_rejects_security_alerts_that_is_not_an_email(self):
        self.assertTrue(errors("version: 1\nsecurity:\n  alerts: nope\n"))

    def test_first_login_wizard_true_exports_auto_run(self):
        exported = env("version: 1\nfirst_login_wizard: true\n")
        self.assertEqual(exported["AUTO_RUN"], "TRUE")

    def test_first_login_wizard_false_does_not_export_auto_run(self):
        exported = env("version: 1\nfirst_login_wizard: false\n")
        self.assertNotIn("AUTO_RUN", exported)


class TestSecrets(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def secret_file(self, content: str, mode: int = 0o600) -> str:
        path = join(self.tmpdir, "secret")
        with open(path, "w") as fob:
            fob.write(content)
        os.chmod(path, mode)
        return path

    def test_secret_file_is_read_and_trailing_newline_stripped(self):
        path = self.secret_file("s3cret\n")
        exported = env(
            "version: 1\n"
            "secrets:\n"
            "  app_password:\n"
            f"    file: {path}\n"
        )
        self.assertEqual(exported["APP_PASS"], "s3cret")

    def test_secret_file_with_loose_mode_is_rejected(self):
        path = self.secret_file("s3cret\n", 0o644)
        found = errors(
            "version: 1\n"
            "secrets:\n"
            "  app_password:\n"
            f"    file: {path}\n"
        )
        self.assertTrue(any("mode" in error for error in found))

    def test_missing_secret_file_is_rejected(self):
        found = errors(
            "version: 1\n"
            "secrets:\n"
            "  app_password:\n"
            f"    file: {join(self.tmpdir, 'absent')}\n"
        )
        self.assertTrue(found)

    def test_secret_with_two_backends_is_rejected(self):
        path = self.secret_file("s3cret\n")
        found = errors(
            "version: 1\n"
            "secrets:\n"
            "  db_password:\n"
            f"    file: {path}\n"
            "    generate: true\n"
        )
        self.assertTrue(found)

    def test_generate_is_refused_for_app_password_without_wizard(self):
        found = errors(
            "version: 1\nsecrets:\n  app_password:\n    generate: true\n"
        )
        self.assertTrue(any("generate" in error for error in found))

    def test_generate_is_allowed_for_app_password_with_wizard(self):
        text = (
            "version: 1\n"
            "first_login_wizard: true\n"
            "secrets:\n"
            "  app_password:\n"
            "    generate: true\n"
        )
        self.assertEqual(errors(text), [])

    def test_generated_db_password_is_not_empty(self):
        exported = env(
            "version: 1\nsecrets:\n  db_password:\n    generate: true\n"
        )
        self.assertTrue(len(exported["DB_PASS"]) > 8)

    def test_values_are_shell_quoted(self):
        password = "a b$c\"d'e"
        path = self.secret_file(password + "\n")
        document = doc(
            "version: 1\n"
            "secrets:\n"
            "  app_password:\n"
            f"    file: {path}\n"
        )
        self.assertEqual(declarative.validate(document), [])
        secrets = declarative.resolve_secrets(document)
        rendered = declarative.render_env(document, secrets)

        conf = join(self.tmpdir, "inithooks.conf")
        declarative.write_conf(rendered, conf)
        out = subprocess.run(
            ["bash", "-c", f'source {conf}; printf %s "$APP_PASS"'],
            capture_output=True,
        )
        self.assertEqual(out.stdout.decode(), password)


class TestNetwork(unittest.TestCase):
    def test_rejects_ipv6_address_without_prefix_length(self):
        found = errors(
            "version: 1\n"
            "network:\n"
            "  interfaces:\n"
            "    eth0:\n"
            "      ipv6:\n"
            "        method: static\n"
            "        address: 2001:db8:1::10\n"
        )
        self.assertTrue(found)

    def test_accepts_link_local_gateway(self):
        text = (
            "version: 1\n"
            "network:\n"
            "  managed_by: host\n"
            "  interfaces:\n"
            "    eth0:\n"
            "      ipv6:\n"
            "        method: static\n"
            "        address: 2001:db8:1::10/64\n"
            "        gateway: fe80::1\n"
        )
        self.assertEqual(errors(text), [])

    def test_host_managed_network_exports_no_ip_variables(self):
        exported = env(
            "version: 1\n"
            "network:\n"
            "  managed_by: host\n"
            "  interfaces:\n"
            "    eth0:\n"
            "      ipv6:\n"
            "        method: static\n"
            "        address: 2001:db8:1::10/64\n"
        )
        self.assertEqual(exported, {})

    def test_file_managed_ipv4_static_maps_to_ip_variables(self):
        exported = env(
            "version: 1\n"
            "network:\n"
            "  managed_by: file\n"
            "  interfaces:\n"
            "    eth0:\n"
            "      ipv4:\n"
            "        method: static\n"
            "        address: 192.0.2.10/24\n"
            "        gateway: 192.0.2.1\n"
            "  nameservers:\n"
            "    - 192.0.2.53\n"
            "    - 192.0.2.54\n"
        )
        self.assertEqual(exported["IP_CONFIG"], "static")
        self.assertEqual(exported["IP_ADDRESS"], "192.0.2.10")
        self.assertEqual(exported["IP_NETMASK"], "255.255.255.0")
        self.assertEqual(exported["IP_GW"], "192.0.2.1")
        self.assertEqual(exported["IP_DNS1"], "192.0.2.53")
        self.assertEqual(exported["IP_DNS2"], "192.0.2.54")

    def test_file_managed_static_ipv6_is_refused_in_this_version(self):
        found = errors(
            "version: 1\n"
            "network:\n"
            "  managed_by: file\n"
            "  interfaces:\n"
            "    eth0:\n"
            "      ipv6:\n"
            "        method: static\n"
            "        address: 2001:db8:1::10/64\n"
        )
        self.assertTrue(found)

    def test_rejects_unknown_managed_by(self):
        self.assertTrue(errors("version: 1\nnetwork:\n  managed_by: magic\n"))


class TestDomains(unittest.TestCase):
    def test_rejects_domain_with_path(self):
        found = errors("version: 1\napp:\n  domain: example.org/blog\n")
        self.assertTrue(found)

    def test_rejects_fqdn_with_port(self):
        found = errors("version: 1\ninstance:\n  fqdn: example.org:8080\n")
        self.assertTrue(found)


class TestConf(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def test_write_conf_is_only_readable_by_root(self):
        path = join(self.tmpdir, "inithooks.conf")
        declarative.write_conf("export ROOT_PASS=secret\n", path)
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_existing_non_empty_conf_wins(self):
        decl = join(self.tmpdir, "inithooks.yaml")
        conf = join(self.tmpdir, "inithooks.conf")
        with open(decl, "w") as fob:
            fob.write("version: 1\ninstance:\n  hostname: blog\n")
        with open(conf, "w") as fob:
            fob.write("export ROOT_PASS=preseeded\n")

        hook = join(
            dirname(dirname(abspath(__file__))), "firstboot.d", "00declarative"
        )
        environment = dict(os.environ)
        environment["INITHOOKS_DEFAULT"] = self.write_default(decl, conf)
        environment["PYTHONPATH"] = dirname(dirname(abspath(__file__)))
        out = subprocess.run([hook], capture_output=True, env=environment)

        self.assertEqual(out.returncode, 0)
        with open(conf) as fob:
            self.assertEqual(fob.read(), "export ROOT_PASS=preseeded\n")

    def write_default(self, decl: str, conf: str) -> str:
        path = join(self.tmpdir, "default-inithooks")
        source = dirname(dirname(abspath(__file__)))
        with open(path, "w") as fob:
            fob.write(
                f"INITHOOKS_CONF={conf}\n"
                f"INITHOOKS_DECL={decl}\n"
                f"INITHOOKS_PATH={source}\n"
            )
        return path


if __name__ == "__main__":
    unittest.main()
