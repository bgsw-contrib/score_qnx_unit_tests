#!/bin/bash
# *******************************************************************************
# Copyright (c) 2026 Contributors to the Eclipse Foundation
#
# See the NOTICE file(s) distributed with this work for additional
# information regarding copyright ownership.
#
# This program and the accompanying materials are made available under the
# terms of the Apache License Version 2.0 which is available at
# https://www.apache.org/licenses/LICENSE-2.0
#
# SPDX-License-Identifier: Apache-2.0
# *******************************************************************************

set -euo pipefail

source "$1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file_content() {
    local description="$1" expected="$2" path="$3" actual
    actual="$(<"$path")"
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' \
            "$description" "$expected" "$actual" >&2
        exit 1
    fi
}

# Round-trip values with trailing newlines, shell metacharacters, helper-name
# collisions, empty strings, and the old unset-marker text.
requested_names=(
    qnx_forward_names
    qnx_forward_values
    qnx_forward_is_set
    qnx_forward_index
    qnx_forward_name
    forward_names
    forward_values
    forward_is_set
    forward_name
    forward_index
    names
    values
    set_flags
    requested
    index
    _qnx_common_name
    TRAILING_NEWLINES
    QUOTED_VALUE
    EMPTY_VALUE
    SENTINEL_VALUE
)
qnx_forward_names="caller names value"
qnx_forward_values=$'final line\n\n'
qnx_forward_is_set="__QNX_FORWARD_ENV_UNSET__"
qnx_forward_index="caller index"
qnx_forward_name="requested name"
forward_names="wrapper names"
forward_values="wrapper values"
forward_is_set="wrapper set"
forward_name="wrapper name"
forward_index="wrapper index"
names="caller names"
values="caller values"
set_flags="caller flags"
requested="caller requested"
index="index value"
_qnx_common_name="caller private-name value"
TRAILING_NEWLINES=$'value\n\n\n'
QUOTED_VALUE="single' quote; \$(false) \\\\ \$HOME"
EMPTY_VALUE=""
SENTINEL_VALUE="__QNX_FORWARD_ENV_UNSET__"
QNX_FORWARD_ENV="$(IFS=,; printf '%s' "${requested_names[*]}")"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
env_fragment="$scratch/cc_test_qnx_env.sh"
qemu_write_forwarded_env "$scratch"

bash -c '
    set -euo pipefail
    source "$1"
    assert_equal() {
        local name="$1" expected="$2" actual
        [[ -v "$name" ]] || { echo "FAIL: $name was not set" >&2; exit 1; }
        actual="${!name}"
        [[ "$actual" == "$expected" ]] || {
            printf "FAIL: %s expected %q, got %q\\n" "$name" "$expected" "$actual" >&2
            exit 1
        }
    }
    assert_equal qnx_forward_names "caller names value"
    assert_equal qnx_forward_values $'"'"'final line\n\n'"'"'
    assert_equal qnx_forward_is_set "__QNX_FORWARD_ENV_UNSET__"
    assert_equal qnx_forward_index "caller index"
    assert_equal qnx_forward_name "requested name"
    assert_equal forward_names "wrapper names"
    assert_equal forward_values "wrapper values"
    assert_equal forward_is_set "wrapper set"
    assert_equal forward_name "wrapper name"
    assert_equal forward_index "wrapper index"
    assert_equal names "caller names"
    assert_equal values "caller values"
    assert_equal set_flags "caller flags"
    assert_equal requested "caller requested"
    assert_equal index "index value"
    assert_equal _qnx_common_name "caller private-name value"
    assert_equal TRAILING_NEWLINES $'"'"'value\n\n\n'"'"'
    assert_equal QUOTED_VALUE "single'"'"' quote; \$(false) \\\\ \$HOME"
    assert_equal EMPTY_VALUE ""
    assert_equal SENTINEL_VALUE "__QNX_FORWARD_ENV_UNSET__"
    [[ ! ${UNSET_FORWARD_VALUE+x} ]]
