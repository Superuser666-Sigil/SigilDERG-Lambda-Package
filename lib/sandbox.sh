#!/bin/bash
# lib/sandbox.sh
#
# Docker and Firejail sandbox verification and fallback handling.
#
# Verifies Docker access, handles permission issues, and provides fallback
# options (Firejail installation or unsandboxed mode) with user confirmation.
# Ensures users are always aware of sandboxing status when running untrusted code.
# Includes retry logic and detailed diagnostics for Docker startup issues.
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 1.3.5

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/eval_setup_config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/environment.sh"

# Verify Docker permissions and functionality
verify_docker_access() {
    log_info "Verifying Docker access and permissions..."
    
    if ! command_exists docker; then
        return 1
    fi
    
    # First check if Docker daemon is running with docker info
    if ! docker info >/dev/null 2>&1; then
        DOCKER_ERROR=$(docker info 2>&1)
        if echo "$DOCKER_ERROR" | grep -q "permission denied\|connect.*docker.sock"; then
            log_error "Docker permission denied: user does not have access to Docker daemon"
            log_info "Error details: $DOCKER_ERROR"
            return 2  # Permission denied
        else
            log_warning "Docker daemon not running or not accessible"
            log_info "Error details: $DOCKER_ERROR"
            return 1  # Other error (daemon not running)
        fi
    fi
    
    # Test Docker access with a simple command
    if docker ps >/dev/null 2>&1; then
        log_success "Docker access verified (docker ps succeeded)"
        return 0
    else
        # Check if it's a permission issue
        DOCKER_PS_ERROR=$(docker ps 2>&1)
        if echo "$DOCKER_PS_ERROR" | grep -q "permission denied\|connect.*docker.sock"; then
            log_error "Docker permission denied: user does not have access to Docker daemon"
            log_info "Error details: $DOCKER_PS_ERROR"
            return 2  # Permission denied
        else
            log_warning "Docker command failed (may not be running or accessible)"
            log_info "Error details: $DOCKER_PS_ERROR"
            return 1  # Other error
        fi
    fi
}

# Install Firejail
install_firejail() {
    log_info "Installing Firejail for sandboxing..."
    
    if command_exists apt-get; then
        # Ubuntu/Debian installation
        sudo apt-get update || {
            log_error "Failed to update package lists"
            return 1
        }
        
        sudo apt-get install -y firejail || {
            log_error "Failed to install Firejail"
            return 1
        }
        
        # Verify installation
        if command_exists firejail; then
            FIREJAIL_VERSION=$(firejail --version 2>/dev/null | head -1 || echo "unknown")
            log_success "Firejail installed: $FIREJAIL_VERSION"
            
            # Verify firejail works
            if firejail --version >/dev/null 2>&1; then
                log_success "Firejail is functional"
                return 0
            else
                log_warning "Firejail installed but may not be functional"
                return 1
            fi
        else
            log_error "Firejail installation completed but command not found"
            return 1
        fi
    else
        log_error "apt-get not available. Cannot install Firejail automatically."
        log_info "Please install Firejail manually for your distribution"
        return 1
    fi
}

# Check Firejail availability
check_firejail() {
    if command_exists firejail; then
        if firejail --version >/dev/null 2>&1; then
            FIREJAIL_VERSION=$(firejail --version 2>/dev/null | head -1 || echo "unknown")
            log_success "Firejail is available: $FIREJAIL_VERSION"
            return 0
        else
            log_warning "Firejail command exists but may not be functional"
            return 1
        fi
    else
        return 1
    fi
}

