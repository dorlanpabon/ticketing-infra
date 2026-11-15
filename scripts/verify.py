"""Audit every introduced Git commit using rules from an independently trusted tree."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile

SHA = re.compile(r"^[0-9a-f]{40}$")
PROTECTED = ("scripts/", ".github/", ".githooks/", ".checkov.yml", ".tflint.hcl", ".terraform-version", ".gitleaks", ".gitignore", ".gitattributes")


def run(command: list[str], cwd: Path, timeout: int = 900) -> str:
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} failed ({result.returncode}):\n{result.stdout[-6000:]}\n{result.stderr[-2000:]}")
    return result.stdout.strip()


def revision(repo: Path, value: str) -> str:
    sha = run(["git", "rev-parse", "--verify", f"{value}^{{commit}}"], repo)
    if not SHA.fullmatch(sha):
        raise ValueError("Expected a full Git commit SHA")
    return sha


def introduced(repo: Path, before: str | None, after: str) -> list[str]:
    args = ["git", "rev-list", "--reverse", "--topo-order", revision(repo, after)]
    if before and set(before) != {"0"}:
        args.append("^" + revision(repo, before))
    return run(args, repo).splitlines()


def snapshot(repo: Path, sha: str, target: Path) -> None:
    entries = subprocess.check_output(["git", "ls-tree", "-rz", "--full-tree", sha], cwd=repo)
    for entry in entries.split(b"\0"):
        if not entry:
            continue
        metadata, name = entry.split(b"\t", 1)
        mode, kind, object_id = metadata.decode("ascii").split()
        relative = PurePosixPath(name.decode("utf-8"))
        if mode not in ("100644", "100755") or kind != "blob" or relative.is_absolute() or ".." in relative.parts or "\\" in str(relative):
            raise ValueError("Unsafe path, symlink or submodule in audited tree")
        output = target.joinpath(*relative.parts)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(subprocess.check_output(["git", "cat-file", "blob", object_id], cwd=repo))
        output.chmod(int(mode[-3:], 8))


def policy_hash(root: Path) -> str:
    digest = hashlib.sha256()
    for directory, names, files in os.walk(root):
        names[:] = sorted(name for name in names if name not in (".git", ".terraform", ".work", ".trusted", "artifacts", "__pycache__"))
        for filename in sorted(files):
            path = Path(directory) / filename
            name = path.relative_to(root).as_posix()
            protected = name.startswith(PROTECTED) or filename.endswith(".tftest.hcl")
            if protected:
                # Git stores LF while an existing Windows checkout may still contain CRLF.
                # Snapshot bytes stay exact; only this text-policy fingerprint is canonicalized.
                content = path.read_bytes().replace(b"\r\n", b"\n")
            elif filename.endswith(".tf"):
                content = "\n".join(line.strip() for line in path.read_text(encoding="utf-8").splitlines() if "checkov:skip=" in line).encode()
                if not content:
                    continue
            else:
                continue
            digest.update(name.encode() + b"\0" + content + b"\0")
    return digest.hexdigest()


def verify_tree(candidate: Path, trusted: Path) -> list[str]:
    checks = []
    run([os.environ.get("GITLEAKS", "gitleaks"), "dir", "--redact", "--no-banner", "--exit-code", "1", "--ignore-gitleaks-allow", "--config", str(trusted / ".gitleaks.toml"), "--gitleaks-ignore-path", str(trusted / ".gitleaksignore"), str(candidate)], candidate)
    checks.append("gitleaks")
    terraform_files = list((candidate / "infra").rglob("*.tf")) if (candidate / "infra").exists() else []
    if not terraform_files:
        if (trusted / "infra").exists() and any((trusted / "infra").rglob("*.tf")):
            raise RuntimeError("Candidate removed the infrastructure protected by the trusted policy")
        checks.append("terraform:not-applicable")
        return checks
    terraform = os.environ.get("TERRAFORM", "terraform")
    tflint = os.environ.get("TFLINT", "tflint")
    checkov = os.environ.get("CHECKOV", "checkov")
    run([terraform, "fmt", "-check", "-recursive", "-no-color", "infra"], candidate)
    run([tflint, "--recursive", "--config", str(trusted / ".tflint.hcl")], candidate)
    run([checkov, "--directory", str(candidate), "--config-file", str(trusted / ".checkov.yml"), "--quiet"], candidate)
    checks += ["terraform-fmt", "tflint", "checkov"]
    for relative in ("infra/bootstrap", "infra/envs/dev", "infra/envs/qa", "infra/envs/prod"):
        root = candidate / relative
        if not root.exists():
            continue
        run([terraform, f"-chdir={root}", "init", "-backend=false", "-input=false", "-lockfile=readonly", "-no-color"], candidate)
        run([terraform, f"-chdir={root}", "validate", "-no-color"], candidate)
        run([terraform, f"-chdir={root}", "test", "-no-color"], candidate)
        checks.append(f"{relative}:validate-and-mocked-plan-tests")
    return checks


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--trusted", type=Path, required=True)
    parser.add_argument("--before")
    parser.add_argument("--after", default="HEAD")
    parser.add_argument("--integration")
    parser.add_argument("--approved-policy-hash")
    parser.add_argument("--print-policy-hash", action="store_true")
    args = parser.parse_args()
    repo, trusted = args.repo.resolve(), args.trusted.resolve()
    expected_policy = policy_hash(trusted)
    if args.print_policy_hash:
        print(expected_policy)
        return
    commits = introduced(repo, args.before, args.after)
    if args.integration:
        integrated = revision(repo, args.integration)
        if integrated not in commits:
            commits.append(integrated)
    if not commits:
        commits = [revision(repo, args.after)]
    work = repo / ".work"
    reports = repo / "artifacts" / "quality"
    work.mkdir(exist_ok=True)
    reports.mkdir(parents=True, exist_ok=True)
    for sha in commits:
        report = {"sha": sha, "tree": run(["git", "rev-parse", f"{sha}^{{tree}}"], repo), "trustedPolicyHash": expected_policy, "status": "failed"}
        try:
            with tempfile.TemporaryDirectory(dir=work, prefix="snapshot-") as temporary:
                candidate = Path(temporary)
                snapshot(repo, sha, candidate)
                actual_policy = policy_hash(candidate)
                if actual_policy not in (expected_policy, args.approved_policy_hash):
                    raise RuntimeError(f"Protected policy differs: review exact hash {actual_policy}")
                report["checks"] = verify_tree(candidate, trusted)
                report["status"] = "passed"
        finally:
            (reports / f"{sha}.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"{sha}: passed")


if __name__ == "__main__":
    main()
