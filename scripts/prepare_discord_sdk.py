#!/usr/bin/env python3
"""Verify and prepare the pinned official Discord mobile SDK for CI."""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Optional


VERSION = "1.10.19337"
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = PROJECT_ROOT / ".dart_tool" / "discord-social-sdk" / VERSION
ENCRYPTED_ARCHIVE = PROJECT_ROOT / "third_party" / "discord" / f"discord-mobile-{VERSION}.zip.gpg"
XCFRAMEWORK = "lib/release/discord_partner_sdk.xcframework"
FILES = {
    "License-Notices.txt":
        "e8afa66340c225431e69768543cc34a7240f3494a9d759189fe118620ea8eebf",
    "include/discordpp.h":
        "822e71509bf11b7155becca5fb00d215a7db7b305f357c0f3b5f6e27ff45b6ab",
    "lib/release/discord_partner_sdk.aar":
        "b1b2491f1e1848c79fd6f1986d5aa1e0c8019e88a6e62c7be06b89e8e4870933",
    f"{XCFRAMEWORK}/Info.plist":
        "bb227b40a5adb4e4a02447b46a91b7a0fe28c9d238fbb80e19b7215c7ae3f431",
}
for slice_name, plist, binary in (
    ("ios-arm64",
     "41bc76fed4b9d3adb7d711e5b44848b87f775598ed24173abfd1f4a6a0656a90",
     "8d86063b1a6c5c562b822378d34f55d335b37358e20f3425d446cc335ffae8bd"),
    ("ios-arm64-simulator",
     "a3e162d5587897f9435e7897dbcde4d5b32c6dd445a0c8ff897157f5f340e4a1",
     "eddc98dcb0e5614d64bef4c17476e5bb1ad53b3a7e8d6d8fc550b3abfc067f98"),
):
    framework = f"{XCFRAMEWORK}/{slice_name}/discord_partner_sdk.framework"
    FILES.update({
        f"{framework}/Info.plist": plist,
        f"{framework}/discord_partner_sdk": binary,
        f"{framework}/Headers/cdiscord.h":
            "86ef9280ab8432493952bb974bd18c5a25d7725011393b5dba05162bcfdb3371",
        f"{framework}/Headers/discord_partner_sdk.h":
            "b049099dab197146011b3ceecc823ec25fdbbda7a37ea1584be8e472501a390b",
        f"{framework}/Headers/discordpp.h": FILES["include/discordpp.h"],
        f"{framework}/Modules/module.modulemap":
            "48879037011d015ad2c9802fdc478862785ba073e7f96dfdf6c0865b6075a542",
    })
MAX_FILE_BYTES = 64 * 1024 * 1024


class SdkError(Exception):
    pass


def verify(directory: Path) -> None:
    for relative, expected in FILES.items():
        path = directory / relative
        if not path.is_file() or path.is_symlink():
            raise SdkError("Missing or invalid Discord SDK file: " + relative)
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != expected:
            raise SdkError(f"Discord SDK {VERSION} checksum mismatch: {relative}")


def unpack(archive: Path, destination: Path) -> None:
    with zipfile.ZipFile(archive) as zf:
        for relative in FILES:
            matches = [info for info in zf.infolist() if not info.is_dir() and
                       (info.filename == relative or info.filename.endswith("/" + relative))]
            if len(matches) != 1:
                raise SdkError("SDK archive must contain exactly one " + relative)
            if matches[0].file_size > MAX_FILE_BYTES:
                raise SdkError("SDK archive entry exceeds size limit: " + relative)
            path = destination / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            # Write only pinned destinations, never paths supplied by the ZIP.
            with zf.open(matches[0]) as source, path.open("wb") as target:
                shutil.copyfileobj(source, target)
            if relative.endswith(".framework/discord_partner_sdk"):
                path.chmod(0o755)


def prepare(output: Path, source_dir: Optional[Path] = None,
            archive: Optional[Path] = None, passphrase: Optional[str] = None) -> Path:
    output = output.expanduser().resolve()
    if source_dir is None and archive is None and output.is_dir():
        verify(output)
        return output
    if source_dir is None and archive is None and not passphrase:
        raise SdkError(
            f"Discord SDK {VERSION} is required. Supply --source-dir, --archive, "
            "or the Actions secret DISCORD_MOBILE_SDK_PASSPHRASE."
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="discord-sdk-", dir=output.parent) as temporary:
        staging = Path(temporary) / "sdk"
        if source_dir is not None:
            source_dir = source_dir.expanduser().resolve()
            verify(source_dir)
            for relative in FILES:
                target = staging / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source_dir / relative, target)
        else:
            if archive is None:
                archive = Path(temporary) / "sdk.zip"
                try:
                    result = subprocess.run(
                        ["gpg", "--batch", "--quiet", "--no-symkey-cache",
                         "--pinentry-mode", "loopback",
                         "--passphrase-fd", "0", "--output", str(archive),
                         "--decrypt", str(ENCRYPTED_ARCHIVE)],
                        input=passphrase.encode(), stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, check=False,
                    )
                except FileNotFoundError as exc:
                    raise SdkError("Install GnuPG to decrypt the Discord SDK") from exc
                if result.returncode != 0:
                    raise SdkError("SDK decryption failed; check DISCORD_MOBILE_SDK_PASSPHRASE")
            unpack(archive, staging)
        verify(staging)
        for relative in FILES:
            target = output / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            (staging / relative).replace(target)
    verify(output)
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--source-dir", type=Path)
    parser.add_argument("--archive", type=Path, help="official SDK ZIP for offline setup")
    args = parser.parse_args()
    try:
        output = prepare(args.output, args.source_dir, args.archive,
                         os.environ.get("DISCORD_MOBILE_SDK_PASSPHRASE"))
    except (SdkError, OSError, zipfile.BadZipFile) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    # stdout contains only the verified directory, suitable for setup_discord_sdk.sh.
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