' _ "$env_fragment" || fail "forwarded values did not round-trip"

# Empty selection removes any stale fragment without failing.
QNX_FORWARD_ENV=""
qemu_write_forwarded_env "$scratch"
[[ ! -e "$env_fragment" ]] || fail "empty selection should remove the env fragment"

# Unset entries between set entries must not shift the later value.
FIRST_VALUE="first"
LAST_VALUE="last"
unset MIDDLE_UNSET
QNX_FORWARD_ENV="FIRST_VALUE,MIDDLE_UNSET,LAST_VALUE"
qemu_write_forwarded_env "$scratch"
bash -c '
    set -euo pipefail
    source "$1"
    [[ "$FIRST_VALUE" == first && "$LAST_VALUE" == last ]]
    [[ ! ${MIDDLE_UNSET+x} ]]
' _ "$env_fragment" || fail "unset entry shifted a later forwarded value"

# Invalid identifiers must fail clearly before writing any partial fragment.
QNX_FORWARD_ENV="VALID_NAME,INVALID-NAME"
if qemu_write_forwarded_env "$scratch" 2>"$scratch/error.log"; then
    fail "invalid variable name should be rejected"
fi
[[ ! -s "$env_fragment" ]] || fail "invalid name left a partial env fragment"
grep -q 'Invalid environment variable name' "$scratch/error.log" || \
    fail "invalid variable name did not produce a clear diagnostic"

# A caller-provided FSDEV_PATH is reused: stale staged entries are removed,
# unrelated caller data survives, and cleanup does not remove the caller's path.
reuse_dir="$scratch/reused"
mkdir -p "$reuse_dir/test_results" "$reuse_dir/libs" "$reuse_dir/unrelated"
printf stale > "$reuse_dir/test_results/stale"
printf stale > "$reuse_dir/libs/stale"
printf preserve > "$reuse_dir/unrelated/keep"
FSDEV_PATH="$reuse_dir"
unset FSDEV_PATH_CREATED || true
qemu_setup_fsdev
[[ ! -e "$reuse_dir/test_results" ]] || fail "setup retained stale test_results"
[[ ! -e "$reuse_dir/libs" ]] || fail "setup retained stale libs"
[[ -f "$reuse_dir/unrelated/keep" ]] || fail "setup deleted unrelated caller data"
qemu_cleanup_fsdev
[[ -f "$reuse_dir/unrelated/keep" ]] || fail "cleanup deleted caller-owned FSDEV_PATH"

# Without a caller path, setup creates a temporary path which cleanup removes.
unset FSDEV_PATH FSDEV_PATH_CREATED || true
qemu_setup_fsdev
created_dir="$FSDEV_PATH"
[[ -d "$created_dir" && "${FSDEV_PATH_CREATED:-0}" == 1 ]] || \
    fail "setup did not create and mark a temporary FSDEV_PATH"
printf keep > "$created_dir/payload"
qemu_cleanup_fsdev
[[ ! -e "$created_dir" ]] || fail "cleanup retained helper-created FSDEV_PATH"

# Result extraction runs in a subprocess since it exits with the test status.
result_dir="$scratch/results"
mkdir -p "$result_dir/test_results" "$scratch/outputs"
printf '<testsuite/>\n' > "$result_dir/test_results/test.xml"
printf 'captured output\n' > "$result_dir/test_results/test_output.log"
printf '7\n' > "$result_dir/test_results/returncode.log"
XML_OUTPUT_FILE="$scratch/outputs/test.xml"
TEST_UNDECLARED_OUTPUTS_DIR="$scratch/outputs"
COVERAGE_DIR=""
set +e
bash -c '
    source "$1"
    XML_OUTPUT_FILE="$3"
    TEST_UNDECLARED_OUTPUTS_DIR="$4"
    COVERAGE_DIR=""
    qemu_extract_results "$2"
