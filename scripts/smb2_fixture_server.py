"""Local SMB2 fixture for TEST_SMB=1 flutter test test/network_storage_service_test.dart.

Requires impacket in a temporary Python environment. Listens only on loopback,
uses port 1445, and exposes only generated test data in a temporary directory.
"""

from argparse import ArgumentParser
from pathlib import Path
from tempfile import TemporaryDirectory

from impacket.ntlm import compute_lmhash, compute_nthash
from impacket.smbserver import SimpleSMBServer


def main():
    parser = ArgumentParser()
    parser.add_argument("--deletion", action="store_true")
    args = parser.parse_args()
    with TemporaryDirectory(prefix="mornye-smb-test-") as root:
        (Path(root) / "A B.wav").write_bytes(bytes(range(256)))
        if args.deletion:
            deletion = Path(root) / "Deletion"
            deletion.mkdir()
            (deletion / "Target.flac").write_bytes(bytes(range(256)))
            (deletion / "Keep.flac").write_bytes(bytes(range(256)))
        server = SimpleSMBServer(listenAddress="127.0.0.1", listenPort=1445)
        server.addShare("MUSIC", root)
        server.setSMB2Support(True)
        server.addCredential("test", 0, compute_lmhash("secret"), compute_nthash("secret"))
        server.start()


if __name__ == "__main__":
    main()
