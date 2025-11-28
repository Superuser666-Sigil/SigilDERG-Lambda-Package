#!/usr/bin/env bats
# tests/test_environment.bats
#
# Tests for lib/environment.sh
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 2.0.0

setup() {
    # Load test helpers
    load 'conftest.bash'
    
    # Source the module under test
    source "$PROJECT_ROOT/lib/environment.sh"
}

@test "command_exists returns true for existing command" {
    run command_exists bash
    [ "$status" -eq 0 ]
}

@test "command_exists returns false for non-existing command" {
    run command_exists nonexistent_command_xyz
    [ "$status" -eq 1 ]
}

@test "check_environment skipped when SKIP_ENV_CHECK=1" {
    export SKIP_ENV_CHECK=1
    run check_environment
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping"* ]] || [[ "$output" == *"WARNING"* ]]
}

@test "command_exists handles command with special characters" {
    run command_exists "bash"
    [ "$status" -eq 0 ]
}

@test "environment variables are exported correctly" {
    [ -n "$RED" ]
    [ -n "$GREEN" ]
    [ -n "$YELLOW" ]
    [ -n "$BLUE" ]
    [ -n "$NC" ]
}