' _ "$1" "$result_dir" "$XML_OUTPUT_FILE" "$TEST_UNDECLARED_OUTPUTS_DIR" >"$scratch/extract.stdout" 2>"$scratch/extract.stderr"
extract_rc=$?
set -e
[[ "$extract_rc" == 7 ]] || fail "extract returned $extract_rc, expected status 7"
[[ -f "$XML_OUTPUT_FILE" ]] || fail "extract did not copy XML results"
cmp -s <(printf '<testsuite/>\n') "$XML_OUTPUT_FILE" || fail "extracted XML was not copied exactly"
assert_file_content "captured output" 'captured output' "$scratch/extract.stdout"
printf 'binary\001\rtext\n' > "$result_dir/test_results/test_output.log"
printf '7\n' > "$result_dir/test_results/returncode.log"
set +e
bash -c '
    source "$1"
    XML_OUTPUT_FILE="$3"
    TEST_UNDECLARED_OUTPUTS_DIR="$4"
    COVERAGE_DIR=""
    qemu_extract_results "$2"
' _ "$1" "$result_dir" "$XML_OUTPUT_FILE" "$TEST_UNDECLARED_OUTPUTS_DIR" >"$scratch/sanitized.stdout" 2>"$scratch/sanitized.stderr"
sanitized_rc=$?
set -e
[[ "$sanitized_rc" == 7 ]] || fail "sanitized-output run returned $sanitized_rc"
assert_file_content "sanitized captured output" 'binarytext' "$scratch/sanitized.stdout"

# Missing returncode is an infrastructure failure, never a false pass.
rm "$result_dir/test_results/returncode.log"
set +e
bash -c '
    source "$1"
    XML_OUTPUT_FILE="$3"
    TEST_UNDECLARED_OUTPUTS_DIR="$4"
    COVERAGE_DIR=""
    qemu_extract_results "$2"
' _ "$1" "$result_dir" "$XML_OUTPUT_FILE" "$TEST_UNDECLARED_OUTPUTS_DIR" >"$scratch/missing.stdout" 2>"$scratch/missing.stderr"
missing_rc=$?
set -e
[[ "$missing_rc" == 1 ]] || fail "missing returncode produced status $missing_rc"
grep -q 'Test return code log not found' "$scratch/missing.stderr" || \
    fail "missing returncode did not emit an error"

# Empty and malformed return codes must also fail, not become success.
printf '\n' > "$result_dir/test_results/returncode.log"
set +e
bash -c '
    source "$1"
    XML_OUTPUT_FILE="$3"
    TEST_UNDECLARED_OUTPUTS_DIR="$4"
    COVERAGE_DIR=""
    qemu_extract_results "$2"
' _ "$1" "$result_dir" "$XML_OUTPUT_FILE" "$TEST_UNDECLARED_OUTPUTS_DIR" >"$scratch/empty.stdout" 2>"$scratch/empty.stderr"
empty_rc=$?
set -e
[[ "$empty_rc" == 1 ]] || fail "empty returncode produced status $empty_rc"
printf 'not-a-number\n' > "$result_dir/test_results/returncode.log"
set +e
bash -c '
    source "$1"
    XML_OUTPUT_FILE="$3"
    TEST_UNDECLARED_OUTPUTS_DIR="$4"
    COVERAGE_DIR=""
    qemu_extract_results "$2"
' _ "$1" "$result_dir" "$XML_OUTPUT_FILE" "$TEST_UNDECLARED_OUTPUTS_DIR" >"$scratch/malformed.stdout" 2>"$scratch/malformed.stderr"
malformed_rc=$?
set -e
[[ "$malformed_rc" == 2 ]] || fail "malformed returncode produced status $malformed_rc, expected shell error 2"

# Coverage archives are extracted into Bazel's undeclared-output directory and,
# when requested, the coverage directory as well.
mkdir -p "$scratch/coverage_payload"
printf 'coverage data\n' > "$scratch/coverage_payload/coverage.dat"
tar -czf "$result_dir/test_results/coverage.tar.gz" -C "$scratch/coverage_payload" coverage.dat
mkdir -p "$scratch/coverage-output" "$scratch/coverage-dir"
printf '0\n' > "$result_dir/test_results/returncode.log"
set +e
bash -c '
    source "$1"
    XML_OUTPUT_FILE="$3"
    TEST_UNDECLARED_OUTPUTS_DIR="$4"
    COVERAGE_DIR="$5"
    qemu_extract_results "$2"
