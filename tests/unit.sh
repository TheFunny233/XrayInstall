#!/bin/ash
set -eu
XRAY_REALITY_SOURCE_ONLY=1
export XRAY_REALITY_SOURCE_ONLY
. "${1:-./xray-reality.sh}"
assert_ok() { "$@" || { echo "FAIL: $*"; exit 1; }; }
assert_bad() { if "$@"; then echo "UNEXPECTED PASS: $*"; exit 1; fi; }
for addr in :: ::1 2001:db8::1 2401:b60:e0ff:18:3fcc:e27a:67fe:10f1; do assert_ok valid_ipv6 "$addr"; done
for addr in '' : ::: 1:2:3 1::2::3 12345::1 1:2:3:4:5:6:7::8 '::1;id' "::'"; do assert_bad valid_ipv6 "$addr"; done
assert_ok valid_ipv4 192.0.2.34
assert_bad valid_ipv4 256.1.2.3
assert_ok valid_port 443
assert_bad valid_port 0083
assert_bad valid_port 65536
assert_bad valid_port '22;id'
assert_ok valid_domain www.amd.com
assert_bad valid_domain 'www.amd.com/path'
assert_bad valid_domain 'evil.com\n'
assert_ok valid_target '[2001:db8::1]:443'
assert_ok valid_target www.amd.com:443
assert_bad valid_target '2001:db8::1:443'
assert_bad valid_target 'example.com:0'

SERVER_IP=2001:db8::1; PUBLIC_PORT=20443; PUBLIC_KEY=public; SERVER_NAME=www.amd.com; SHORT_ID=aabb
uri=$(make_uri test-uuid '手机 1#test')
printf '%s' "$uri" | grep -F '@[2001:db8::1]:20443?' >/dev/null
printf '%s' "$uri" | grep -F '#%E6%89%8B%E6%9C%BA%201%23test' >/dev/null
SERVER_IP=192.0.2.1
make_uri test user | grep -F '@192.0.2.1:20443?' >/dev/null

# Override only the memory input; verify boundary profiles and cgroup-sized budget.
detected=$(effective_memory_mb)
assert_ok valid_uint "$detected" 1 999999
effective_memory_mb() { echo "$TEST_MEM"; }
for pair in '122 38MiB 50 120 64' '128 40MiB 50 120 64' '183 91MiB 75 180 128' '256 128MiB 75 180 128' '512 332MiB 100 180 256' '1024 819MiB 100 300 512'; do
  set -- $pair
  TEST_MEM=$1; auto_profile
  [ "$LIMIT $GC $IDLE $BUFFER" = "$2 $3 $4 $5" ] || die "profile $pair"
done

# Exercise the actual jq policy program, without writing system paths.
TEST_MEM=122; auto_profile
edit_config() { jq "$@" <<'JSON'
{"policy":{},"inbounds":[{"settings":{"clients":[{"id":"keep"}]}}]}
JSON
}
apply_policy | jq -e '.policy.levels["0"].bufferSize==64 and .policy.levels["0"].connIdle==120 and .inbounds[0].settings.clients[0].id=="keep"' >/dev/null
echo 'All unit tests passed'
