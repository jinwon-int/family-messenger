#!/usr/bin/env python3
"""App Store Connect API 로 iOS App Store 프로비저닝 프로필을 만들거나 가져와 .mobileprovision 으로 저장한다 (#271 §11 F, 기기 등록 불필요).

사용: asc_profiles.py --key-path AuthKey.p8 --key-id KID --issuer-id IID --cert-serial SERIAL --out DIR BUNDLE_ID[=PROFILE_NAME] ...
- 프로필 이름 기본값: "hande appstore <bundle_id>". 같은 이름의 ACTIVE 프로필이 있고 지정 인증서를 포함하면 재사용, 아니면 삭제 후 재생성
  (프로필은 비밀이 아니며 App ID 의 capability 변경 뒤에는 재생성해야 entitlement 가 반영된다).
- 출력: DIR/<bundle_id>.mobileprovision, 표준출력에 "bundle_id<TAB>profile_name<TAB>uuid". 키 내용은 절대 출력하지 않는다.
의존: PyJWT, cryptography, requests (러너에서 pip install).
"""
import argparse, base64, json, plistlib, re, sys, time
import jwt, requests
BASE = "https://api.appstoreconnect.apple.com/v1"
def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--key-path", required=True); ap.add_argument("--key-id", required=True); ap.add_argument("--issuer-id", required=True)
    ap.add_argument("--cert-serial", required=True, help="Apple Distribution 인증서 일련번호(hex, 대문자)"); ap.add_argument("--out", required=True); ap.add_argument("bundles", nargs="+")
    a = ap.parse_args()
    key = open(a.key_path).read()
    def tok():
        now = int(time.time()); return jwt.encode({"iss": a.issuer_id, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}, key, algorithm="ES256", headers={"kid": a.key_id, "typ": "JWT"})
    def req(m, path, **kw):
        r = requests.request(m, BASE + path, headers={"Authorization": "Bearer " + tok(), "Content-Type": "application/json"}, timeout=60, **kw)
        if r.status_code >= 400: sys.exit(f"ASC {m} {path} -> HTTP {r.status_code}: {r.text[:500]}")
        return r.json() if r.text else {}
    certs = [c for c in req("GET", "/certificates?limit=200&filter[certificateType]=DISTRIBUTION")["data"] if c["attributes"]["serialNumber"].upper() == a.cert_serial.upper()]
    if not certs: sys.exit("distribution certificate with that serial not found in the team")
    cert_id = certs[0]["id"]
    bundle_ids = {b["attributes"]["identifier"]: b["id"] for b in req("GET", "/bundleIds?limit=200")["data"]}
    for spec in a.bundles:
        bid, _, name = spec.partition("="); name = name or f"hande appstore {bid}"
        if bid not in bundle_ids: sys.exit(f"bundle id not registered: {bid}")
        existing = [p for p in req("GET", f"/profiles?limit=200&filter[profileType]=IOS_APP_STORE&filter[name]={requests.utils.quote(name)}")["data"]]
        prof = None
        for p in existing:
            cids = [c["id"] for c in req("GET", f"/profiles/{p['id']}/certificates")["data"]]
            if p["attributes"]["profileState"] == "ACTIVE" and cert_id in cids: prof = p
            else: req("DELETE", f"/profiles/{p['id']}")
        if prof is None:
            prof = req("POST", "/profiles", data=json.dumps({"data": {"type": "profiles", "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_ids[bid]}}, "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}}))["data"]
        content = base64.b64decode(prof["attributes"]["profileContent"])
        m = re.search(rb"<plist.*?</plist>", content, re.S); uuid = plistlib.loads(m.group(0))["UUID"] if m else "?"
        open(f"{a.out}/{bid}.mobileprovision", "wb").write(content)
        print(f"{bid}\t{prof['attributes']['name']}\t{uuid}")
if __name__ == "__main__": main()