# Handle sandbox mode selection when Docker fails
handle_sandbox_fallback() {
    log_error "==================================================================="
    log_error "CRITICAL: Docker access verification failed!"
    log_error "==================================================================="
    log_error ""
    log_error "The evaluation will run untrusted model-generated Rust code."
    log_error "You MUST choose a sandboxing method:"
    log_error ""
    log_error "Options:"
    log_error "  1) Install Firejail (recommended) - Linux sandboxing tool"
    log_error "  2) Run UNSANDBOXED (DANGEROUS - only for trusted code)"
    log_error "  3) Stop and fix Docker permissions manually"
    log_error ""
    
    if [ "${NONINTERACTIVE:-0}" = "1" ]; then
        log_error "NONINTERACTIVE=1 set, but sandbox verification failed."
        log_error "Cannot proceed without user confirmation for sandbox mode."
        log_error ""
        log_error "To fix Docker permissions, run:"
        log_error "  sudo usermod -aG docker \$USER"
        log_error "  newgrp docker  # or log out and back in"
        log_error "  docker ps  # verify it works"
        log_error ""
        log_error "Then re-run this script."
        error_exit "Docker verification failed in non-interactive mode"
    fi
    
    while true; do
        echo ""
        read -p "Choose an option (1=Firejail, 2=Unsandboxed, 3=Stop): " -n 1 -r choice
        echo ""
        
        case $choice in
            1)
                log_info "Installing Firejail..."
                if install_firejail; then
                    if check_firejail; then
                        log_success "Firejail installed and verified. Sandbox mode will be 'firejail'"
                        export SANDBOX_MODE="firejail"
                        return 0
                    else
                        log_error "Firejail installation completed but verification failed"
                        log_error "Please verify Firejail manually: firejail --version"
                        read -p "Continue anyway with Firejail? (y/N): " -n 1 -r
                        echo ""
                        if [[ $REPLY =~ ^[Yy]$ ]]; then
                            export SANDBOX_MODE="firejail"
                            return 0
                        fi
                    fi
                else
                    log_error "Firejail installation failed"
                    read -p "Try again? (y/N): " -n 1 -r
                    echo ""
                    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                        continue
                    fi
                fi
                ;;
            2)
                log_error "==================================================================="
                log_error "WARNING: UNSANDBOXED MODE SELECTED"
                log_error "==================================================================="
                log_error ""
                log_error "You have chosen to run evaluation WITHOUT sandboxing."
                log_error "This means untrusted model-generated Rust code will run directly"
                log_error "on your system with full privileges."
                log_error ""
                log_error "THIS IS DANGEROUS and should only be used:"
                log_error "  - For development/testing with trusted code"
                log_error "  - On isolated systems"
                log_error "  - When you fully understand the risks"
                log_error ""
                read -p "Type 'YES' to confirm you understand the risks: " confirm
                if [[ "$confirm" == "YES" ]]; then
                    log_warning "Proceeding with UNSANDBOXED evaluation (sandbox_mode=none)"
                    export SANDBOX_MODE="none"
                    return 0
                else
                    log_info "Confirmation not provided. Please choose again."
                    continue
                fi
                ;;
            3)
                log_info "Stopping as requested."
                log_info ""
                log_info "To fix Docker permissions, run:"
                log_info "  sudo usermod -aG docker \$USER"
                log_info "  newgrp docker  # or log out and back in"
                log_info "  docker ps  # verify it works"
                log_info ""
                log_info "Then re-run this script."
                exit 0
                ;;
            *)
                log_warning "Invalid choice. Please enter 1, 2, or 3."
                continue
                ;;
        esac
    done
}

# Enhanced Docker check with permission verification
check_docker_with_verification() {
    log_info "Checking Docker availability and permissions..."
    
    if ! command_exists docker; then
        log_warning "Docker not found. Install Docker for secure sandboxing: https://docs.docker.com/get-docker/"
        log_info "For Ubuntu 22.04, you can install with:"
        log_info "  curl -fsSL https://get.docker.com -o get-docker.sh"
        log_info "  sudo sh get-docker.sh"
        handle_sandbox_fallback
        return $?
    fi
    
    # Check if Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        log_warning "Docker is installed but not running. Attempting to start Docker..."
        
        # Try to start Docker service (systemd)
        if command_exists systemctl; then
            log_info "Starting Docker service via systemctl..."
            if sudo systemctl start docker 2>&1 | tee -a setup.log; then
                log_info "Waiting for Docker daemon to start (this may take up to 60 seconds)..."
                
                # Wait for Docker to be ready with retries
                DOCKER_READY=false
                for i in {1..12}; do
                    sleep 5
                    if docker info >/dev/null 2>&1; then
                        log_success "Docker daemon is now running"
                        DOCKER_READY=true
                        break
                    fi
                    if [ $i -lt 12 ]; then
                        log_info "Still waiting for Docker... ($((i*5))s elapsed)"
                    fi
                done
                
                if [ "$DOCKER_READY" = false ]; then
                    log_warning "Docker service started but daemon not responding after 60 seconds"
                    log_info "Checking Docker service status..."
                    sudo systemctl status docker --no-pager -l | head -20 || true
                    log_info "You may need to check Docker logs: sudo journalctl -u docker.service"
                fi
            else
                log_warning "Failed to start Docker service via systemctl"
                log_info "Checking Docker service status..."
                sudo systemctl status docker --no-pager -l | head -20 || true
            fi
        else
            log_warning "systemctl not available, cannot start Docker service automatically"
        fi
    fi
    
    # Verify Docker access with docker ps
    verify_docker_access
    verify_result=$?
    case $verify_result in
        0)
            log_success "Docker is available, running, and accessible"
            return 0
            ;;
        2)
            # Permission denied - this is critical
            log_error "Docker permission denied detected"
            
            # Try to fix automatically if possible
            if groups | grep -q docker; then
                log_warning "User is in docker group but permissions not active in this session"
                log_info "You may need to run: newgrp docker"
                log_info "Or log out and log back in for group changes to take effect"
            else
                log_info "User is not in docker group. Attempting to add user to docker group..."
                if sudo usermod -aG docker "$USER" 2>/dev/null; then
                    log_success "User added to docker group"
                    log_warning "You need to either:"
                    log_warning "  1) Log out and log back in, OR"
                    log_warning "  2) Run: newgrp docker"
                    log_warning ""
                    log_warning "Then verify with: docker ps"
                    log_warning ""
                    log_warning "The script will now prompt you for sandbox fallback options."
                else
                    log_warning "Could not automatically add user to docker group"
                fi
            fi
            
            # Always prompt for fallback when permission denied
            handle_sandbox_fallback
            return $?
            ;;
        1)
            # Other Docker error
            log_warning "Docker is installed but not accessible"
            handle_sandbox_fallback
            return $?
            ;;
    esac
}

# Check Docker availability (legacy function, kept for compatibility)
check_docker() {
    # This function is now a wrapper that calls the enhanced version
    check_docker_with_verification
}

