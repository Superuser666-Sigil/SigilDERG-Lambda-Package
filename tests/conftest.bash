#!/bin/bash
# tests/conftest.bash
#
# Shared test fixtures and helpers for bats tests.
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 2.0.0

# Get the project root directory
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source the config and libraries
source "$PROJECT_ROOT/eval_setup_config.sh"
source "$PROJECT_ROOT/lib/logging.sh"

# Test helper: create a temporary directory
create_temp_dir() {
    mktemp -d
}

# Test helper: cleanup temporary directory
cleanup_temp_dir() {
    local dir="$1"
    if [[ -d "$dir" ]] && [[ "$dir" == /tmp/* ]]; then
        rm -rf "$dir"
    fi
}

# Test helper: mock command_exists
mock_command_exists() {
    local cmd="$1"
    local exists="$2"
    
    if [[ "$exists" == "true" ]]; then
        eval "function $cmd() { return 0; }"
    else
        eval "function $cmd() { return 1; }"
    fi
}

# Test helper: capture output
capture_output() {
    local -n out="$1"
    local -n err="$2"
    shift 2
    
    local temp_stdout=$(mktemp)
    local temp_stderr=$(mktemp)
    
    "$@" > "$temp_stdout" 2> "$temp_stderr"
    local exit_code=$?
    
    out=$(cat "$temp_stdout")
    err=$(cat "$temp_stderr")
    
    rm -f "$temp_stdout" "$temp_stderr"
    
    return $exit_code
}

# Test helper: assert string contains
assert_contains() {
    local haystack="$1"
    local needle="$2"
    
    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        echo "Expected '$haystack' to contain '$needle'"
        return 1
    fi
}

# Test helper: assert string does not contain
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    
    if [[ "$haystack" != *"$needle"* ]]; then
        return 0
    else
        echo "Expected '$haystack' to NOT contain '$needle'"
        return 1
    fi
}

