#!/bin/bash
# lib/sandbox.sh
#
# Docker and Firejail sandbox verification and fallback handling.
# Optimized for Ubuntu 22.04 LTS.
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 1.4.0

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Ensure these files exist before sourcing to prevent crash
[ -f "$SCRIPT_DIR/eval_setup_config.sh" ] && source "$SCRIPT_DIR/eval_setup_config.sh"
[ -f "$SCRIPT_DIR/lib/logging.sh" ] && source "$SCRIPT_DIR/lib/logging.sh" || { echo "CRITICAL: logging.sh not found"; exit 1; }
[ -f "$SCRIPT_DIR/lib/environment.sh" ] && source "$SCRIPT_DIR/lib/environment.sh"

# ----------------------------------------------------------------------
# Helper: Check for conflicting Docker Snap installation (Ubuntu specific)
# ----------------------------------------------------------------------
check_docker_snap() {
    if command -v snap >/dev/null 2>&1; then
        if snap list docker >/dev/null 2>&1; then
            log_warning "Detected Docker installed via Snap."
            log_warning "This script is optimized for the upstream Docker Engine (apt)."
            log_warning "Snap versions often have permission idiosyncrasies."
            # We don't exit, but we warn the user.
        fi
    fi
}

# ----------------------------------------------------------------------
# Install Docker and configure user group
# ----------------------------------------------------------------------
install_docker() {
    log_info "Installing Docker..."

    check_docker_snap
    
    if command_exists docker; then
        log_success "Docker is already installed"
        return 0
    fi
    
    if ! command_exists curl; then
        log_info "Installing curl..."
        sudo apt-get update && sudo apt-get install -y curl || error_exit "Failed to install curl."
    fi
    
    # Install Docker using official script
    log_info "Downloading Docker installation script..."
    if ! curl -fsSL https://get.docker.com -o /tmp/get-docker.sh; then
        error_exit "Failed to download Docker installation script"
    fi
    
    log_info "Running Docker installation script..."
    # Use sh explicitly
    if ! sudo sh /tmp/get-docker.sh; then
        rm -f /tmp/get-docker.sh
        error_exit "Docker installation failed"
    fi
    
    rm -f /tmp/get-docker.sh
    log_success "Docker installed successfully"
    
    # Configure Group
    log_info "Configuring Docker permissions..."
    if ! getent group docker >/dev/null; then
        sudo groupadd docker
    fi

    if ! sudo usermod -aG docker "$USER"; then
        error_exit "Failed to add user to docker group."
    fi
    
    log_success "User added to docker group."
    
    # CRITICAL CHANGE: We cannot reliably activate the group in the current script flow
    # for subsequent commands without complex hacks. The safest path is to force a restart.
    log_error "==================================================================="
    log_error "  DOCKER INSTALLATION COMPLETE - RESTART REQUIRED"
    log_error "==================================================================="
    log_error "  The user '$USER' has been added to the 'docker' group."
    log_error "  However, Linux requires a session restart for this to take effect."
    log_error ""
    log_error "  PLEASE DO ONE OF THE FOLLOWING:"
    log_error "  1. Log out and log back in (Recommended)"
    log_error "  2. Run this command manually, then re-run the script:"
    log_error "     newgrp docker"
    log_error "==================================================================="
    exit 1
}

# ----------------------------------------------------------------------
# Verify Docker permissions and functionality
# ----------------------------------------------------------------------
verify_docker_access() {
    log_info "Verifying Docker access..."
    
    if ! command_exists docker; then
        return 1
    fi
    
    # Increased timeout to 10s for slow startups
    if timeout 10 docker ps >/dev/null 2>&1; then
        log_success "Docker access verified (docker ps succeeded)"
        return 0
    else
        EXIT_CODE=$?
        ERROR_MSG=$(docker ps 2>&1)
        
        if [[ "$ERROR_MSG" == *"permission denied"* ]] || [[ "$ERROR_MSG" == *"connect to the Docker daemon socket"* ]]; then
             log_error "Permission denied accessing Docker socket."
             return 2
        elif [ $EXIT_CODE -eq 124 ]; then
             log_warning "Docker check timed out (daemon might be hung or starting)."
             return 1
        else
             log_warning "Docker daemon is not running."
             return 1
        fi
    fi
}

