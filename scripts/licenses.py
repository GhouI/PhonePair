"""Collect the pinned Rust dependencies' bundled license texts for the IPA."""
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent.parent
metadata = json.loads((root / "build/cargo-metadata.json").read_text())
sections = ["PhonePair Rust dependency licenses\n"]
for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
    if package["name"] == "phonepair-core":
        continue
    folder = Path(package["manifest_path"]).parent
    texts = sorted(p for p in folder.iterdir() if p.is_file() and p.name.lower().startswith(("license", "licence", "copying", "copyright")))
    if not texts and package["name"] == "idevice":
        texts = [folder.parent / "LICENSE.txt"]
    sections.append(f"\n{'=' * 72}\n{package['name']} {package['version']}\nLicense: {package['license']}\nSource: {package.get('repository') or package.get('source')}\n")
    for path in texts:
        sections.append(f"\n--- {path.name} ---\n{path.read_text(errors='replace')}\n")
sysroot = Path(subprocess.check_output([str(Path.home() / ".cargo/bin/rustc"), "--print", "sysroot"], text=True).strip())
copyright_path = sysroot / "share/doc/rust/COPYRIGHT-library.html"
if copyright_path.exists():
    sections.append("\nRust standard library copyright and licenses\n" + copyright_path.read_text())
    for path in sorted((sysroot / "share/doc/rust/licenses").glob("*")):
        if path.is_file():
            sections.append(f"\n--- Rust: {path.name} ---\n{path.read_text(errors='replace')}\n")
out = root / "Dependency-Licenses.txt"
out.write_text("".join(sections))
print(f"Collected notices for {len(metadata['packages']) - 1} dependency packages.")
