"""Synthetic, local-only checks. No game, GUI or installer is executed."""
import ctypes
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

import assemble_release as release


def png(width=1, height=1):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(
        b"IDAT", zlib.compress((b"\0" + b"\0\0\0\xff" * width) * height)) + chunk(b"IEND", b"")


def seal(cipher, plain):
    """Test-only CNG encryption. Production assembly exposes no encryption path."""
    function = cipher.dll.BCryptEncrypt
    function.argtypes = cipher.dll.BCryptDecrypt.argtypes
    function.restype = ctypes.c_int32
    nonce, tag = ctypes.create_string_buffer(os.urandom(12)), ctypes.create_string_buffer(16)
    data, output = ctypes.create_string_buffer(plain), ctypes.create_string_buffer(max(len(plain), 1))
    info = cipher.AuthInfo()
    info.cbSize, info.dwInfoVersion = ctypes.sizeof(info), 1
    info.pbNonce, info.cbNonce = ctypes.addressof(nonce), 12
    info.pbTag, info.cbTag = ctypes.addressof(tag), 16
    written = ctypes.c_uint32()
    cipher.check(function(cipher.key, data, len(plain), ctypes.byref(info), None, 0, output, len(output), ctypes.byref(written), 0))
    return release.SEALED_HEADER + nonce.raw[:12] + tag.raw[:16] + output.raw[:written.value]


def container(cipher, names=release.PRIVATE_NAMES, invalid_offset=False):
    blocks = [seal(cipher, b'{"synthetic":true}') for _ in names]
    size = 12 + 36 + sum(16 + len(name.encode("utf8")) for name in names)
    header = b"PBZS\x03\x01" + struct.pack("<HI", len(names), size)
    rows, offset = [], 0
    for index, (name, block) in enumerate(zip(names, blocks)):
        label = name.encode("utf8")
        at = 1 if invalid_offset and index == 0 else offset
        rows.append(struct.pack("<H", len(label)) + label + struct.pack("<BBIII", 0, 0, 18, at, len(block)))
        offset += len(block)
    return header + seal(cipher, header + b"".join(rows)) + b"".join(blocks)


class SourceAndInputChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = release.ROOT / "build"
        cls.build.mkdir(exist_ok=True)

    def test_payload_contract(self):
        self.assertEqual(len(release.RUNTIME_FILES), 52)
        self.assertEqual(len(set(release.RUNTIME_FILES)), 52)
        self.assertTrue({"LionArena.lua", "EnemyHealthGuard.lua", "StampPress.lua"}.issubset(release.RUNTIME_FILES))
        self.assertNotIn("ChallengeUI.lua", release.RUNTIME_FILES)
        self.assertIn("ue4ss/Mods/shared/UEHelpers/UEHelpers.lua", release.LOADER_FILES)
        self.assertEqual(len(release.PRIVATE_NAMES), 18)
        self.assertNotIn("__Advanced__", release.PRIVATE_NAMES)

    def test_missing_input_fails(self):
        with tempfile.TemporaryDirectory(dir=self.build) as directory:
            with self.assertRaisesRegex(ValueError, "missing"):
                release.read(Path(directory) / "missing.bin")

    def test_wrong_executable_fails_without_any_external_file(self):
        with tempfile.TemporaryDirectory(dir=self.build) as directory:
            game = Path(directory) / "not-a-game.exe"
            game.write_bytes(b"Synthetic negative input, never executed")
            with self.assertRaisesRegex(ValueError, "fingerprint"):
                release.derive_game_key(game)

    def test_duplicate_json_key_fails(self):
        with tempfile.TemporaryDirectory(dir=self.build) as directory:
            source = Path(directory) / "Manifest.json"
            source.write_text('{"files":[],"files":[]}', encoding="utf8")
            with self.assertRaisesRegex(ValueError, "Duplicate"):
                release.read_json(source)

    def test_output_escape_fails_before_input_reads(self):
        options = release.parser().parse_args(["--assets-dir", "absent", "--presets", "absent", "--ue4ss-zip", "absent", "--game-exe", "absent"])
        with tempfile.TemporaryDirectory(dir=self.build) as directory:
            root = Path(directory)
            options.output = str(root / "dist/../outside")
            with patch.object(release, "ROOT", root), self.assertRaisesRegex(ValueError, "new child"):
                release.assemble(options)
            self.assertFalse((root / "outside").exists())

    def test_existing_release_is_not_overwritten(self):
        options = release.parser().parse_args(["--assets-dir", "absent", "--presets", "absent", "--ue4ss-zip", "absent", "--game-exe", "absent"])
        with tempfile.TemporaryDirectory(dir=self.build) as directory:
            root = Path(directory)
            output = root / "dist/existing"
            output.mkdir(parents=True)
            keep = output / "keep.txt"
            keep.write_bytes(b"keep existing release")
            options.output = str(output)
            with patch.object(release, "ROOT", root), self.assertRaisesRegex(ValueError, "new child"):
                release.assemble(options)
            self.assertEqual(keep.read_bytes(), b"keep existing release")

    def test_png_dimensions_crc_and_end(self):
        data = png(3, 2)
        self.assertEqual(release.image_size(data, "fixture.png"), (3, 2))
        changed = bytearray(data)
        changed[20] ^= 1
        with self.assertRaisesRegex(ValueError, "CRC"):
            release.image_size(changed, "fixture.png")
        with self.assertRaises(ValueError):
            release.image_size(data[:-1], "fixture.png")

    def test_ui_metadata_only_line_endings_are_equivalent(self):
        old = b"return {\r\n    value = 1,\r\n}\r\n"
        lf = old.replace(b"\r\n", b"\n")
        self.assertIn(release.digest(old), release.metadata_hashes(lf))
        self.assertIn(release.digest(lf), release.metadata_hashes(old))
        self.assertNotIn(release.digest(old.replace(b"1", b"2")), release.metadata_hashes(lf))

    def test_x64_pe_header_validation(self):
        pe = bytearray(128)
        pe[:2] = b"MZ"
        struct.pack_into("<I", pe, 0x3c, 64)
        pe[64:68] = b"PE\0\0"
        struct.pack_into("<H", pe, 68, 0x8664)
        struct.pack_into("<H", pe, 88, 0x20b)
        release.pe64(pe, "synthetic-header")
        struct.pack_into("<H", pe, 68, 0x14c)
        with self.assertRaisesRegex(ValueError, "x64"):
            release.pe64(pe, "synthetic-header")

    def test_generated_data_current_and_stale(self):
        with tempfile.TemporaryDirectory(dir=self.build) as directory:
            output = Path(directory)
            subprocess.run([sys.executable, str(release.ROOT / "tools/data/generate_runtime_data.py"), "--output", str(output)],
                check=True, stdout=subprocess.PIPE)
            self.assertEqual(set(release.generated_data(output)), set(release.GENERATED))
            with (output / "BossCatalog.lua").open("ab") as target:
                target.write(b"-- stale synthetic modification\n")
            with self.assertRaisesRegex(ValueError, "stale"):
                release.generated_data(output)


@unittest.skipUnless(os.name == "nt", "Windows CNG authentication checks")
class PresetAuthenticationChecks(unittest.TestCase):
    def setUp(self):
        self.cipher = release.CngGcm(bytes(range(32)))

    def tearDown(self):
        self.cipher.close()

    def test_canonical_eighteen_blocks(self):
        result = release.verify_presets(container(self.cipher), self.cipher)
        self.assertEqual(tuple(result), release.PRIVATE_NAMES)
        self.assertEqual(len(result), 18)

    def test_ordinary_slot_instead_of_private_fails(self):
        names = ("AutoSave0", *release.PRIVATE_NAMES[1:])
        with self.assertRaisesRegex(ValueError, "canonical"):
            release.verify_presets(container(self.cipher, names), self.cipher)

    def test_advanced_account_block_fails(self):
        names = ("__Advanced__", *release.PRIVATE_NAMES[1:])
        with self.assertRaisesRegex(ValueError, "canonical"):
            release.verify_presets(container(self.cipher, names), self.cipher)

    def test_changed_directory_gcm_tag_fails(self):
        data = bytearray(container(self.cipher))
        data[32] ^= 1
        with self.assertRaisesRegex(ValueError, "CNG authentication"):
            release.verify_presets(bytes(data), self.cipher)

    def test_changed_payload_gcm_tag_fails(self):
        data = bytearray(container(self.cipher))
        data[-1] ^= 1
        with self.assertRaisesRegex(ValueError, "CNG authentication"):
            release.verify_presets(bytes(data), self.cipher)

    def test_authenticated_invalid_offset_fails(self):
        with self.assertRaisesRegex(ValueError, "extent"):
            release.verify_presets(container(self.cipher, invalid_offset=True), self.cipher)

    def test_trailing_bytes_fails(self):
        with self.assertRaisesRegex(ValueError, "cover"):
            release.verify_presets(container(self.cipher) + b"extra", self.cipher)


if __name__ == "__main__":
    unittest.main(verbosity=2)
