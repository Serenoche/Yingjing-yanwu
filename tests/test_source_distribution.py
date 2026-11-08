"""Audit the source-distribution boundary without reading a game or a save."""
from __future__ import annotations

import re
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
LOCAL_DIRS = {".git", "build", "dist", "local-inputs", "__pycache__", ".venv"}
SOURCE_SUFFIXES = {
    ".lua", ".py", ".cpp", ".hpp", ".cs", ".ps1", ".cmd", ".json",
    ".md", ".txt", ".yml", ".yaml", ".mit",
}
ROOT_FILES = {"LICENSE", ".gitignore", ".gitattributes", ".editorconfig"}


def distribution_files() -> list[Path]:
    """Use the Git index when available, so ignored-but-tracked files are checked."""
    if (ROOT / ".git").exists():
        result = subprocess.run(
            ["git", "-c", "safe.directory=" + ROOT.as_posix(), "ls-files", "-z"],
            cwd=ROOT, check=True, capture_output=True
        )
        names = [part.decode("utf-8") for part in result.stdout.split(b"\0") if part]
        if names:
            return [ROOT / name for name in names]
    return [p for p in ROOT.rglob("*") if p.is_file()
            and not LOCAL_DIRS.intersection(p.relative_to(ROOT).parts)]


class SourceDistributionTests(unittest.TestCase):
    def test_only_reviewable_source_is_in_the_distribution(self):
        files = distribution_files()
        self.assertGreater(len(files), 75, "This check must cover the full source tree")
        for path in files:
            with self.subTest(file=path.relative_to(ROOT).as_posix()):
                relative = path.relative_to(ROOT)
                self.assertFalse(LOCAL_DIRS.intersection(relative.parts))
                self.assertFalse(path.is_symlink(), "Do not distribute links to local inputs")
                self.assertTrue(path.name in ROOT_FILES or path.suffix.lower() in SOURCE_SUFFIXES,
                                "Binary, media, save, state or unreviewed file type")
                data = path.read_bytes()
                self.assertNotIn(b"\0", data, "Source must not embed a binary payload")
                data.decode("utf-8-sig")

    def test_no_common_personal_identifier_or_credential_payloads(self):
        patterns = {
            "personal Windows home": re.compile(r"[A-Za-z]:[\\/]Users[\\/][^\\/\s\"']+", re.I),
            "Steam account identifier": re.compile(r"\b7656119\d{10}\b"),
            "Windows account SID": re.compile(r"S-1-5-21-\d+-\d+-\d+-\d+"),
            "GitHub token": re.compile(r"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})"),
            "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
        }
        for path in distribution_files():
            content = path.read_text(encoding="utf-8-sig")
            for label, pattern in patterns.items():
                with self.subTest(file=path.relative_to(ROOT).as_posix(), check=label):
                    # A failed check identifies only the file/category, never a matched secret.
                    self.assertIsNone(pattern.search(content), label)

    def test_runtime_dependencies_are_local_or_the_declared_loader_helper(self):
        scripts = ROOT / "src/runtime/Scripts"
        modules = {path.stem for path in scripts.glob("*.lua")}
        self.assertIn("main", modules)
        self.assertNotIn("ChallengeUI", modules, "The retired external overlay is not shipped")
        used_external = set()
        for path in scripts.glob("*.lua"):
            for dependency in re.findall(r'\brequire\s*\(\s*[\"\']([^\"\']+)[\"\']',
                                         path.read_text(encoding="utf-8-sig")):
                if dependency not in modules:
                    used_external.add(dependency)
        self.assertEqual(used_external, {"UEHelpers"})
        for name in ("BossCatalog", "GeneratedEncounterCatalog", "GeneratedArenaScenes",
                     "NativeUiAssetsData"):
            self.assertGreater((scripts / (name + ".lua")).stat().st_size, 1000,
                               "Do not replace a missing manifest with an empty stub")

    def test_license_notices_and_powershell_encoding_are_preserved(self):
        self.assertIn("MIT License", (ROOT / "LICENSE").read_text(encoding="utf-8"))
        self.assertTrue((ROOT / "THIRD_PARTY_NOTICES.md").is_file())
        self.assertIn("Niels Lohmann", (ROOT / "src/save_tool/vendor/LICENSE.MIT")
                      .read_text(encoding="utf-8"))
        for path in (ROOT / "src/installer").glob("*.ps1"):
            # Windows PowerShell 5.1 needs the BOM to read Chinese UI text reliably.
            content = path.read_bytes()
            if not content.isascii():
                self.assertTrue(content.startswith(b"\xef\xbb\xbf"), path.name)


if __name__ == "__main__":
    unittest.main()
