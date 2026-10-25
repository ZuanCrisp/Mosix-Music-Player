"""Check SDK integrity, bounded extraction and encrypted CI preparation."""

import hashlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import prepare_discord_sdk as sdk


class PrepareDiscordSdkTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.output = self.root / "prepared"
        self.archive = self.root / "sdk.zip"
        self.contents = {
            "lib/release/discord_partner_sdk.aar": b"test Android library",
            f"{sdk.XCFRAMEWORK}/ios-arm64/discord_partner_sdk.framework/discord_partner_sdk":
                b"test iOS device library",
            f"{sdk.XCFRAMEWORK}/ios-arm64-simulator/discord_partner_sdk.framework/discord_partner_sdk":
                b"test iOS simulator library",
            "License-Notices.txt": b"test license notices",
            "include/discordpp.h": b"test C++ header",
        }
        checksums = {name: hashlib.sha256(data).hexdigest()
                     for name, data in self.contents.items()}
        patch = mock.patch.object(sdk, "FILES", checksums)
        patch.start()
        self.addCleanup(patch.stop)

    def make_archive(self, prefix="", contents=None):
        with zipfile.ZipFile(self.archive, "w") as zf:
            for name, data in (self.contents if contents is None else contents).items():
                zf.writestr(prefix + name, data)
            zf.writestr("../../outside.txt", b"must not be extracted")
            zf.writestr("lib/release/desktop.dll", b"unused")

    def assert_prepared(self):
        files = {str(path.relative_to(self.output)): path.read_bytes()
                 for path in self.output.rglob("*") if path.is_file()}
        self.assertEqual(files, self.contents)

    def test_root_and_prefixed_archives_extract_only_mobile_files(self):
        for prefix in ("", "discord_social_sdk/"):
            with self.subTest(prefix=prefix):
                self.make_archive(prefix)
                sdk.prepare(self.output, archive=self.archive)
                self.assert_prepared()
                self.assertFalse((self.root / "outside.txt").exists())

    def test_source_directory_and_verified_cache(self):
        source = self.root / "download"
        for name, data in self.contents.items():
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        sdk.prepare(self.output, source_dir=source)
        shutil.rmtree(source)
        self.assertEqual(sdk.prepare(self.output), self.output)
        self.assert_prepared()

    def test_corrupt_cache_is_rejected(self):
        self.make_archive()
        sdk.prepare(self.output, archive=self.archive)
        (self.output / "License-Notices.txt").write_bytes(b"tampered")
        with self.assertRaisesRegex(sdk.SdkError, "checksum mismatch"):
            sdk.prepare(self.output)

    def test_bad_archive_does_not_replace_verified_sdk(self):
        self.make_archive()
        sdk.prepare(self.output, archive=self.archive)
        contents = self.contents.copy()
        contents["include/discordpp.h"] = b"wrong SDK version"
        self.make_archive(contents=contents)
        with self.assertRaisesRegex(sdk.SdkError, "checksum mismatch"):
            sdk.prepare(self.output, archive=self.archive)
        self.assert_prepared()

    def test_each_missing_mobile_component_is_rejected(self):
        for name in self.contents:
            with self.subTest(name=name):
                self.make_archive(contents={key: value for key, value in self.contents.items()
                                            if key != name})
                with self.assertRaisesRegex(sdk.SdkError, "exactly one"):
                    sdk.prepare(self.output, archive=self.archive)
                self.assertFalse(self.output.exists())

    def test_duplicate_file_is_rejected(self):
        self.make_archive()
        with zipfile.ZipFile(self.archive, "a") as zf:
            zf.writestr("other/License-Notices.txt", b"duplicate")
        with self.assertRaisesRegex(sdk.SdkError, "exactly one"):
            sdk.prepare(self.output, archive=self.archive)

    def test_oversized_file_is_rejected_before_writing_output(self):
        self.make_archive()
        with mock.patch.object(sdk, "MAX_FILE_BYTES", 1):
            with self.assertRaisesRegex(sdk.SdkError, "size limit"):
                sdk.prepare(self.output, archive=self.archive)
        self.assertFalse(self.output.exists())

    def test_missing_configuration_names_the_required_secret(self):
        with self.assertRaisesRegex(sdk.SdkError, "DISCORD_MOBILE_SDK_PASSPHRASE"):
            sdk.prepare(self.output)

    def test_decryption_failure_does_not_echo_key(self):
        key = "private-test-passphrase"
        with mock.patch.object(sdk.subprocess, "run", return_value=mock.Mock(returncode=2)):
            with self.assertRaises(sdk.SdkError) as error:
                sdk.prepare(self.output, passphrase=key)
        self.assertNotIn(key, str(error.exception))
        self.assertFalse(self.output.exists())

    def test_missing_gpg_is_actionable(self):
        with mock.patch.object(sdk.subprocess, "run", side_effect=FileNotFoundError):
            with self.assertRaisesRegex(sdk.SdkError, "Install GnuPG"):
                sdk.prepare(self.output, passphrase="test")

    @unittest.skipUnless(shutil.which("gpg"), "GnuPG is required for encrypted archive test")
    def test_encrypted_archive_roundtrip_and_wrong_key(self):
        self.make_archive()
        encrypted = self.root / "sdk.zip.gpg"
        key = "test-fixture-passphrase"
        gnupg_home = self.root / "gnupg"
        gnupg_home.mkdir(mode=0o700)
        with mock.patch.dict(sdk.os.environ, {"GNUPGHOME": str(gnupg_home)}):
            subprocess.run(
                ["gpg", "--batch", "--quiet", "--pinentry-mode", "loopback",
                 "--passphrase-fd", "0", "--cipher-algo", "AES256", "--symmetric",
                 "--output", str(encrypted), str(self.archive)],
                input=key.encode(), check=True, capture_output=True,
            )
            with mock.patch.object(sdk, "ENCRYPTED_ARCHIVE", encrypted):
                with self.assertRaisesRegex(sdk.SdkError, "decryption failed"):
                    sdk.prepare(self.output, passphrase="incorrect")
                sdk.prepare(self.output, passphrase=key)
        self.assert_prepared()


if __name__ == "__main__":
    unittest.main()
