#!/bin/bash
# 이 Mac 의 Apple Development 인증서에서 팀 ID(인증서 Subject 의 OU)를 뽑아 나열한다.
# 괄호 안의 값은 팀 ID 가 아니라 개인 ID 라서, 인증서를 직접 열어야 한다.
set -euo pipefail
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
security find-certificate -a -c "Apple Develop" -p 2>/dev/null > "$tmp"
python3 - "$tmp" <<'PY'
import re, subprocess, sys
data = open(sys.argv[1]).read()
blocks = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----\n", data, re.S)
seen = set()
for b in blocks:
    out = subprocess.run(["openssl", "x509", "-noout", "-subject"],
                         input=b, capture_output=True, text=True).stdout
    ou = re.search(r"OU\s*=\s*([A-Z0-9]+)", out)
    cn = re.search(r"CN\s*=\s*([^,]+)", out)
    if not ou:
        continue
    key = (ou.group(1), cn.group(1) if cn else "")
    if key in seen:
        continue
    seen.add(key)
    print(f"  {ou.group(1)}   {key[1].strip()}")
if not seen:
    print("  (Apple Development 인증서가 없습니다. Xcode > Settings > Accounts 에서 로그인하세요.)")
PY
