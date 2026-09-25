# Copyright (c) 2026 TurnKey GNU/Linux <admin@turnkeylinux.org>
"""Secrets are referenced, never inlined, and never leak into a render"""

import os
import tempfile
import unittest
from os.path import join
from unittest import mock

from helpers import declarative, doc, env, errors, secret_file


class TestSecretFiles(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def test_secret_file_without_trailing_newline_is_read_verbatim(self):
        path = secret_file(self.tmpdir, "s3cret")
        exported = env(
            f"version: 1\nsecrets:\n  db_password:\n    file: {path}\n"
        )
        self.assertEqual(exported["DB_PASS"], "s3cret")

    def test_secret_file_that_loosens_after_validation_is_refused(self):
        path = secret_file(self.tmpdir, "s3cret\n")
        document = doc(
            f"version: 1\nsecrets:\n  db_password:\n    file: {path}\n"
        )
        self.assertEqual(declarative.validate(document), [])
        os.chmod(path, 0o644)
        with self.assertRaises(declarative.DeclarativeError) as raised:
            declarative.resolve_secrets(document)
        self.assertIn("mode", str(raised.exception))

    @unittest.skipIf(os.geteuid() == 0, "root owns every file it creates")
    def test_secret_file_owned_by_another_user_is_rejected(self):
        path = secret_file(self.tmpdir, "s3cret\n")
        with mock.patch.object(
            declarative.os, "geteuid", return_value=os.geteuid() + 1
        ):
            found = errors(
                f"version: 1\nsecrets:\n  app_password:\n    file: {path}\n"
            )
        self.assertTrue(any("owned by root" in error for error in found))

    def test_hub_api_key_from_a_file_is_exported(self):
        path = secret_file(self.tmpdir, "ABCDEF123456\n", "apikey")
        text = f"version: 1\nhub:\n  api_key:\n    file: {path}\n"

        self.assertEqual(env(text)["HUB_APIKEY"], "ABCDEF123456")

    def test_hub_api_key_from_a_file_is_masked_for_display(self):
        path = secret_file(self.tmpdir, "ABCDEF123456\n", "apikey")
        document = doc(f"version: 1\nhub:\n  api_key:\n    file: {path}\n")

        rendered = declarative.mask(
            declarative.render_env(document, {"HUB_APIKEY": declarative.MASK})
        )

        self.assertIn(f"export HUB_APIKEY={declarative.MASK}\n", rendered)
        self.assertNotIn("ABCDEF123456", rendered)

    def test_generated_hub_api_key_is_not_empty(self):
        exported = env("version: 1\nhub:\n  api_key:\n    generate: true\n")
        self.assertGreater(len(exported["HUB_APIKEY"]), 8)


class TestMask(unittest.TestCase):
    def test_render_for_display_masks_the_secret(self):
        tmpdir = tempfile.mkdtemp()
        path = secret_file(tmpdir, "s3cret\n")
        document = doc(
            f"version: 1\nsecrets:\n  app_password:\n    file: {path}\n"
        )
        rendered = declarative.mask(
            declarative.render_env(document, {"APP_PASS": declarative.MASK})
        )
        self.assertIn("APP_PASS", rendered)
        self.assertNotIn("s3cret", rendered)

    def test_mask_leaves_the_skip_keyword_readable(self):
        rendered = declarative.mask(
            "export HUB_APIKEY=SKIP\nexport ROOT_PASS=x\n"
        )
        self.assertEqual(
            rendered,
            f"export HUB_APIKEY=SKIP\nexport ROOT_PASS={declarative.MASK}\n",
        )


class TestRenderKeywords(unittest.TestCase):
    def test_boolean_values_are_exported_as_the_hooks_keywords(self):
        exported = env(
            "version: 1\n"
            "app:\n  options:\n    debug: true\n"
            "preseed:\n  AUTOGROW: false\n"
        )
        self.assertEqual(exported["APP_DEBUG"], "TRUE")
        self.assertEqual(exported["AUTOGROW"], "FALSE")

    def test_security_updates_keyword_is_kept_when_not_skip_or_force(self):
        # render_env does not validate; other values pass through unchanged
        rendered = declarative.render_env(
            doc("version: 1\nsecurity:\n  updates: weekly\n"), {}
        )
        self.assertEqual(rendered, "export SEC_UPDATES=weekly\n")


class TestConf(unittest.TestCase):
    def test_write_conf_tightens_the_mode_of_an_existing_file(self):
        conf = join(tempfile.mkdtemp(), "inithooks.conf")
        with open(conf, "w") as fob:
            fob.write("stale\n")
        os.chmod(conf, 0o644)

        declarative.write_conf("export HOSTNAME=blog\n", conf)

        self.assertEqual(os.stat(conf).st_mode & 0o777, 0o600)
        with open(conf) as fob:
            self.assertEqual(fob.read(), "export HOSTNAME=blog\n")


if __name__ == "__main__":
    unittest.main()
