"""deploy/sygnal 배포 패키지의 정합성 검사 — 네트워크·실행 없이 파일만 본다."""
import fnmatch
import json
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PKG = ROOT / "deploy" / "sygnal"
RUNBOOK = ROOT / "docs" / "SYGNAL-DEPLOY.md"
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


def _unit_text() -> str:
    return (PKG / "sygnal.service").read_text(encoding="utf-8")


def _unit_directives() -> str:
    """주석을 걷어낸 실제 지시자만. 주석 속 설명 문구를 잘못 잡지 않기 위해서다."""
    lines = []
    for line in _unit_text().splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            lines.append(line)
    return "\n".join(lines)


class SygnalPinsTest(unittest.TestCase):
    def setUp(self):
        self.pins = json.loads((PKG / "sygnal.pins.json").read_text(encoding="utf-8"))

    def test_version_and_source(self):
        self.assertRegex(self.pins["version"], r"^v\d+\.\d+\.\d+$")
        # matrix-org/sygnal은 2025-07 아카이브됐다. 유지보수 리포를 가리켜야 한다.
        self.assertIn("element-hq/sygnal", self.pins["source_repo"])

    def test_image_digests_are_pinned(self):
        image = self.pins["image"]
        self.assertRegex(image["index_digest"], DIGEST)
        for platform, digest in image["platform_digests"].items():
            self.assertRegex(digest, DIGEST, f"{platform}: digest 형식이 아니다")
        self.assertIn("linux/amd64", image["platform_digests"])

    def test_webpush_is_declared_included_with_caveats(self):
        """webpush 지원과 그 한계를 함께 기록해 둔다 — 성숙도·iOS 미확인을 지우지 않는다."""
        webpush = self.pins["webpush_support"]
        self.assertEqual(webpush["status"], "included")
        self.assertIn("미확인", webpush["ios_status"])
        self.assertTrue(webpush["maturity_warning"])


class SygnalUnitTest(unittest.TestCase):
    def setUp(self):
        self.unit = _unit_directives()
        self.pins = json.loads((PKG / "sygnal.pins.json").read_text(encoding="utf-8"))

    def test_unit_image_matches_pins(self):
        """유닛의 SYGNAL_IMAGE digest는 핀과 반드시 같아야 한다.

        이 동기화가 깨지면 핀을 올려도 옛 이미지가 계속 돈다. 런북·주석에서 여러 번
        당부하지만 사람이 지키는 규칙이라 여기서 기계로 검사한다.
        """
        match = re.search(r"^Environment=SYGNAL_IMAGE=(\S+)$", self.unit, re.MULTILINE)
        self.assertIsNotNone(match, "유닛에 SYGNAL_IMAGE 가 없다")
        image = match.group(1)
        self.assertTrue(image.startswith("docker.io/matrixdotorg/sygnal@"), image)
        digest = image.split("@", 1)[1]
        self.assertEqual(
            digest,
            self.pins["image"]["platform_digests"]["linux/amd64"],
            "sygnal.service 의 SYGNAL_IMAGE 가 sygnal.pins.json 과 다르다 — 함께 갱신한다",
        )

    def test_image_is_pinned_by_digest_not_tag(self):
        match = re.search(r"^Environment=SYGNAL_IMAGE=(\S+)$", self.unit, re.MULTILINE)
        image = match.group(1)
        self.assertIn("@sha256:", image, "태그로 고정하면 이미지가 이동할 수 있다")
        self.assertNotRegex(image.split("@", 1)[0], r":v?\d", "리포지토리 부분에 태그가 남아 있다")

    def test_container_drops_privileges(self):
        for flag in ("--user ${SYGNAL_UID}", "--cap-drop=ALL", "--read-only", "--security-opt=no-new-privileges"):
            self.assertIn(flag, self.unit, f"컨테이너 권한 축소 플래그 누락: {flag}")

    def test_uid_placeholder_is_empty_so_deployment_must_fill_it(self):
        """SYGNAL_UID는 빈 값으로 배포된다 — 호스트마다 다르므로 런북에서 채운다."""
        self.assertRegex(self.unit, r"(?m)^Environment=SYGNAL_UID=$")
        self.assertIn("SYGNAL_UID", RUNBOOK.read_text(encoding="utf-8"))

    def test_binds_loopback_only(self):
        self.assertIn("--publish 127.0.0.1:5000:5000", self.unit)
        # host netns를 공유하면 게이트웨이가 홈서버 등 다른 루프백 서비스에 도달한다.
        self.assertNotIn("--network=host", self.unit)

    def test_start_is_fail_closed_on_missing_image(self):
        self.assertIn("ExecStartPre=/usr/bin/podman image exists", self.unit)
        # '-' 접두사가 붙으면 실패를 무시해 fail-closed가 깨진다.
        self.assertNotIn("ExecStartPre=-", self.unit)

    def test_config_mounted_read_only_from_outside_home(self):
        self.assertIn("--volume /etc/sygnal:/sygnal:ro", self.unit)


