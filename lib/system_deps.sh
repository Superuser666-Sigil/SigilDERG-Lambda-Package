#!/bin/bash
# lib/system_deps.sh
#
# System dependency installation.
#
# Installs required system packages for Ubuntu 22.04 including build tools,
# libraries, and utilities needed for Python compilation, Rust toolchain, and tmux.
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 1.3.8

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/eval_setup_config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/environment.sh"

# Install system dependencies (Ubuntu 22.04)
install_system_deps() {
    log_info "Installing system dependencies for Ubuntu 22.04..."
    
    if command_exists apt-get; then
        # Note: User handles apt update/upgrade separately
        sudo apt-get install -y \
            git build-essential wget curl tmux \
            pkg-config libssl-dev libffi-dev \
            libbz2-dev libreadline-dev libsqlite3-dev \
            zlib1g-dev liblzma-dev \
            || log_warning "Some system packages may not have installed correctly"
        log_success "System dependencies installed"
    else
        log_warning "apt-get not found. Please install system dependencies manually."
    fi
}

