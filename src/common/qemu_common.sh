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

# Shared QEMU launch helpers sourced by x86_64 and aarch64 test scripts.

# Verify the QEMU binary is on PATH and log the detected version.
qemu_check() {
    local binary="$1"
    command -v "${binary}" >/dev/null 2>&1 || {
        echo "ERROR: ${binary} not found. Install: sudo apt-get install -y qemu-system" >&2
        exit 1
    }
    local version
    version="$("${binary}" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" || true
    if [ -n "${version}" ]; then
        echo "${binary} version ${version} detected"
    fi
}

# Set ACCEL, QEMU_CPU, and DISABLE_KVM for the given guest architecture.
# KVM and host-vendor CPU matching only apply when the host can run that guest
# natively (host arch == guest arch); a cross-arch host is always TCG, so the
# host's own CPU vendor is irrelevant and a generic model is used instead.
# Usage: qemu_setup_accel <x86_64|aarch64>
qemu_setup_accel() {
    local guest_arch="$1"
    local host_arch
    host_arch="$(uname -m)"

    case "${guest_arch}" in
        x86_64)
            qemu_check qemu-system-x86_64
            if [[ "${host_arch}" == "x86_64" ]]; then
                DISABLE_KVM="${DISABLE_KVM:-0}"
                if [[ -e /dev/kvm && -r /dev/kvm ]] && [[ "${DISABLE_KVM}" == 0 ]]; then
                    case "$(grep -m1 '^vendor_id' /proc/cpuinfo 2>/dev/null)" in
                        *AuthenticAMD*) QEMU_CPU="${QEMU_CPU:-EPYC-Milan}" ;;
                        *GenuineIntel*) QEMU_CPU="${QEMU_CPU:-Icelake-Server}" ;;
                        *) QEMU_CPU="${QEMU_CPU:-host}" ;;
                    esac
                    echo "KVM supported! CPU model: ${QEMU_CPU}"
                    ACCEL="-enable-kvm -cpu ${QEMU_CPU}"
                else
                    [[ "${DISABLE_KVM}" != 0 ]] && echo "KVM explicitly disabled!"
                    QEMU_CPU="${QEMU_CPU:-max}"
                    echo "CPU model: ${QEMU_CPU}"
                    ACCEL="-cpu ${QEMU_CPU}"
                fi
            else
                QEMU_CPU="${QEMU_CPU:-max}"
                echo "Cross-arch emulation (host ${host_arch}), no KVM. CPU model: ${QEMU_CPU}"
                ACCEL="-cpu ${QEMU_CPU}"
            fi
            ;;
        aarch64)
            qemu_check qemu-system-aarch64
            QEMU_CPU="${QEMU_CPU:-max}"
            echo "CPU model: ${QEMU_CPU}"
            ACCEL="-machine virt -cpu ${QEMU_CPU}"
            ;;
        *)
            echo "ERROR: qemu_setup_accel: unknown guest arch '${guest_arch}'" >&2
            exit 1
            ;;
    esac
}

# Write selected host variables as shell-escaped exports at
# <fsdev_path>/cc_test_qnx_env.sh, sourced by prepare_test.sh in the guest.
# All caller variables are collected before output handling begins so helper
# assignments cannot shadow caller values through Bash's dynamic scoping.
qemu_write_forwarded_env() {
    local -a qnx_forward_saved_names=() qnx_forward_saved_values=() qnx_forward_saved_set=()
    local qnx_forward_loop_name qnx_forward_loop_index=0

    IFS=, read -r -a qnx_forward_saved_names <<< "${QNX_FORWARD_ENV:-}"

    # Validate requested names before reading values or writing the file.
    for qnx_forward_loop_name in "${qnx_forward_saved_names[@]}"; do
        [[ -n "${qnx_forward_loop_name}" ]] || continue
        if [[ ! "${qnx_forward_loop_name}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
            echo "ERROR: Invalid environment variable name '${qnx_forward_loop_name}' in QNX_FORWARD_ENV" >&2
            rm -f "$1/cc_test_qnx_env.sh"
            return 1
        fi
    done

    # Capture caller values before later loops reuse any variable names.
    for qnx_forward_loop_name in "${qnx_forward_saved_names[@]}"; do
        [[ -n "${qnx_forward_loop_name}" ]] || continue
        if [[ -v "${qnx_forward_loop_name}" ]]; then
            qnx_forward_saved_set+=(1)
            qnx_forward_saved_values+=("${!qnx_forward_loop_name}")
        else
            qnx_forward_saved_set+=(0)
            qnx_forward_saved_values+=("")
        fi
    done

    rm -f "$1/cc_test_qnx_env.sh"
    if ((${#qnx_forward_saved_names[@]} > 0)); then
        : > "$1/cc_test_qnx_env.sh"
        for qnx_forward_loop_name in "${qnx_forward_saved_names[@]}"; do
            [[ -n "${qnx_forward_loop_name}" ]] || continue
            if [[ "${qnx_forward_saved_set[qnx_forward_loop_index]}" == 1 ]]; then
                # printf %q avoids command substitution, preserving trailing newlines.
                printf 'export %s=%q\n' "${qnx_forward_loop_name}" "${qnx_forward_saved_values[qnx_forward_loop_index]}" >> "$1/cc_test_qnx_env.sh"
            fi
            ((qnx_forward_loop_index += 1))
        done
    fi
}

# Create or reuse the virtio-9p shared directory.
qemu_setup_fsdev() {
    if [[ -z "${FSDEV_PATH:-}" ]]; then
        FSDEV_PATH="$(mktemp -d)"
        FSDEV_PATH_CREATED=1
    else
        local entry
        for entry in test_results cc_test_qnx cc_test_qnx.runfiles \
                cc_test_qnx_filters.txt cc_test_qnx_extra_args.sh \
                cc_test_qnx_env.sh libs; do
            rm -rf "${FSDEV_PATH:?}/${entry}"
        done
    fi
    mkdir -p "${FSDEV_PATH}"
}

# Remove the virtio-9p shared directory if we created it.
qemu_cleanup_fsdev() {
    if [[ "${FSDEV_PATH_CREATED:-0}" == "1" ]]; then
        rm -rf "${FSDEV_PATH}"
    fi
}

# Extract test results from the virtio-9p share and exit with the test's code.
qemu_extract_results() {
    local fsdev_path="$1"
    if [ -f "${fsdev_path}/test_results/test.xml" ]; then
        cp "${fsdev_path}/test_results/test.xml" "${XML_OUTPUT_FILE}"
    fi
    if [ -f "${fsdev_path}/test_results/test_output.log" ]; then
        sed 's/[^[:print:]]//g; s/\r//' "${fsdev_path}/test_results/test_output.log"
    fi
    if [ -f "${fsdev_path}/test_results/coverage.tar.gz" ]; then
        tar -xf "${fsdev_path}/test_results/coverage.tar.gz" --no-same-owner --no-same-permissions -C "${TEST_UNDECLARED_OUTPUTS_DIR}"
        if [ -n "${COVERAGE_DIR:-}" ]; then
            tar -xf "${fsdev_path}/test_results/coverage.tar.gz" --no-same-owner --no-same-permissions -C "${COVERAGE_DIR}"
        fi
    fi
    local rc
    if [ -f "${fsdev_path}/test_results/returncode.log" ]; then
        rc="$(cat "${fsdev_path}/test_results/returncode.log")"
    else
        echo "ERROR: Test return code log not found!" >&2
        rc=1
    fi
    exit "${rc:-1}"
}
