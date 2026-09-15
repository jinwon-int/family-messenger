"""deploy/tuwunel 배포 패키지의 정합성 검사 — 네트워크·실행 없이 파일만 본다."""
import json
import re
import subprocess
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PKG = ROOT / "deploy" / "tuwunel"
SHA256 = re.compile(r"^[0-9a-f]{64}$")


class TuwunelPinsTest(unittest.TestCase):
    def setUp(self):
        self.pins = json.loads((PKG / "tuwunel.pins.json").read_text(encoding="utf-8"))

    def test_version_and_binary_pin(self):
        self.assertRegex(self.pins["version"], r"^v\d+\.\d+\.\d+$")
        binary = self.pins["binary"]
        self.assertRegex(binary["sha256"], SHA256)
        self.assertGreater(binary["size"], 50_000_000)
        self.assertTrue(binary["path_in_deb"].endswith("/tuwunel"))

    def test_default_asset_is_verified(self):
        deb = self.pins["assets"]["deb"]
        self.assertEqual(deb["status"], "verified")
        self.assertRegex(deb["sha256"], SHA256)
        self.assertIn(self.pins["version"], deb["name"])
        self.assertTrue(deb["name"].endswith(".deb"))

    def test_unverified_assets_have_no_hash(self):
        for name, asset in self.pins["assets"].items():
            if asset["status"] != "verified":
                self.assertIsNone(asset["sha256"], f"{name}: unverified asset must not carry a pinned hash")


class TuwunelConfigExampleTest(unittest.TestCase):
    def setUp(self):
        text = (PKG / "tuwunel.toml.example").read_text(encoding="utf-8")
        # 자리표시자를 채운 뒤 파싱해 TOML 문법과 키 이름을 검사한다.
        text = text.replace("<server_name, 예: example.com>", "example.com").replace(
            "<matrix_api_host, 예: matrix.example.com>", "matrix.example.com"
        )
        self.cfg = tomllib.loads(text)["global"]

    def test_family_safety_defaults(self):
        self.assertEqual(self.cfg["address"], ["127.0.0.1"])
        self.assertFalse(self.cfg["allow_guest_registration"])
        self.assertFalse(self.cfg["allow_federation"])
        self.assertTrue(self.cfg["allow_registration"])
        # [2026-09-15 yukson 실측] LoadCredential 경로는 서비스 정지 시 사라져 복원 드릴 원샷이
        # 실패하므로, 서비스 사용자가 직접 읽는 정적 경로(root:tuwunel 0640)를 쓴다.
        self.assertEqual(self.cfg["registration_token_file"], "/etc/tuwunel/registration_token")
        self.assertTrue(self.cfg["allow_encryption"])
        self.assertEqual(self.cfg["encryption_enabled_by_default_for_room_type"], "invite")
        self.assertFalse(self.cfg["allow_legacy_media"])
        self.assertEqual(self.cfg["ip_source"], "cf_connecting_ip")
        self.assertEqual(self.cfg["url_preview_domain_contains_allowlist"], [])
        self.assertEqual(self.cfg["max_request_size"], "100 MiB")

    def test_no_real_secrets_or_hosts(self):
        text = (PKG / "tuwunel.toml.example").read_text(encoding="utf-8")
        self.assertNotRegex(text, r"seoyoon-family\.com|racknerd|vps\d")
        self.assertIn("example.com", text)


class TuwunelServiceUnitTest(unittest.TestCase):
    def test_hardening_directives(self):
        unit = (PKG / "tuwunel.service").read_text(encoding="utf-8")
        for directive in (
            "User=tuwunel",
            "NoNewPrivileges=yes",
            "ProtectSystem=strict",
            "ProtectHome=yes",
            # LoadCredential은 복원 드릴 원샷과 충돌해 제거 — 정적 경로(root:tuwunel 0640) 사용
            "ReadWritePaths=/var/lib/tuwunel /var/lib/tuwunel-backups",
            "SystemCallFilter=io_uring_setup io_uring_enter io_uring_register sched_setaffinity",
            "CapabilityBoundingSet=",
            "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX",
        ):
            self.assertIn(directive, unit, directive)
        self.assertNotIn("DynamicUser=", unit)  # 상태 경로가 symlink가 되어 RocksDB 경로 검사와 충돌

    def test_ingress_exposes_only_client_surface(self):
        ingress = json.loads((PKG / "cloudflare-ingress.example.json").read_text(encoding="utf-8"))
        rules = ingress["ingress"]
        self.assertEqual(rules[-1]["service"], "http_status:404")
        paths = " ".join(r.get("path", "") for r in rules)
        self.assertIn("_matrix/client", paths)
        self.assertIn("well-known/matrix/client", paths)
        self.assertNotIn("_synapse", paths)
        self.assertNotIn("federation", paths)
        self.assertNotRegex(json.dumps(ingress), r"seoyoon-family\.com")


class FetchScriptTest(unittest.TestCase):
    def test_bash_syntax_and_fail_closed_shape(self):
        script = PKG / "fetch-tuwunel.sh"
        subprocess.run(["bash", "-n", str(script)], check=True)
        text = script.read_text(encoding="utf-8")
        self.assertIn("set -euo pipefail", text)
        self.assertIn("sha256 mismatch", text)
        self.assertIn("size mismatch", text)
        self.assertIn("trap cleanup_fail ERR", text)

    def test_rejects_unpinned_asset(self):
        result = subprocess.run(
            ["bash", str(PKG / "fetch-tuwunel.sh"), "--asset", "zst", "--dest", "/nonexistent/should-not-be-created"],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 65)
        self.assertIn("no pinned sha256", result.stderr)
        self.assertFalse(Path("/nonexistent/should-not-be-created").exists())


if __name__ == "__main__":
    unittest.main()
