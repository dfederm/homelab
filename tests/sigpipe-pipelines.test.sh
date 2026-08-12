#!/bin/bash

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() {
    echo "  PASS: $1"
}

fail() {
    echo "  FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

expect_sigpipe() {
    local description="$1"
    shift
    local status

    (set -o pipefail; "$@") 2>/dev/null
    status=$?
    if [ "$status" -eq 141 ]; then
        pass "$description"
    else
        fail "$description"
    fi
}

large_output() {
    printf 'match iface0\n'
    seq 1 200000
}

captured=$(large_output)

echo "=== original early-exit pipelines reproduce the SIGPIPE failure ==="
expect_sigpipe "grep -q closes an active producer" \
    bash -c 'set -o pipefail; { printf "match iface0\n"; seq 1 200000; } | grep -q "^match"'
expect_sigpipe "grep -m1 closes an active producer" \
    bash -c 'set -o pipefail; { printf "match iface0\n"; seq 1 200000; } | grep -m1 "^match" >/dev/null'
expect_sigpipe "awk exit closes an active producer" \
    bash -c "set -o pipefail; { printf 'match iface0\n'; seq 1 200000; } | awk '{ print \$2; exit }' >/dev/null"
expect_sigpipe "head closes an active producer" \
    bash -c 'set -o pipefail; { printf "match iface0\n"; seq 1 200000; } | head -n1 >/dev/null'

echo
echo "=== capture-then-consume forms preserve successful results ==="
if grep -q '^match' <<< "$captured"; then
    pass "grep -q finds an early match after capture"
else
    fail "grep -q finds an early match after capture"
fi

if grep -m1 '^match' <<< "$captured" >/dev/null; then
    pass "grep -m1 finds an early match after capture"
else
    fail "grep -m1 finds an early match after capture"
fi

first_iface=$(awk '{ print $2; exit }' <<< "$captured")
if [ "$first_iface" = "iface0" ]; then
    pass "awk exit returns the first result after capture"
else
    fail "awk exit returns the first result after capture"
fi

first_five=$(awk 'NR <= 5 { print }' <<< "$captured" | tr '\n' ' ')
if [ "$first_five" = "match iface0 1 2 3 4 " ]; then
    pass "bounded awk replaces head without closing its input early"
else
    fail "bounded awk replaces head without closing its input early"
fi

if grep -q '^absent$' <<< "$captured"; then
    fail "capture-then-match rejects an absent value"
else
    pass "capture-then-match rejects an absent value"
fi

echo
echo "=== shipped bounded-version helpers consume the complete captured input ==="
mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/apt-cache" <<'EOF'
#!/bin/bash
for i in $(seq 1 200000); do
    printf 'package | version-%06d | repository\n' "$i"
done
EOF
chmod +x "$TEST_ROOT/bin/apt-cache"
export PATH="$TEST_ROOT/bin:$PATH"

extract_function() {
    awk -v name="$2" '$0 ~ "^" name "\\(\\) \\{", /^\}/' "$1"
}

expected_versions="version-000001 version-000002 version-000003 version-000004 version-000005 "
for module in \
    "$REPO_DIR/scripts/setup/modules/configure-nvidia-driver.sh" \
    "$REPO_DIR/scripts/setup/modules/install-nvidia-container-toolkit.sh"; do
    eval "$(extract_function "$module" apt_offered_versions)"
    offered_versions=$(apt_offered_versions package)
    if [ "$offered_versions" = "$expected_versions" ]; then
        pass "$(basename "$module") returns the first five offered versions"
    else
        fail "$(basename "$module") returns the first five offered versions"
    fi
done

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "sigpipe pipeline tests passed"
else
    echo "$FAILURES test(s) failed"
fi

exit "$FAILURES"
