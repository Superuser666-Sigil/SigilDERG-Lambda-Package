#!/bin/bash
# lib/cli_tools.sh
#
# CLI tool installation (GitHub CLI, HuggingFace CLI).
#
# Installs and authenticates GitHub CLI (gh) and HuggingFace CLI (hf) for accessing
# repositories and models. Handles interactive authentication flows and PATH configuration.
# Skips authentication in NONINTERACTIVE mode with instructions for manual setup.
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 1.3.8

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/eval_setup_config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/environment.sh"

# Install GitHub CLI
install_gh() {
    log_info "Checking GitHub CLI (gh)..."
    
    if command_exists gh; then
        GH_VERSION=$(gh --version | head -1)
        log_success "GitHub CLI already installed: $GH_VERSION"
        
        # Check if already authenticated
        if gh auth status >/dev/null 2>&1; then
            log_success "GitHub CLI is already authenticated"
            return 0
        else
            log_info "GitHub CLI not authenticated"
        fi
    else
        log_info "Installing GitHub CLI..."
        
        if command_exists apt-get; then
            # Install gh via apt (Ubuntu/Debian)
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
                && sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
                && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
                && sudo apt-get update \
                && sudo apt-get install -y gh \
                || return 1
            
            log_success "GitHub CLI installed"
        else
            log_warning "apt-get not available, cannot install GitHub CLI"
            return 1
        fi
    fi
    
    # Prompt for authentication (interactive - let gh handle its own flow)
    if ! gh auth status >/dev/null 2>&1; then
        if [ "${NONINTERACTIVE:-0}" = "1" ]; then
            log_warning "Skipping GitHub CLI authentication (NONINTERACTIVE=1)."
            log_warning "You can authenticate later with: gh auth login"
            return 0
        fi

        log_info "GitHub CLI authentication required"
        log_info "Starting GitHub CLI authentication (follow the interactive prompts)..."
        echo ""
        # Run authentication - gh handles its own interactive flow and waits for completion
        gh auth login || {
            log_warning "GitHub CLI authentication skipped or failed"
            log_warning "You can authenticate later with: gh auth login"
            return 1
        }
        log_success "GitHub CLI authenticated"
    fi
    
    return 0
}

# Install HuggingFace CLI
install_hf_cli() {
    log_info "Checking HuggingFace CLI (hf)..."
    
    if command_exists hf; then
        HF_VERSION=$(hf --version 2>/dev/null || echo "installed")
        log_success "HuggingFace CLI already installed: $HF_VERSION"
        
        # Check if already authenticated
        if hf whoami >/dev/null 2>&1; then
            HF_USER=$(hf whoami 2>/dev/null || echo "unknown")
            log_success "HuggingFace CLI is already authenticated as: $HF_USER"
            return 0
        else
            log_info "HuggingFace CLI not authenticated"
        fi
    else
        log_info "Installing HuggingFace CLI..."
        
        # Install using official installer
        curl -LsSf https://hf.co/cli/install.sh | bash || return 1
        
        # Add to PATH for current session
        export PATH="$HOME/.local/bin:$PATH"
        
        # Add to bashrc if not already there
        if [ -f ~/.bashrc ] && ! grep -q '\.local/bin' ~/.bashrc; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
        fi
        
        # Verify installation
        if command_exists hf; then
            log_success "HuggingFace CLI installed"
        else
            # Try sourcing bashrc
            source ~/.bashrc 2>/dev/null || true
            if ! command_exists hf; then
                log_warning "HuggingFace CLI installed but not in PATH"
                log_warning "Adding to PATH for this session..."
                export PATH="$HOME/.local/bin:$PATH"
                if ! command_exists hf; then
                    log_error "HuggingFace CLI installed but not accessible"
                    return 1
                fi
            fi
        fi
    fi
    
    # Prompt for authentication (interactive - let hf handle its own flow)
    if ! hf whoami >/dev/null 2>&1; then
        if [ "${NONINTERACTIVE:-0}" = "1" ]; then
            log_warning "Skipping HuggingFace CLI authentication (NONINTERACTIVE=1)."
            log_warning "You can authenticate later with: hf auth login"
            return 0
        fi

        log_info "HuggingFace CLI authentication required"
        log_info "Starting HuggingFace CLI authentication (follow the interactive prompts)..."
        echo ""
        # Run authentication - hf handles its own interactive flow and waits for completion
        hf auth login || {
            log_warning "HuggingFace CLI authentication skipped or failed"
            log_warning "You can authenticate later with: hf auth login"
            return 1
        }
        log_success "HuggingFace CLI authenticated"
    fi
    
    return 0
}

