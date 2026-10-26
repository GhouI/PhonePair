"""Package and structurally check the ad-hoc IPA for the user's signing service."""
import hashlib
import plistlib
import struct
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
app = root / "build/Payload/PhonePair.app"
info_path = app / "Info.plist"
info = plistlib.loads(info_path.read_bytes())
assert info["CFBundleExecutable"] == "PhonePair"
assert info["MinimumOSVersion"] == "27.0"
assert "_remotepairing-pairable-host._tcp" in info["NSBonjourServices"]
assert "UIBackgroundModes" not in info
binary = (app / "PhonePair").read_bytes()
magic, cpu, *_ = struct.unpack_from("<8I", binary)
assert magic == 0xFEEDFACF and cpu == 0x0100000C, "Expected arm64 Mach-O"
ncmds = struct.unpack_from("<I", binary, 16)[0]
offset = 32
has_signature = False
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", binary, offset)
    assert size >= 8
    if cmd == 0x1D:
        has_signature = True
    offset += size
assert has_signature, "Expected ad-hoc signature for re-signing"
info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
ipa = root / "build/PhonePair-0.1.0.ipa"
with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob("*")):
        if path.is_file():
            archive.write(path, path.relative_to(root / "build"))
with zipfile.ZipFile(ipa) as archive:
    assert archive.testzip() is None
    assert "Payload/PhonePair.app/Info.plist" in archive.namelist()
checksum = hashlib.sha256(ipa.read_bytes()).hexdigest()
ipa.with_suffix(".ipa.sha256").write_text(f"{checksum}  {ipa.name}\n")
print(f"IPA created: {ipa} ({ipa.stat().st_size:,} bytes)")
print(f"SHA-256: {checksum}")
