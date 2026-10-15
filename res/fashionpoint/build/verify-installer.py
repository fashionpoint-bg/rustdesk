#!/usr/bin/env python3
"""FashionPoint: checks an FPRemote Windows installer before it is uploaded.

    verify-installer.py <installer.exe> <edition config json> [--signed]

The installer is the portable packer of libs/portable/generate.py: b"rustdesk", then for each file its path, its
brotli data and its md5, then b"rustdesk" and the exe it launches. Checks that every file unpacks with its md5, that
it launches .\\<app-name>.exe, that the parts every release has are there, and that librustdesk.dll carries exactly
the edition's config (the JSON compiled in as FP_CLIENT_CONFIG). With --signed, also that every exe and dll inside
carries an Authenticode signature (whether it is valid is checked on Windows, by sign-windows.ps1). Needs the Python
package brotli.
"""
import hashlib
import json
import struct
import sys

import brotli

REQUIRED = ["librustdesk.dll", "flutter_windows.dll", "dylib_virtual_display.dll", "WindowInjection.dll",
            "printer_driver_adapter.dll", "data\\app.so", "data\\icudtl.dat", "data\\flutter_assets\\AssetManifest.json"]
REQUIRED_DIRS = ["drivers\\RustDeskPrinterDriver\\", "usbmmidd_v2\\"]


def unpack(path):
    data = open(path, "rb").read()
    pos = data.find(b"rustdesk")
    while pos != -1:
        n = int.from_bytes(data[pos + 8:pos + 12], "big")
        if 0 < n < 512 and data[pos + 12:pos + 12 + n][:2] in (b"./", b".\\"):
            break
        pos = data.find(b"rustdesk", pos + 1)
    if pos == -1:
        sys.exit(f"{path}: no payload")
    files, i = {}, pos + 8
    while data[i:i + 8] != b"rustdesk":
        n = int.from_bytes(data[i:i + 4], "big"); i += 4
        name = data[i:i + n].decode(); i += n
        m = int.from_bytes(data[i:i + 4], "big"); i += 4
        raw = brotli.decompress(data[i:i + m]); i += m
        md5 = data[i:i + 32].decode(); i += 32
        if hashlib.md5(raw).hexdigest() != md5:
            sys.exit(f"{path}: {name} fails its md5")
        files[name.replace("/", "\\").lstrip(".\\")] = raw
    launch = data[i + 8:].split(b"\0")[0].decode(errors="replace")
    return files, launch


def has_signature(raw):
    if raw[:2] != b"MZ":
        return False
    pe = struct.unpack_from("<I", raw, 0x3C)[0]
    opt = pe + 24
    dirs = opt + (96 if struct.unpack_from("<H", raw, opt)[0] == 0x10B else 112)
    off, size = struct.unpack_from("<II", raw, dirs + 8 * 4)
    return off > 0 and size > 0


installer, config_path = sys.argv[1], sys.argv[2]
signed = "--signed" in sys.argv[3:]
config = open(config_path, encoding="utf-8").read().strip()
app = json.loads(config)["app-name"]
files, launch = unpack(installer)
errors = []
if not launch.startswith(f".\\{app}.exe"):
    errors.append(f"launches {launch[:40]!r}, not .\\{app}.exe")
for name in [f"{app}.exe"] + REQUIRED:
    if name not in files:
        errors.append(f"{name} is missing")
for prefix in REQUIRED_DIRS:
    if not any(n.startswith(prefix) for n in files):
        errors.append(f"{prefix} is missing")
lib = files.get("librustdesk.dll", b"")
if lib.count(config.encode()) != 1:
    errors.append("librustdesk.dll does not carry the edition's config exactly once")
if signed:
    unsigned = [n for n, raw in files.items() if n.lower().endswith((".exe", ".dll")) and not has_signature(raw)]
    if unsigned:
        errors.append("not signed: " + ", ".join(unsigned))
    if not has_signature(open(installer, "rb").read()):
        errors.append("the installer itself is not signed")
if errors:
    sys.exit(f"{installer}:\n  " + "\n  ".join(errors))
pe = sum(1 for n in files if n.lower().endswith((".exe", ".dll")))
print(f"{installer}: {len(files)} files ({pe} exe/dll{', all signed' if signed else ''}), launches .\\{app}.exe, "
      f"config of the edition in librustdesk.dll")
