"""Install pinned Linux CI binaries after checking their upstream SHA-256 sums."""
from __future__ import annotations

import hashlib
import io
import os
from pathlib import Path
import tarfile
import urllib.request
import zipfile


def download(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=90) as response:
        return response.read()


def install(destination: Path, binary: str, release: str, archive: str, checksums: str) -> None:
    payload = download(f"{release}/{archive}")
    hashes = download(f"{release}/{checksums}").decode("utf-8")
    expected = next(line.split()[0] for line in hashes.splitlines() if line.split()[-1].lstrip("*") == archive)
    if hashlib.sha256(payload).hexdigest() != expected:
        raise RuntimeError(f"Checksum mismatch for {binary}")
    if archive.endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(payload)) as package:
            content = package.read(binary)
    else:
        with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as package:
            member = package.extractfile(binary)
            if member is None:
                raise RuntimeError(f"Missing binary {binary}")
            content = member.read()
    target = destination / binary
    target.write_bytes(content)
    target.chmod(0o755)


if __name__ == "__main__":
    target_dir = Path(os.environ["RUNNER_TEMP"]) / "ticketing-tools"
    target_dir.mkdir(parents=True, exist_ok=True)
    install(target_dir, "terraform", "https://releases.hashicorp.com/terraform/1.17.2", "terraform_1.17.2_linux_amd64.zip", "terraform_1.17.2_SHA256SUMS")
    install(target_dir, "tflint", "https://github.com/terraform-linters/tflint/releases/download/v0.66.0", "tflint_linux_amd64.zip", "checksums.txt")
    install(target_dir, "gitleaks", "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1", "gitleaks_8.30.1_linux_x64.tar.gz", "gitleaks_8.30.1_checksums.txt")
    with Path(os.environ["GITHUB_PATH"]).open("a", encoding="utf-8") as stream:
        stream.write(str(target_dir) + "\n")
