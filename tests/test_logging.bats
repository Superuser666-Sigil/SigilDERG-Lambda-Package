#!/usr/bin/env bats
# tests/test_logging.bats
#
# Tests for lib/logging.sh
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 2.0.0

setup() {
    # Load test helpers
    load 'conftest.bash'
    
    # Source the module under test
    source "$PROJECT_ROOT/lib/logging.sh"
}

@test "log_info outputs [INFO] prefix" {
    run log_info "Test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO]"* ]]
    [[ "$output" == *"Test message"* ]]
}

@test "log_success outputs [SUCCESS] prefix" {
    run log_success "Test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SUCCESS]"* ]]
    [[ "$output" == *"Test message"* ]]
}

@test "log_warning outputs [WARNING] prefix" {
    run log_warning "Test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARNING]"* ]]
    [[ "$output" == *"Test message"* ]]
}

@test "log_error outputs [ERROR] prefix" {
    run log_error "Test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ERROR]"* ]]
    [[ "$output" == *"Test message"* ]]
}

@test "error_exit exits with code 1" {
    run bash -c "source '$PROJECT_ROOT/lib/logging.sh'; error_exit 'Fatal error'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[ERROR]"* ]]
    [[ "$output" == *"Fatal error"* ]]
}

@test "log functions handle empty messages" {
    run log_info ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO]"* ]]
}

@test "log functions handle special characters" {
    run log_info "Test with special chars: \$PATH && echo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO]"* ]]
}

