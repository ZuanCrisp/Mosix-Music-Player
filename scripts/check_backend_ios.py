#!/usr/bin/env python3
"""Audit an iOS application bundle for the selected native backend."""

import argparse
import hashlib
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set, Tuple


MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
VALID_ARCHES = {"arm64", "x86_64"}
PLATFORM_NAMES = {"ios": "IOS", "ios-simulator": "IOSSIMULATOR"}
GO_SECTIONS = ("__gopclntab", "__go_buildinfo")
GO_SYMBOLS = ("_GobackendSetAppVersion", "_crosscall2")
RUST_SYMBOL = "_uniffi_mornye_mobile_"


class AuditError(Exception):
    pass


def parse_archs(raw: str) -> Tuple[str, ...]:
    archs = tuple(part.strip() for part in raw.split(","))
    if not archs or any(not arch for arch in archs):
        raise AuditError("--archs must be a comma-separated list")
    if len(set(archs)) != len(archs):
        raise AuditError("--archs contains a duplicate architecture")
    unknown = sorted(set(archs) - VALID_ARCHES)
    if unknown:
        raise AuditError("unsupported architecture(s): " + ", ".join(unknown))
    return archs


def run_xcrun(*args: str) -> str:
    try:
        completed = subprocess.run(
            ["xcrun", *args],
            capture_output=True,
            check=False,
            errors="replace",
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise AuditError("xcrun " + " ".join(args) + " failed: " + str(exc)) from exc
    if completed.returncode:
        detail = " ".join(completed.stderr.split())[:240]
        raise AuditError(
            "xcrun " + " ".join(args) + " failed" + (": " + detail if detail else "")
        )
    return completed.stdout


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_main_executable(app: Path) -> Path:
    plist_path = app / "Info.plist"
    if not plist_path.is_file():
        raise AuditError("missing Info.plist")
    try:
        with plist_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, ValueError) as exc:
        raise AuditError("invalid Info.plist: " + str(exc)) from exc
    name = info.get("CFBundleExecutable") if isinstance(info, dict) else None
    if not isinstance(name, str) or not name or name in (".", "..") or any(
        char in name for char in ("\x00", "/", "\\")
    ):
        raise AuditError("CFBundleExecutable must be a simple filename")
    executable = app / name
    if executable.is_symlink() or not executable.is_file():
        raise AuditError("missing main executable: " + name)
    return executable


def check_main_arches(executable: Path, expected: Sequence[str], platform: str) -> None:
    actual = tuple(run_xcrun("lipo", "-archs", str(executable)).split())
    if set(actual) != set(expected) or len(actual) != len(expected):
        raise AuditError("main executable architectures are " + ",".join(actual)
                         + "; expected " + ",".join(expected))

    output = run_xcrun("vtool", "-show-build", str(executable))
    architecture = re.compile(r"\(architecture\s+([^)]*)\):")
    platform_line = re.compile(r"^\s*platform\s+(\S+)")
    observed: Dict[str, Set[str]] = {}
    current = None
    for line in output.splitlines():
        match = architecture.search(line)
        if match:
            current = match.group(1).strip()
        match = platform_line.match(line)
        if match:
            if current is None and len(expected) == 1:
                current = expected[0]
            if current in expected:
                observed.setdefault(current, set()).add(match.group(1))
    wanted = PLATFORM_NAMES[platform]
    for arch in expected:
        values = observed.get(arch, set())
        if values != {wanted}:
            found = ",".join(sorted(values)) or "missing"
            raise AuditError(
                f"{arch} main slice platform is {found}; expected {wanted}"
            )


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as stream:
            return stream.read(4) in MACHO_MAGICS
    except OSError as exc:
        raise AuditError("cannot read bundle file " + str(path)) from exc


def defined_symbol(nm_output: str, marker: str) -> bool:
    for line in nm_output.splitlines():
        fields = line.split()
        if (len(fields) == 3 and re.fullmatch(r"[0-9a-fA-F]+", fields[0])
                and marker in fields[2] and fields[1] not in {"U", "u"}):
            return True
    return False


def macho_uuids(path: Path) -> Dict[str, str]:
    output = run_xcrun("dwarfdump", "--uuid", str(path))
    matches = re.findall(r"UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)", output)
    uuids = {arch: uuid.upper() for uuid, arch in matches}
    if not uuids or len(uuids) != len(matches):
        raise AuditError("missing or duplicate Mach-O UUIDs: " + str(path))
    return uuids