' _ "$1" "$result_dir" "$XML_OUTPUT_FILE" "$scratch/coverage-output" "$scratch/coverage-dir" >"$scratch/coverage.stdout" 2>"$scratch/coverage.stderr"
coverage_rc=$?
set -e
[[ "$coverage_rc" == 0 ]] || fail "coverage extraction returned $coverage_rc"
assert_file_content "undeclared coverage output" 'coverage data' "$scratch/coverage-output/coverage.dat"
assert_file_content "coverage directory output" 'coverage data' "$scratch/coverage-dir/coverage.dat"

# Acceleration setup can be tested without QEMU/KVM by putting stub binaries
# first on PATH and stubbing uname to cover native and cross-architecture cases.
mock_bin="$scratch/mock-bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/qemu-system-x86_64" <<'EOF'
#!/bin/bash
[[ "${1:-}" == "--version" ]] && echo 'QEMU emulator version 8.2.2'
EOF
cat > "$mock_bin/qemu-system-aarch64" <<'EOF'
#!/bin/bash
[[ "${1:-}" == "--version" ]] && echo 'QEMU emulator version 8.2.2'
EOF
chmod +x "$mock_bin/qemu-system-x86_64" "$mock_bin/qemu-system-aarch64"
PATH="$mock_bin:$PATH"

# Native aarch64 defaults to virt + max and honors an explicit CPU override.
PATH="$mock_bin:$PATH" bash -c '
    source "$1"
    uname() { printf aarch64; }
    qemu_setup_accel aarch64 >/dev/null
    [[ "$ACCEL" == "-machine virt -cpu max" ]] || exit 1
    QEMU_CPU=cortex-a72
    qemu_setup_accel aarch64 >/dev/null
    [[ "$ACCEL" == "-machine virt -cpu cortex-a72" ]] || exit 1
' _ "$1" || fail "aarch64 acceleration setup/default/override failed"

# x86 guest on a non-x86 host uses TCG/max; explicit CPU override is preserved.
PATH="$mock_bin:$PATH" bash -c '
    source "$1"
    uname() { printf aarch64; }
    qemu_setup_accel x86_64 >/dev/null
    [[ "$ACCEL" == "-cpu max" && "$QEMU_CPU" == max ]] || exit 1
    QEMU_CPU=Skylake-Client
    qemu_setup_accel x86_64 >/dev/null
    [[ "$ACCEL" == "-cpu Skylake-Client" ]] || exit 1
' _ "$1" || fail "cross-architecture x86 acceleration setup failed"

# Host architecture other than x86_64 avoids depending on the real /dev/kvm
# and CPU vendor while checking QEMU presence/version handling.
PATH="$mock_bin:$PATH" bash -c '
    source "$1"
    qemu_check qemu-system-x86_64
    qemu_check qemu-system-aarch64
' _ "$1" >"$scratch/qemu-check.stdout" || fail "QEMU binary checks failed"
grep -q 'qemu-system-x86_64 version 8.2.2 detected' "$scratch/qemu-check.stdout" || \
    fail "QEMU version was not detected"

# Unknown guest architecture is a clear fatal error.
set +e
bash -c 'source "$1"; qemu_setup_accel mips' _ "$1" >"$scratch/bad-arch.stdout" 2>"$scratch/bad-arch.stderr"
bad_arch_rc=$?
set -e
[[ "$bad_arch_rc" == 1 ]] || fail "unknown guest architecture returned $bad_arch_rc"
grep -q 'unknown guest arch' "$scratch/bad-arch.stderr" || \
    fail "unknown guest architecture did not explain the error"

echo "PASS: qemu_common helpers"
