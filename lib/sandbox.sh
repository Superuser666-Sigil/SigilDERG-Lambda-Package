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
# Version: 1.3.9

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/eval_setup_config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/environment.sh"

# Install Docker and configure user group
install_docker() {
    log_info "Installing Docker..."
    
    if command_exists docker; then
        log_success "Docker is already installed"
        return 0
    fi
    
    if ! command_exists curl; then
        error_exit "curl is required to install Docker. Please install curl first."
    fi
    
    # Install Docker using official script
    log_info "Downloading Docker installation script..."
    if ! curl -fsSL https://get.docker.com -o /tmp/get-docker.sh; then
        error_exit "Failed to download Docker installation script"
    fi
    
    log_info "Running Docker installation script..."
    if ! sudo sh /tmp/get-docker.sh; then
        rm -f /tmp/get-docker.sh
        error_exit "Docker installation failed"
    fi
    
    rm -f /tmp/get-docker.sh
    log_success "Docker installed successfully"
    
    # Immediately add user to docker group
    log_info "Adding user $USER to docker group..."
    if ! sudo usermod -aG docker "$USER"; then
        rm -f /tmp/get-docker.sh 2>/dev/null || true
        error_exit "CRITICAL: Failed to add user to docker group.\n\nPlease run these commands manually:\n  sudo usermod -aG docker $USER\n  newgrp docker\n\nThen verify with: docker ps"
    fi
    log_success "User added to docker group"
    
    # Attempt to activate docker group using newgrp
    # Note: newgrp starts a new shell, so we test access instead of actually activating
    log_info "Testing Docker group access (group activation may require new shell session)..."
    DOCKER_ACCESS_WORKING=false
    
    # Try sg first (preferred, doesn't replace shell)
    if command_exists sg; then
        if timeout 5 sg docker -c "docker ps >/dev/null 2>&1" 2>/dev/null; then
            DOCKER_ACCESS_WORKING=true
            log_success "Docker group access verified with sg docker"
        fi
    fi
    
    # Try newgrp -c as fallback (runs command in new group context without replacing shell)
    if [ "$DOCKER_ACCESS_WORKING" = false ] && command_exists newgrp; then
        if timeout 5 newgrp docker -c "docker ps >/dev/null 2>&1" 2>/dev/null; then
            DOCKER_ACCESS_WORKING=true
            log_success "Docker group access verified with newgrp docker"
        fi
    fi
    
    # If group access test failed, hard stop with instructions
    if [ "$DOCKER_ACCESS_WORKING" = false ]; then
        error_exit "CRITICAL: Docker group added but access verification failed.\n\nGroup changes require a new shell session to take effect.\n\nPlease run this command manually:\n  newgrp docker\n\nOr log out and back in, then verify with: docker ps\n\nAfter activating the group, re-run this setup script."
    fi
    
    log_success "Docker installation and group configuration completed successfully"
    log_info "Note: If you need to activate the docker group in your current shell session, run: newgrp docker"
}

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
# Returns: 0 on success, 1 on other error, 2 on user-requested stop
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
                log_info ""
                log_info "Exiting setup script..."
                # Return 2 to indicate user-requested stop (will be handled by caller)
                return 2
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
        log_warning "Docker not found. Attempting to install Docker..."
        
        if [ "${NONINTERACTIVE:-0}" = "1" ]; then
            # In non-interactive mode, try to install Docker automatically
            if install_docker; then
                log_success "Docker installed and configured successfully"
                export SANDBOX_MODE="docker"
                return 0
            else
                error_exit "Docker installation failed in non-interactive mode. Please install Docker manually."
            fi
        else
            # In interactive mode, ask user if they want to install
            log_info "Docker is required for secure sandboxing."
            read -p "Install Docker now? (Y/n): " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Nn]$ ]]; then
                log_info "Docker installation skipped. Proceeding to sandbox fallback options..."
                handle_sandbox_fallback
                FALLBACK_RESULT=$?
                if [ $FALLBACK_RESULT -eq 2 ]; then
                    # User requested stop (option 3)
                    return 2
                fi
                return $FALLBACK_RESULT
            else
                # User wants to install Docker
                if install_docker; then
                    log_success "Docker installed and configured successfully"
                    export SANDBOX_MODE="docker"
                    return 0
                else
                    log_error "Docker installation failed. Proceeding to sandbox fallback options..."
                    handle_sandbox_fallback
                    FALLBACK_RESULT=$?
                    if [ $FALLBACK_RESULT -eq 2 ]; then
                        # User requested stop (option 3)
                        return 2
                    fi
                    return $FALLBACK_RESULT
                fi
            fi
        fi
    fi
    
    # Check if Docker daemon is running (check service status first, then permissions)
    DOCKER_SERVICE_RUNNING=false
    if command_exists systemctl; then
        if systemctl is-active --quiet docker 2>/dev/null; then
            DOCKER_SERVICE_RUNNING=true
            log_info "Docker service is running"
        fi
    fi
    
    # Check if we can access Docker (this checks both daemon and permissions)
    if ! docker info >/dev/null 2>&1; then
        if [ "$DOCKER_SERVICE_RUNNING" = true ]; then
            # Service is running but we can't access it - this is a permission issue
            log_warning "Docker service is running but access denied (permission issue)"
            # Skip trying to start Docker, go straight to permission handling
        else
            # Service is not running - try to start it
            log_warning "Docker service is not running. Attempting to start Docker..."
            
            if command_exists systemctl; then
                log_info "Starting Docker service via systemctl..."
                if sudo systemctl start docker 2>&1 | tee -a setup.log; then
                    log_info "Waiting for Docker daemon to start (this may take up to 60 seconds)..."
                    
                    # Wait for Docker to be ready with retries
                    DOCKER_READY=false
                    for i in {1..12}; do
                        sleep 5
                        # Check service status first
                        if systemctl is-active --quiet docker 2>/dev/null; then
                            # Service is running, now check if we can access it
                            if docker info >/dev/null 2>&1; then
                                log_success "Docker daemon is now running and accessible"
                                DOCKER_READY=true
                                break
                            else
                                # Service running but no access - permission issue
                                log_warning "Docker service is running but access denied (permission issue)"
                                DOCKER_READY=false
                                break
                            fi
                        fi
                        if [ $i -lt 12 ]; then
                            log_info "Still waiting for Docker service to start... ($((i*5))s elapsed)"
                        fi
                    done
                    
                    if [ "$DOCKER_READY" = false ]; then
                        if systemctl is-active --quiet docker 2>/dev/null; then
                            log_warning "Docker service is running but not accessible (likely permission issue)"
                            log_info "Checking Docker service status..."
                            sudo systemctl status docker --no-pager -l | head -20 || true
                        else
                            log_warning "Docker service failed to start after 60 seconds"
                            log_info "Checking Docker service status..."
                            sudo systemctl status docker --no-pager -l | head -20 || true
                            log_info "You may need to check Docker logs: sudo journalctl -u docker.service"
                        fi
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
                log_info "Testing Docker access with sg docker (safer than newgrp)..."
                
                # Test if Docker works with sg (safer than newgrp, doesn't create interactive shell)
                # Use timeout to prevent hanging (5 second timeout)
                # sg is preferred over newgrp because it doesn't create a new interactive shell
                if command -v sg >/dev/null 2>&1; then
                    if timeout 5 sg docker -c "docker ps >/dev/null 2>&1" 2>/dev/null; then
                        log_success "Docker access verified with sg docker - docker ps succeeded"
                        log_info "Docker is accessible with docker group. Setting sandbox mode to docker."
                        log_info "Note: Current shell session may still need 'newgrp docker' for immediate access,"
                        log_info "but the evaluation will run with docker group active and will have access."
                        export SANDBOX_MODE="docker"
                        return 0
                    fi
                fi
                
                # Fallback to newgrp if sg is not available
                log_info "sg not available, trying newgrp docker..."
                if timeout 5 newgrp docker -c "docker ps >/dev/null 2>&1" 2>/dev/null; then
                    log_success "Docker access verified with newgrp docker - docker ps succeeded"
                    log_info "Docker is accessible with docker group. Setting sandbox mode to docker."
                    log_info "Note: Current shell session may still need 'newgrp docker' for immediate access,"
                    log_info "but the evaluation will run with docker group active and will have access."
                    export SANDBOX_MODE="docker"
                    return 0
                else
                    log_warning "Docker still not accessible even with newgrp docker"
                    log_info "You may need to log out and log back in for group changes to take effect"
                fi
            else
                log_info "User is not in docker group. Attempting to add user to docker group..."
                if sudo usermod -aG docker "$USER" 2>/dev/null; then
                    log_success "User added to docker group"
                    log_info "Testing Docker access with sg docker (safer than newgrp)..."
                    
                    # Test if Docker works with sg (safer than newgrp, doesn't create interactive shell)
                    # Use timeout to prevent hanging (5 second timeout)
                    # sg is preferred over newgrp because it doesn't create a new interactive shell
                    if command -v sg >/dev/null 2>&1; then
                        if timeout 5 sg docker -c "docker ps >/dev/null 2>&1" 2>/dev/null; then
                            log_success "Docker access verified with sg docker - docker ps succeeded"
                            log_info "Docker is accessible with docker group. Setting sandbox mode to docker."
                            log_info "Note: Current shell session may still need 'newgrp docker' for immediate access,"
                            log_info "but the evaluation will run with docker group active and will have access."
                            export SANDBOX_MODE="docker"
                            return 0
                        fi
                    fi
                    
                    # Fallback to newgrp if sg is not available
                    log_info "sg not available, trying newgrp docker..."
                    if timeout 5 newgrp docker -c "docker ps >/dev/null 2>&1" 2>/dev/null; then
                        log_success "Docker access verified with newgrp docker - docker ps succeeded"
                        log_info "Docker is accessible with docker group. Setting sandbox mode to docker."
                        log_info "Note: Current shell session may still need 'newgrp docker' for immediate access,"
                        log_info "but the evaluation will run with docker group active and will have access."
                        export SANDBOX_MODE="docker"
                        return 0
                    else
                        log_warning "Docker group added but access still not working"
                        log_warning "You may need to log out and log back in for group changes to take effect"
                        log_warning "Or run: newgrp docker"
                        log_warning ""
                        log_warning "Then verify with: docker ps"
                    fi
                else
                    log_warning "Could not automatically add user to docker group"
                fi
            fi
            
            # If we get here, Docker access still not working - prompt for fallback
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