class SygnalConfigExampleTest(unittest.TestCase):
    def setUp(self):
        self.text = (PKG / "sygnal.yaml.example").read_text(encoding="utf-8")

    def test_yaml_parses_and_declares_one_webpush_app(self):
        try:
            import yaml
        except ImportError:  # pragma: no cover - PyYAML 없는 환경
            self.skipTest("PyYAML 없음")
        doc = yaml.safe_load(self.text)
        self.assertEqual(doc["http"]["bind_addresses"], ["127.0.0.1"])
        self.assertEqual(doc["http"]["port"], 5000)
        apps = doc["apps"]
        self.assertEqual(len(apps), 1, "활성 앱은 webpush 하나여야 한다(apns는 주석)")
        app = next(iter(apps.values()))
        self.assertEqual(app["type"], "webpush")

    def test_webpush_keys_are_understood_by_sygnal(self):
        """sygnal WebpushPushkin.UNDERSTOOD_CONFIG_FIELDS 밖의 키를 쓰면 기동이 거부된다."""
        try:
            import yaml
        except ImportError:  # pragma: no cover
            self.skipTest("PyYAML 없음")
        understood = {
            "type", "max_connections", "vapid_private_key",
            "vapid_contact_email", "allowed_endpoints", "ttl",
            "inflight_request_limit",
        }
        app = next(iter(yaml.safe_load(self.text)["apps"].values()))
        self.assertTrue(set(app) <= understood, f"미지원 키: {set(app) - understood}")

    def test_allowed_endpoints_is_set_and_covers_apple(self):
        """미설정은 SSRF, Apple 누락은 조용한 유실 — 둘 다 나쁘다.

        sygnal은 endpoint의 netloc을 allowed_endpoints 글로브와 **fullmatch**로 비교한다
        (webpushpushkin.py). 여기서도 같은 방식으로 검사한다 — 부분 문자열 포함으로
        확인하면 'push.apple.com.attacker.net' 같은 값도 통과하는 느슨한 검사가 된다.
        """
        try:
            import yaml
        except ImportError:  # pragma: no cover
            self.skipTest("PyYAML 없음")
        app = next(iter(yaml.safe_load(self.text)["apps"].values()))
        endpoints = app["allowed_endpoints"]
        self.assertTrue(endpoints, "미설정은 모든 엔드포인트 허용 = SSRF 노출")
        self.assertTrue(
            any(fnmatch.fnmatch("web.push.apple.com", pattern) for pattern in endpoints),
            "Apple 엔드포인트가 허용 목록에 매칭되지 않으면 iOS 알림이 조용히 사라진다",
        )

    def test_allowed_endpoints_do_not_overmatch(self):
        """허용 패턴이 남의 도메인까지 덮지 않아야 한다."""
        try:
            import yaml
        except ImportError:  # pragma: no cover
            self.skipTest("PyYAML 없음")
        app = next(iter(yaml.safe_load(self.text)["apps"].values()))
        for hostile in ("push.apple.com.attacker.net", "evil.net", "notfcm.googleapis.com.evil.net"):
            self.assertFalse(
                any(fnmatch.fnmatch(hostile, pattern) for pattern in app["allowed_endpoints"]),
                f"허용 목록이 {hostile} 까지 매칭한다",
            )

    def test_app_id_is_literal_not_glob(self):
        """글로브 app_id는 find_pushkins 모호성 → pushkey reject → pusher 삭제."""
        try:
            import yaml
        except ImportError:  # pragma: no cover
            self.skipTest("PyYAML 없음")
        for app_id in yaml.safe_load(self.text)["apps"]:
            self.assertNotIn("*", app_id)
            self.assertNotIn("?", app_id)


