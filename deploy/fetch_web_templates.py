"""Installs Godot's single-threaded Web export templates without downloading
the whole 1.3 GB template bundle: the .tpz is a zip, so HTTP range requests
read just its directory and the two files the Web export needs (~10 MB each).

Every extracted file is checked against a pinned SHA-512, so a tampered or
corrupted download fails the build.

    python3 fetch_web_templates.py <godot version, e.g. 4.7.2> <dest dir>
"""
import hashlib
import io
import os
import sys
import urllib.request
import zipfile

# SHA-512 of the files inside Godot_v4.7.2-stable_export_templates.tpz
# (which itself is listed in the release's SHA512-SUMS.txt as ca4d71c4...).
PINNED = {
    "4.7.2": {
        "version.txt": "1a068c1a5338ef144813775d7d1964fb4f03b3aa1142f9a01ce1666c411c4a43eebb0f0b8eb958ec7625d623264e743c6ca92fbf2890d88f9788bff30043e65f",
        "web_nothreads_release.zip": "33a52b6d9b1ce32d3683caaa3ea4b997a3f84c76a92a2e4a98a115b46da55d887854c9ef49bbf3b45b9629938110837978132c3a8cda26d278eb020bd6a9b8ea",
    },
}


class RangeFile(io.RawIOBase):
    """A read-only, seekable view of a remote file over HTTP range requests."""

    def __init__(self, url):
        self.url = url
        self.pos = 0
        head = urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=60)
        self.size = int(head.headers["Content-Length"])

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        base = {0: 0, 1: self.pos, 2: self.size}[whence]
        self.pos = base + offset
        return self.pos

    def readinto(self, buf):
        if self.pos >= self.size:
            return 0
        end = min(self.pos + len(buf), self.size) - 1
        req = urllib.request.Request(self.url, headers={"Range": f"bytes={self.pos}-{end}"})
        data = urllib.request.urlopen(req, timeout=120).read()
        buf[: len(data)] = data
        self.pos += len(data)
        return len(data)


def main():
    version, dest = sys.argv[1], sys.argv[2]
    if version not in PINNED:
        sys.exit(f"No pinned template hashes for Godot {version}: add them to {__file__}")
    url = (f"https://github.com/godotengine/godot/releases/download/{version}-stable/"
           f"Godot_v{version}-stable_export_templates.tpz")
    os.makedirs(dest, exist_ok=True)
    bundle = zipfile.ZipFile(io.BufferedReader(RangeFile(url), 1 << 20))
    for name, expected in PINNED[version].items():
        data = bundle.read(f"templates/{name}")
        actual = hashlib.sha512(data).hexdigest()
        if actual != expected:
            sys.exit(f"SHA-512 mismatch for {name}: got {actual}")
        with open(os.path.join(dest, name), "wb") as out:
            out.write(data)
        print(f"installed {name} ({len(data)} bytes, checksum ok)")


if __name__ == "__main__":
    main()