# ----------------------------------------------------------------------
# Install Firejail
# ----------------------------------------------------------------------
install_firejail() {
    log_info "Installing Firejail..."
    
    if ! command_exists apt-get; then
        log_error "This script requires apt-get (Ubuntu/Debian)."
        return 1
    fi

    sudo apt-get update || return 1
    sudo apt-get install -y firejail || return 1
    
    # Verify installation
    if command_exists firejail; then
        FIREJAIL_VERSION=$(firejail --version | head -1)
        log_success "Firejail installed: $FIREJAIL_VERSION"
        return 0
    else
        return 1
    fi
}

# ----------------------------------------------------------------------
# Handle sandbox mode selection when Docker fails
# ----------------------------------------------------------------------
handle_sandbox_fallback() {
    # If in non-interactive mode, fail immediately
    if [ "${NONINTERACTIVE:-0}" = "1" ]; then
        error_exit "Docker verification failed in NONINTERACTIVE mode."
    fi

    log_error "==================================================================="
    log_error "CRITICAL: Docker Unavailable or Permission Denied"
    log_error "==================================================================="
    log_error "Options:"
    log_error "  1) Install Firejail (Linux native sandbox)"
    log_error "  2) Run UNSANDBOXED (DANGEROUS - Code runs as $USER)"
    log_error "  3) Exit"
    
    while true; do
        read -p "Selection [1-3]: " choice
        case $choice in
            1)
                install_firejail
                if [ $? -eq 0 ]; then
                    export SANDBOX_MODE="firejail"
                    return 0
                fi
                log_error "Firejail install failed."
                ;;
            2)
                log_error "WARNING: CONFIRM UNSANDBOXED EXECUTION."
                read -p "Type 'YES' to confirm: " confirm
                if [ "$confirm" == "YES" ]; then
                    export SANDBOX_MODE="none"
                    return 0
                fi
                ;;
            3)
                return 2
                ;;
            *)
                echo "Invalid option."
                ;;
        esac
    done
}

# ----------------------------------------------------------------------
# Main Docker Check Logic
# ----------------------------------------------------------------------
check_docker_with_verification() {
    log_info "Checking Docker environment..."

    # 1. Check if installed
    if ! command_exists docker; then
        if [ "${NONINTERACTIVE:-0}" = "1" ]; then
             install_docker # Will exit 1 if it has to add groups
        else
             read -p "Docker not found. Install now? (y/N): " choice
             if [[ "$choice" =~ ^[Yy]$ ]]; then
                 install_docker
             else
                 handle_sandbox_fallback
                 return $?
             fi
        fi
    fi

    # 2. Check Service Status
    if command_exists systemctl; then
        if ! systemctl is-active --quiet docker; then
            log_info "Starting Docker service..."
            sudo systemctl start docker
            # Give it time to warm up
            log_info "Waiting for Docker daemon..."
            for i in {1..10}; do
                if docker info >/dev/null 2>&1; then break; fi
                sleep 2
            done
        fi
    fi

    # 3. Verify Access
    verify_docker_access
    RESULT=$?
    
    if [ $RESULT -eq 0 ]; then
        export SANDBOX_MODE="docker"
        return 0
    elif [ $RESULT -eq 2 ]; then
        # Permission denied specifically
        log_error "Current user does not have permission to access Docker."
        
        # Check if they are in the group but just need a reload
        if groups | grep -q docker; then
            log_warning "You are in the 'docker' group, but the session has not updated."
            log_info "Please run: 'newgrp docker' and re-run this script."
            return 2
        else
            log_info "Attempting to add user to docker group..."
            if sudo usermod -aG docker "$USER"; then
                 log_success "User added to group. PLEASE LOG OUT AND BACK IN."
                 exit 1
            fi
        fi
    fi

    # Fallback if we reach here
    handle_sandbox_fallback
    return $?
}

# Legacy wrapper
check_docker() {
    check_docker_with_verification
}

# ----------------------------------------------------------------------
# Verify Rust in Sandbox
# ----------------------------------------------------------------------
verify_rust_in_sandbox() {
    log_info "Verifying Rust toolchain in mode: ${SANDBOX_MODE:-unknown}"

    case "${SANDBOX_MODE:-docker}" in
        docker)
            DOCKER_IMAGE="${DOCKER_IMAGE:-human-eval-rust-sandbox}"
            if ! docker run --rm "${DOCKER_IMAGE}" rustc --version >/dev/null 2>&1; then
                error_exit "Rust not found in Docker image: ${DOCKER_IMAGE}"
            fi
            ;;
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
    esac
}