class SygnalIngressTest(unittest.TestCase):
    def test_exposes_only_the_notify_endpoint(self):
        doc = json.loads((PKG / "cloudflare-ingress.example.json").read_text(encoding="utf-8"))
        rules = doc["ingress"]
        self.assertEqual(rules[-1], {"service": "http_status:404"}, "마지막은 404 폴백이어야 한다")
        paths = [r.get("path") for r in rules if "path" in r]
        self.assertEqual(paths, ["^/_matrix/push/v1/notify$"])
        # 게이트웨이의 /health 를 외부에 열지 않는다(규칙만 검사 — $comment 는 제외).
        exposed = json.dumps([r for r in rules])
        self.assertNotIn("health", exposed)


class SygnalKeygenScriptTest(unittest.TestCase):
    def setUp(self):
        self.path = PKG / "gen-vapid-key.sh"
        self.text = self.path.read_text(encoding="utf-8")

    def test_bash_syntax(self):
        subprocess.run(["bash", "-n", str(self.path)], check=True)

    def test_is_executable(self):
        self.assertTrue(self.path.stat().st_mode & 0o111, "실행 권한이 없다")

    def test_refuses_to_overwrite_existing_keys(self):
        """덮어쓰면 가족 전원의 구독이 죽는다. 컨테이너 중간 산출물 이름도 막아야 한다."""
        self.assertIn("이미 존재한다", self.text)
        self.assertIn("$OUTDIR/private_key.pem", self.text)
        self.assertIn("$OUTDIR/public_key.pem", self.text)

    def test_fails_closed_and_shows_diagnostics(self):
        self.assertIn("set -euo pipefail", self.text)
        self.assertIn("umask 077", self.text)
        # 실패 출력이 set -e 에 삼켜지지 않아야 한다.
        self.assertIn('if ! OUTPUT="$(', self.text)

    def test_uses_pinned_digest_not_tag(self):
        self.assertIn("platform_digests", self.text)
        self.assertIn('IMAGE="docker.io/matrixdotorg/sygnal@${DIGEST}"', self.text)


class SygnalSecretHygieneTest(unittest.TestCase):
    """공개 저장소다 — 실제 도메인·이메일·키·터널 ID가 들어가면 안 된다."""

    FILES = ("README.md", "sygnal.pins.json", "sygnal.yaml.example",
             "sygnal.service", "gen-vapid-key.sh", "cloudflare-ingress.example.json")

    def test_no_real_hosts_or_secrets(self):
        forbidden = re.compile(
            r"seoyoon-family\.com"
            r"|BEGIN [A-Z ]*PRIVATE KEY"
            r"|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"  # 터널 UUID
        )
        for name in self.FILES:
            text = (PKG / name).read_text(encoding="utf-8")
            self.assertIsNone(forbidden.search(text), f"{name}: 실제 식별자/비밀값으로 보이는 내용")

    def test_examples_use_placeholder_domains(self):
        ingress = (PKG / "cloudflare-ingress.example.json").read_text(encoding="utf-8")
        self.assertIn("<tunnel-id>", ingress)
        self.assertIn("example.com", ingress)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
