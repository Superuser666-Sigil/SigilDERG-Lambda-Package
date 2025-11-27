#!/bin/bash
# lib/logging.sh
#
# Logging utilities for evaluation setup.
#
# Provides colored logging functions: log_info, log_success, log_warning, log_error
# and error_exit for consistent output across all modules. All logging functions
# use colors defined in eval_setup_config.sh for visual clarity.
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 1.3.7

# Source config for colors (if not already sourced)
if [ -z "${RED:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [ -f "$SCRIPT_DIR/eval_setup_config.sh" ]; then
        source "$SCRIPT_DIR/eval_setup_config.sh"
    fi
fi

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Error handler
error_exit() {
    log_error "$1"
    log_error "Setup failed. Check the logs above for details."
    exit 1
}

