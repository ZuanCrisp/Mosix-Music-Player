"""Loopback-only Samba fixture; never changes the system's Samba configuration.

Requires Samba 4 (Homebrew: brew install samba). The isolated test account is
test / secret and maps to the current OS user. Run with --help for dialects.
"""

import argparse
import os
from pathlib import Path
import pwd
import shutil
import subprocess
from tempfile import TemporaryDirectory
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=1445)
    parser.add_argument("--dialect", choices=["SMB2_02", "SMB2_10", "SMB3_00", "SMB3_02", "SMB3_11"], default="SMB3_11")
    parser.add_argument("--encryption", choices=["required", "off"], default="required")
    parser.add_argument("--guest", action="store_true")
    parser.add_argument("--writable", action="store_true", help="Allow uploads to the disposable fixture share")
    args = parser.parse_args()
    executable = shutil.which("samba-dot-org-smbd") or shutil.which("smbd")
    if not executable:
        parser.error("Samba smbd is required")
    if not 1024 <= args.port <= 65535:
        parser.error("Use an unprivileged TCP port")
    if args.guest and args.encryption != "off":
        parser.error("Guest sessions cannot require encryption; use --encryption off")
    username = pwd.getpwuid(os.getuid()).pw_name
    with TemporaryDirectory(prefix="spotiflac-samba-") as directory:
        root = Path(directory)
        for name in ["private", "lock", "state", "cache", "run", "music"]:
            (root / name).mkdir()
        (root / "music" / "A B.wav").write_bytes(bytes(range(256)))
        (root / "music" / "Uploads" / "Album").mkdir(parents=True)
        (root / "users.map").write_text(f"{username} = test\n")
        # NT hash of the public fixture password "secret". No OS password used.
        (root / "private" / "smbpasswd").write_text(
            f"{username}:{os.getuid()}:XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX:"
            f"878D8014606CDA29677A44EFA1353FC7:[U          ]:LCT-{int(time.time()):08X}:\n"
        )
        config = root / "smb.conf"
        config.write_text(f"""[global]
server role = standalone server
workgroup = WORKGROUP
netbios name = SMBTEST
interfaces = 127.0.0.1
bind interfaces only = yes
smb ports = {args.port}
server min protocol = {args.dialect}
server max protocol = {args.dialect}
server signing = {'auto' if args.guest else 'mandatory'}
server smb encrypt = {args.encryption}
private dir = {root}/private
lock directory = {root}/lock
state directory = {root}/state
cache directory = {root}/cache
pid directory = {root}/run
log file = {root}/log.%m
passdb backend = smbpasswd:{root}/private/smbpasswd
username map = {root}/users.map
guest account = {username}
map to guest = {'Bad User' if args.guest else 'Never'}
load printers = no
disable spoolss = yes
[MUSIC]
path = {root}/music
read only = {'no' if args.writable else 'yes'}
guest ok = {'yes' if args.guest else 'no'}
""")
        print(f"SMB fixture: 127.0.0.1:{args.port}/MUSIC, {args.dialect}, encryption {args.encryption}", flush=True)
        process = subprocess.Popen([executable, "-F", "--no-process-group", "-s", str(config)])
        try:
            process.wait()
        except KeyboardInterrupt:
            process.terminate()
            process.wait(timeout=10)


if __name__ == "__main__":
    main()
