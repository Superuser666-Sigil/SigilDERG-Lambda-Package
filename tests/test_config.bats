#!/usr/bin/env bats
# tests/test_config.bats
#
# Tests for eval_setup_config.sh
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 2.0.0

setup() {
    # Load test helpers
    load 'conftest.bash'
}

@test "PYTHON_VERSION has default value" {
    unset PYTHON_VERSION
    source "$PROJECT_ROOT/eval_setup_config.sh"
    [ "$PYTHON_VERSION" = "3.12.11" ]
}

@test "PYTHON_VERSION can be overridden" {
    export PYTHON_VERSION="3.11.0"
    source "$PROJECT_ROOT/eval_setup_config.sh"
    [ "$PYTHON_VERSION" = "3.11.0" ]
}

@test "BASE_MODEL has default value" {
    unset BASE_MODEL
    source "$PROJECT_ROOT/eval_setup_config.sh"
    [ "$BASE_MODEL" = "meta-llama/Meta-Llama-3.1-8B-Instruct" ]
}

@test "SANDBOX_MODE defaults to firejail" {
    unset SANDBOX_MODE
    source "$PROJECT_ROOT/eval_setup_config.sh"
    [ "$SANDBOX_MODE" = "firejail" ]
}

@test "NUM_SAMPLES defaults to 100" {
    unset NUM_SAMPLES
    source "$PROJECT_ROOT/eval_setup_config.sh"
    [ "$NUM_SAMPLES" = "100" ]
}

@test "K_VALUES defaults to 1,10,100" {
    unset K_VALUES
    source "$PROJECT_ROOT/eval_setup_config.sh"
    [ "$K_VALUES" = "1,10,100" ]
}

@test "SKIP_ENV_CHECK defaults to 0" {
    unset SKIP_ENV_CHECK
    source "$PROJECT_ROOT/eval_setup_config.sh"
    [ "$SKIP_ENV_CHECK" = "0" ]
}

@test "NONINTERACTIVE defaults to 0" {
    unset NONINTERACTIVE
    source "$PROJECT_ROOT/eval_setup_config.sh"
    [ "$NONINTERACTIVE" = "0" ]
}

@test "color variables are defined" {
    source "$PROJECT_ROOT/eval_setup_config.sh"
    [ -n "$RED" ]
    [ -n "$GREEN" ]
    [ -n "$YELLOW" ]
    [ -n "$BLUE" ]
    [ -n "$NC" ]
}

