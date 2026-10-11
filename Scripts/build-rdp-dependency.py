#!/usr/bin/env python3
"""Rebuild the pinned static FreeRDP runtime; does not install system packages."""
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import urllib.request

root = pathlib.Path(__file__).resolve().parent.parent
version = "3.32.1"
checksum = "8803dd26ec9660550252f255cf2d672a785ddd8f544bb475834993e96807c87f"
work = root / ".build/rdp-deps"
tools = root / ".build/rdp-tools"
work.mkdir(parents=True, exist_ok=True)
cmake = tools / "bin/cmake"
if not cmake.is_file():
    subprocess.run([sys.executable, "-m", "venv", str(tools)], check=True)
    subprocess.run([str(tools / "bin/pip"), "install", "cmake==4.4.4", "ninja==1.13.2"], check=True)
archive = work / f"freerdp-{version}.tar.gz"
if not archive.is_file():
    urllib.request.urlretrieve(f"https://github.com/FreeRDP/FreeRDP/archive/refs/tags/{version}.tar.gz", archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
    raise SystemExit("FreeRDP source checksum mismatch; refusing to build")
source = work / f"FreeRDP-{version}"
if not source.is_dir():
    with tarfile.open(archive) as bundle:
        members = bundle.getmembers()
        for member in members:
            target = (work / member.name).resolve()
            if not target.is_relative_to(work.resolve()) or not (member.isfile() or member.isdir()):
                raise SystemExit("Unexpected archive path or entry; refusing to extract")
        # Compatible with the system Python 3.9 on macOS; paths and types checked above.
        bundle.extractall(work, members=members)
openssl = root / ".build/artifacts/openssl-spm/libssl/OpenSSL.Package.xcframework/macos-arm64_x86_64"
if not (openssl / "libssl.a").is_file():
    subprocess.run(["swift", "package", "resolve"], cwd=root, check=True)
if not (openssl / "libssl.a").is_file():
    raise SystemExit("Resolve the OpenSSL SwiftPM binary artifact before building FreeRDP")
dest = root / "Vendor/FreeRDP"
disabled = ["CLIENT", "SERVER", "SHADOW", "PROXY", "CHANNELS", "SAMPLE", "X11", "WAYLAND", "SDL",
            "FFMPEG", "SWSCALE", "CUPS", "PULSE", "ALSA", "PCSC", "KRB5", "FUSE", "ICU", "JPEG",
            "OPENH264", "AAD", "WEBVIEW", "SMARTCARD_EMULATE", "MANPAGES", "BINARY_VERSIONING", "WINPR_TOOLS"]
args = [str(cmake), "-S", str(source), "-B", str(work / "build"), "-G", "Ninja",
        f"-DCMAKE_MAKE_PROGRAM={tools / 'bin/ninja'}", "-DCMAKE_BUILD_TYPE=Release",
        f"-DCMAKE_INSTALL_PREFIX={dest}", "-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0",
        "-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64", "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_TESTING=OFF",
        f"-DOPENSSL_INCLUDE_DIR={openssl / 'Headers'}", f"-DOPENSSL_SSL_LIBRARY={openssl / 'libssl.a'}",
        f"-DOPENSSL_CRYPTO_LIBRARY={openssl / 'libssl.a'}"]
args += [f"-DWITH_{name}=OFF" for name in disabled]
subprocess.run(args, check=True)
subprocess.run([str(cmake), "--build", str(work / "build"), "-j", str(min(os.cpu_count() or 4, 8))], check=True)
subprocess.run([str(cmake), "--install", str(work / "build")], check=True)
shutil.copy2(source / "LICENSE", dest / "LICENSE")
manifest = {
    "version": version,
    "source": f"https://github.com/FreeRDP/FreeRDP/tree/{version}",
    "sourceArchiveSHA256": checksum,
    "architectures": ["arm64", "x86_64"],
    "minimumMacOS": "26.0",
    "buildScript": "Scripts/build-rdp-dependency.py",
    "libraries": {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in sorted((dest / "lib").glob("*.a"))},
}
(dest / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"FreeRDP {version} static runtime built in {dest}")
