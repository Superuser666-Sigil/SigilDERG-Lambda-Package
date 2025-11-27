#!/bin/bash
# lib/environment.sh
#
# Environment validation and utility functions.
#
# Provides environment checks (OS, GPU) and utility functions like command_exists
# for validating the system before proceeding with installation. Validates Ubuntu 22.04
# and NVIDIA H100 GPU requirements, with optional override via SKIP_ENV_CHECK.
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 1.3.7

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/eval_setup_config.sh"
source "$SCRIPT_DIR/lib/logging.sh"

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Environment sanity checks for reproducibility (Ubuntu 22.04 + H100)
check_environment() {
    # OS check
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "${NAME:-}" != "Ubuntu" || "${VERSION_ID:-}" != "22.04" ]]; then
            log_error "This script is validated only on Ubuntu 22.04. Detected: ${PRETTY_NAME:-unknown}"
            error_exit "Unsupported OS for reproducible Lambda eval environment (set SKIP_ENV_CHECK=1 to override)"
        fi
    else
        log_error "/etc/os-release not found; unable to verify OS."
        error_exit "Unsupported OS for reproducible Lambda eval environment (set SKIP_ENV_CHECK=1 to override)"
    fi

    # GPU check
    if ! command_exists nvidia-smi; then
        log_error "nvidia-smi not found. A CUDA-capable GPU (H100) is required for this environment."
        error_exit "CUDA GPU not detected"
    fi

    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1 || echo "")
    if [[ "$GPU_NAME" != *"H100"* ]]; then
        log_error "This script is validated for NVIDIA H100 only. Detected GPU: ${GPU_NAME:-unknown}"
        error_exit "Unsupported GPU for reproducible Lambda eval environment (set SKIP_ENV_CHECK=1 to override)"
    fi

    log_success "Environment check passed: Ubuntu 22.04 + H100 detected"
}

