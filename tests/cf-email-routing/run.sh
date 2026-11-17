#!/usr/bin/env bash
# Integration test for scripts/cf-email-routing.sh against an in-memory mock of
# the Cloudflare API (mock_cf.py). Asserts: plan is read-only, apply converges,
# a second plan reports no changes, foreign MX zones are refused.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
port="${PORT:-18787}"

python3 -I "$here/mock_cf.py" "$port" &
mock_pid=$!
trap 'kill $mock_pid 2>/dev/null || true' EXIT
for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.1; done

export CF_API="http://127.0.0.1:$port/client/v4" CLOUDFLARE_API_TOKEN=test-token CLOUDFLARE_ACCOUNT_ID=acct1
cfg="$root/deploy/cloudflare/email-routing.conf.example"
run() { "$root/scripts/cf-email-routing.sh" "$@" 2>&1 || true; }
pass=0
check() { if grep -qE -- "$2" <<<"$3"; then pass=$((pass + 1)); echo "ok   - $1"; else echo "FAIL - $1"; printf '     | %s\n' "${3//$'\n'/$'\n'     | }"; exit 1; fi; }
refute() { if grep -qE -- "$2" <<<"$3"; then echo "FAIL - $1"; printf '     | %s\n' "${3//$'\n'/$'\n'     | }"; exit 1; else pass=$((pass + 1)); echo "ok   - $1"; fi; }

out="$(run plan "$cfg")"
check  "plan proposes enabling example.org"       '\+ enable Email Routing'                      "$out"
check  "plan proposes updating drifted rule"      '~ support@example.com -> worker'               "$out"
check  "plan refuses zone with foreign MX"        'example.net has non-Cloudflare MX'             "$out"
check  "plan reports unmanaged rule"              'unmanaged: legacy@example.com'                 "$out"
check  "plan suggests merged SPF"                 'include:_spf.mx.cloudflare.net include:spf.brevo.com' "$out"
out2="$(run plan "$cfg")"
check  "plan is read-only (same result twice)"    '10 change\(s\) planned'                        "$out2"

out="$(run apply "$cfg")"
check  "apply enables zone"                       '✓ enabled'                                     "$out"
check  "apply creates rules"                      '✓ created reply@example.com'                   "$out"
check  "apply sets catch-all"                     '✓ catch-all set'                               "$out"

out="$(run plan "$cfg")"
check  "second plan has no changes"               'no changes'                                    "$out"
refute "second plan proposes nothing"             '^  [+~] '                                      "$out"
check  "legacy rule untouched"                    'unmanaged: legacy@example.com'                 "$out"

out="$(CLOUDFLARE_API_TOKEN=wrong run plan "$cfg")"
check  "bad token surfaces API error"             'Authentication error'                          "$out"

printf 'example.com support@other.com worker x\n' > "${TMPDIR:-/tmp}/bad.conf"
out="$(run plan "${TMPDIR:-/tmp}/bad.conf")"
check  "config validation catches wrong zone"     'is not in zone example.com'                    "$out"

echo "all $pass checks passed"
