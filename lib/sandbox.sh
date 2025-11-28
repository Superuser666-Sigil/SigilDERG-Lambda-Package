#!/bin/bash
# lib/sandbox.sh
#
# Firejail sandbox verification and fallback handling.
# Optimized for Ubuntu 22.04 LTS.
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 1.4.1

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Ensure these files exist before sourcing to prevent crash
[ -f "$SCRIPT_DIR/eval_setup_config.sh" ] && source "$SCRIPT_DIR/eval_setup_config.sh"
[ -f "$SCRIPT_DIR/lib/logging.sh" ] && source "$SCRIPT_DIR/lib/logging.sh" || { echo "CRITICAL: logging.sh not found"; exit 1; }
[ -f "$SCRIPT_DIR/lib/environment.sh" ] && source "$SCRIPT_DIR/lib/environment.sh"

# ----------------------------------------------------------------------
# Install Firejail
# ----------------------------------------------------------------------
install_firejail() {
    FIREJAIL_INSTALL_ERROR=""
    log_info "Installing Firejail..."

    if ! command_exists apt-get; then
        FIREJAIL_INSTALL_ERROR="apt-get not available; Firejail installation requires apt-get."
        log_error "$FIREJAIL_INSTALL_ERROR"
        return 1
    fi

    local install_output
    if ! install_output=$(sudo apt-get update && sudo apt-get install -y firejail 2>&1); then
        FIREJAIL_INSTALL_ERROR="$install_output"
        log_error "Firejail installation failed with error:"
        echo "$install_output"
        return 1
    fi

    if command_exists firejail; then
        FIREJAIL_VERSION=$(firejail --version | head -1)
        log_success "Firejail installed: $FIREJAIL_VERSION"
        return 0
    else
        FIREJAIL_INSTALL_ERROR="Firejail binary not found after installation."
        log_error "$FIREJAIL_INSTALL_ERROR"
        return 1
    fi
}

# ----------------------------------------------------------------------
# Prompt user after Firejail installation failure
# ----------------------------------------------------------------------
confirm_unsandboxed() {
    log_error "WARNING: Running without a sandbox executes arbitrary code as ${USER}."
    read -p "Type 'YES' to proceed unsandboxed: " confirm

    if [ "$confirm" == "YES" ]; then
        export SANDBOX_MODE="none"
        log_warning "Proceeding without sandbox protection."
        return 0
    fi

    log_info "Unsandboxed execution not confirmed."
    return 1
}

# ----------------------------------------------------------------------
# Handle Firejail installation failures in interactive mode
# ----------------------------------------------------------------------
handle_firejail_failure() {
    local reason="$1"

    while true; do
        log_error "Firejail installation failed: ${reason}"

        if [ -n "${FIREJAIL_INSTALL_ERROR:-}" ]; then
            log_error "Error detail:"
            echo "${FIREJAIL_INSTALL_ERROR}"
        fi

        log_error "Options:"
        log_error "  [r] Retry installation"
        log_error "  [u] Proceed UNSANDBOXED (DANGEROUS - Code runs as ${USER})"
        log_error "  [a] Abort"

        read -p "Selection [r/u/a]: " choice
        case $choice in
            r|R)
                if install_firejail; then
                    export SANDBOX_MODE="firejail"
                    return 0
                fi
                reason="${FIREJAIL_INSTALL_ERROR:-Installation failed again}"
                ;;
            u|U)
                if confirm_unsandboxed; then
                    return 0
                fi
                ;;
            a|A)
                return 2
                ;;
            *)
                echo "Invalid option."
                ;;
        esac
    done
}

# ----------------------------------------------------------------------
# Ensure Firejail sandbox availability
# ----------------------------------------------------------------------
ensure_sandbox() {
    log_info "Checking Firejail sandbox environment..."

    if command_exists firejail; then
        FIREJAIL_VERSION=$(firejail --version | head -1)
        log_success "Firejail available: $FIREJAIL_VERSION"
        export SANDBOX_MODE="firejail"
        return 0
    fi

    if [ "${NONINTERACTIVE:-0}" = "1" ]; then
        log_info "Firejail not detected; attempting installation in NONINTERACTIVE mode."
        if install_firejail; then
            export SANDBOX_MODE="firejail"
            return 0
        fi
        error_exit "Firejail installation failed in NONINTERACTIVE mode: ${FIREJAIL_INSTALL_ERROR:-Unknown error}"
    fi

    while true; do
        read -p "Firejail not found. Install now? (Y/n): " choice
        case $choice in
            ""|y|Y)
                if install_firejail; then
                    export SANDBOX_MODE="firejail"
                    return 0
                fi
                local reason="${FIREJAIL_INSTALL_ERROR:-Installation failed}"
                handle_firejail_failure "$reason"
                return $?
                ;;
            n|N)
                handle_firejail_failure "Firejail installation skipped by user"
                return $?
                ;;
            *)
                echo "Please answer 'y' or 'n'."
                ;;
        esac
    done
}

# Legacy wrapper
check_docker() {
    ensure_sandbox
}

# ----------------------------------------------------------------------
# Verify Rust in Sandbox
# ----------------------------------------------------------------------
verify_rust_in_sandbox() {
    log_info "Verifying Rust toolchain in mode: ${SANDBOX_MODE:-unknown}"

    case "${SANDBOX_MODE:-firejail}" in
        firejail)
            if ! firejail --quiet rustc --version >/dev/null 2>&1; then
                error_exit "Rust not found (Firejail mode checks host Rust)"
            fi
            ;;
        none)
            if ! command -v rustc >/dev/null 2>&1; then
                error_exit "Rust not installed on host."
            fi
            ;;
        *)
            error_exit "Unknown sandbox mode: ${SANDBOX_MODE}"
            ;;
    esac
}
