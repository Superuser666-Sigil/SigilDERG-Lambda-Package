#!/bin/bash
# lib/rust.sh
#
# Rust toolchain installation.
#
# Installs Rust via rustup and verifies installation. REQUIRED for evaluation as
# human-eval-rust needs rustc and cargo to compile and execute Rust code completions.
# Sources ~/.cargo/env to make rustc available in PATH.
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 1.3.5

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/eval_setup_config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/environment.sh"

# Install Rust toolchain (REQUIRED - evaluation cannot proceed without Rust)
install_rust() {
    log_info "Checking Rust toolchain (REQUIRED for evaluation)..."
    
    # Source cargo env if it exists (in case Rust was installed previously)
    if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env" 2>/dev/null || true
    fi
    
    if command_exists rustc; then
        RUST_VERSION=$(rustc --version)
        log_success "Rust already installed: $RUST_VERSION"
        return 0
    else
        log_info "Installing Rust toolchain..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
            || error_exit "Failed to install Rust (REQUIRED for evaluation)"
        
        # Source cargo environment (use dot notation as requested)
        . "$HOME/.cargo/env" || error_exit "Failed to source cargo environment"
        
        # Verify Rust is now available
        if command_exists rustc; then
            RUST_VERSION=$(rustc --version)
            log_success "Rust toolchain installed: $RUST_VERSION"
            return 0
        else
            error_exit "Rust installed but rustc not found in PATH. Evaluation cannot proceed."
        fi
    fi
}