# Verify Rust toolchain is available inside the sandbox
verify_rust_in_sandbox() {
    log_info "Verifying Rust toolchain inside sandbox (mode=${SANDBOX_MODE:-docker})..."

    case "${SANDBOX_MODE:-docker}" in
        docker)
            DOCKER_IMAGE="${DOCKER_IMAGE:-human-eval-rust-sandbox}"
            if [ -z "${DOCKER_IMAGE:-}" ]; then
                error_exit "DOCKER_IMAGE not set; cannot verify Rust in Docker sandbox"
            fi

            if docker run --rm "${DOCKER_IMAGE}" rustc --version >/dev/null 2>&1; then
                RUST_VER=$(docker run --rm "${DOCKER_IMAGE}" rustc --version 2>/dev/null || echo "unknown")
                log_success "Rust available inside Docker sandbox image: ${DOCKER_IMAGE} (${RUST_VER})"
            else
                error_exit "Rust toolchain not available inside Docker image: ${DOCKER_IMAGE}. Build the image first or ensure it includes Rust."
            fi
            ;;
        firejail)
            if firejail --quiet rustc --version >/dev/null 2>&1; then
                RUST_VER=$(firejail --quiet rustc --version 2>/dev/null || echo "unknown")
                log_success "Rust available inside Firejail sandbox (${RUST_VER})"
            else
                error_exit "Rust toolchain not available inside Firejail sandbox"
            fi
            ;;
        none)
            # Fallback to host verification
            if command_exists rustc; then
                RUST_VER=$(rustc --version 2>/dev/null || echo "unknown")
                log_warning "Sandbox mode 'none': using host Rust toolchain directly (${RUST_VER})"
            else
                error_exit "Sandbox mode 'none' but Rust not available on host"
            fi
            ;;
        *)
            error_exit "Unknown SANDBOX_MODE: ${SANDBOX_MODE}"
            ;;
    esac
}

