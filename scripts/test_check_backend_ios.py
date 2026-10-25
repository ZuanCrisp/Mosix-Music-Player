"""Regression coverage for backend evidence in stripped iOS archives."""

import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import check_backend_ios as checker


class BackendArchiveAuditTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self.app = root / "Runner.app"
        self.app.mkdir()
        with (self.app / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "Runner"}, stream)
        self.binary = self.app / "Runner"
        self.binary.write_bytes(b"\xcf\xfa\xed\xfe" + b"fixture")
        self.dsym = root / "Runner.app.dSYM"
        self.dwarf = self.dsym / "Contents/Resources/DWARF/Runner"
        self.dwarf.parent.mkdir(parents=True)
        self.dwarf.write_bytes(b"\xcf\xfa\xed\xfe" + b"symbols")
        self.binary_symbols = ""
        self.dsym_symbols = "0000000100010000 T _uniffi_spotiflac_mobile_fn_func_probe\n"
        self.dsym_uuid = "12345678-1234-1234-1234-123456789ABC"
        self.dsym_arch = "arm64"
        self.sections = ""
        mock = patch.object(checker, "run_xcrun", side_effect=self.xcrun)
        mock.start()
        self.addCleanup(mock.stop)

    def xcrun(self, tool, *args):
        if tool == "lipo":
            return "arm64\n"
        if tool == "vtool":
            return "    platform IOS\n"
        if tool == "otool":
            return self.sections
        if tool == "nm":
            return self.dsym_symbols if Path(args[-1]) == self.dwarf else self.binary_symbols
        if tool == "dwarfdump":
            if Path(args[-1]) == self.dwarf:
                return f"UUID: {self.dsym_uuid} ({self.dsym_arch}) {self.dwarf}\n"
            return f"UUID: 12345678-1234-1234-1234-123456789ABC (arm64) {self.binary}\n"
        self.fail("Unexpected xcrun tool: " + tool)

    def audit(self, dsym=None):
        return checker.audit(self.app, "rust", ("arm64",), "ios", True, dsym)

    def test_unstripped_binary_needs_no_dsym(self):
        self.binary_symbols = self.dsym_symbols
        self.assertEqual(self.audit(), checker.sha256(self.binary))

    def test_stripped_binary_requires_symbol_evidence(self):
        with self.assertRaisesRegex(checker.AuditError, "no defined"):
            self.audit()

    def test_matching_dsym_verifies_stripped_binary(self):
        self.assertEqual(self.audit(self.dsym), checker.sha256(self.binary))

    def test_dsym_from_another_build_is_rejected(self):
        self.dsym_uuid = "ABCDEF01-1234-1234-1234-123456789ABC"
        with self.assertRaisesRegex(checker.AuditError, "do not match"):
            self.audit(self.dsym)

    def test_dsym_from_another_architecture_is_rejected(self):
        self.dsym_arch = "x86_64"
        with self.assertRaisesRegex(checker.AuditError, "do not match"):
            self.audit(self.dsym)

    def test_missing_dsym_is_rejected(self):
        self.dwarf.unlink()
        with self.assertRaisesRegex(checker.AuditError, "missing Mach-O dSYM"):
            self.audit(self.dsym)

    def test_matching_dsym_without_defined_rust_is_rejected(self):
        self.dsym_symbols = "                 U _uniffi_spotiflac_mobile_fn_func_probe\n"
        with self.assertRaisesRegex(checker.AuditError, "no defined"):
            self.audit(self.dsym)

    def test_matching_dsym_does_not_hide_go_in_shipped_binary(self):
        self.sections = "sectname __gopclntab\n"
        with self.assertRaisesRegex(checker.AuditError, "contains Go"):
            self.audit(self.dsym)

    def test_matching_dsym_with_go_symbols_is_rejected(self):
        self.dsym_symbols += "0000000100020000 T _crosscall2\n"
        with self.assertRaisesRegex(checker.AuditError, "contains Go"):
            self.audit(self.dsym)

    def test_debug_artifacts_remain_forbidden_with_dsym(self):
        (self.app / "kernel_blob.bin").write_bytes(b"fixture")
        with self.assertRaisesRegex(checker.AuditError, "forbidden kernel_blob.bin"):
            self.audit(self.dsym)


if __name__ == "__main__":
    unittest.main()