def read_dsym_symbols(executable: Path, dsym: Path) -> str:
    dwarf = dsym / "Contents" / "Resources" / "DWARF" / executable.name
    if dwarf.is_symlink() or not dwarf.is_file() or not is_macho(dwarf):
        raise AuditError("missing Mach-O dSYM for main executable: " + str(dwarf))
    if macho_uuids(executable) != macho_uuids(dwarf):
        raise AuditError("dSYM UUIDs/architectures do not match the main executable")
    return run_xcrun("nm", "-gU", str(dwarf))


def audit(app: Path, backend: str, archs: Sequence[str], platform: str, release: bool,
          dsym: Optional[Path] = None) -> str:
    if not app.is_dir():
        raise AuditError(".app is not a directory: " + str(app))
    executable = read_main_executable(app)
    if not is_macho(executable):
        raise AuditError("main executable is not a Mach-O file")
    check_main_arches(executable, archs, platform)
    digest = sha256(executable)
    try:
        paths = sorted(app.rglob("*"), key=lambda path: path.as_posix())
    except OSError as exc:
        raise AuditError("cannot enumerate app bundle: " + str(exc)) from exc

    macho: List[Tuple[str, str, str]] = []
    rust_framework_path = False
    for path in paths:
        relative = path.relative_to(app)
        parts = relative.parts
        if "Gobackend.framework" in parts and backend == "rust":
            raise AuditError("Rust app contains Gobackend.framework: " + relative.as_posix())
        rust_framework_path |= any(
            part == "MornyeBackend" or part.startswith("MornyeBackend.")
            or part == "MornyeBackendFFI" or part.startswith("MornyeBackendFFI.")
            for part in parts
        )
        if release and path.name in {"kernel_blob.bin", "Runner.debug.dylib"}:
            raise AuditError("release app contains forbidden " + path.name)
        if path.is_symlink() or not path.is_file() or not is_macho(path):
            continue
        otool = run_xcrun("otool", "-l", str(path))
        nm = run_xcrun("nm", "-gU", str(path))
        macho.append((relative.as_posix(), otool, nm))

    # Archive strips static Rust symbols from Runner after generating its dSYM.
    # Only accept symbol evidence from the exact same executable (all UUIDs and
    # architectures must match); continue scanning the shipped bundle for Go.
    if dsym is not None:
        macho.append(("main executable dSYM", "", read_dsym_symbols(executable, dsym)))

    go_section = any(section in otool for _, otool, _ in macho for section in GO_SECTIONS)
    go_symbol = any(
        defined_symbol(nm, symbol) for _, _, nm in macho for symbol in GO_SYMBOLS
    )
    rust_symbol = any(RUST_SYMBOL in nm for _, _, nm in macho)
    rust_defined_symbol = any(defined_symbol(nm, RUST_SYMBOL) for _, _, nm in macho)
    if backend == "rust":
        if not rust_defined_symbol:
            raise AuditError("Rust app has no defined " + RUST_SYMBOL + " symbol")
        if go_section or go_symbol:
            raise AuditError("Rust app contains Go sections or defined Go symbols")
    else:
        if rust_symbol or rust_framework_path:
            raise AuditError("Go app contains Rust symbols or framework paths")
        if not (go_section or go_symbol):
            raise AuditError("Go app has no Go section or defined symbol evidence")
    return digest


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help=".app directory to audit")
    parser.add_argument("--backend", choices=("rust", "go"), required=True)
    parser.add_argument("--archs", required=True, metavar="ARCH[,ARCH...]")
    parser.add_argument("--platform", choices=tuple(PLATFORM_NAMES), required=True)
    parser.add_argument("--release", action="store_true", help="apply release artifact checks")
    parser.add_argument("--dsym", type=Path,
                        help="matching main executable .dSYM for a stripped archive")
    return parser


def main(argv: Sequence[str] = None) -> int:
    args = make_parser().parse_args(argv)
    try:
        archs = parse_archs(args.archs)
        digest = audit(args.app, args.backend, archs, args.platform, args.release, args.dsym)
    except (AuditError, OSError) as exc:
        print("error: " + str(exc), file=sys.stderr)
        return 1
    print(f"OK sha256={digest} backend={args.backend} archs={','.join(archs)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
