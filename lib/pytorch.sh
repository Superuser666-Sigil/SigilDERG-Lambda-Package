#!/bin/bash
# lib/pytorch.sh
#
# PyTorch and Flash Attention v2 installation.
#
# Installs PyTorch with CUDA support and optionally Flash Attention v2 for performance.
# Detects CUDA version and installs appropriate PyTorch wheel (2.4.0 for CUDA 12.4 or
# 2.7.1 for CUDA 12.8+). Attempts to install Flash Attention v2 with graceful fallback.
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 1.3.6

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/eval_setup_config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/python_env.sh"

# Install PyTorch with CUDA support
install_pytorch() {
    log_info "Installing PyTorch with CUDA support..."
    
    # Ensure venv is active (use parameter expansion to handle unset variable)
    if [ -z "${VIRTUAL_ENV:-}" ] || [ "${VIRTUAL_ENV:-}" != "$VENV_DIR" ]; then
        source "$VENV_DIR/bin/activate" || error_exit "Failed to activate virtual environment"
    fi
    
    # Use venv's pip explicitly
    PIP_CMD="$VENV_DIR/bin/pip"
    
    # Detect CUDA version
    if command_exists nvidia-smi; then
        CUDA_VERSION=$(nvidia-smi | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' || echo "12.4")
        log_info "Detected CUDA version: $CUDA_VERSION"
    else
        CUDA_VERSION="12.4"
        log_warning "nvidia-smi not found, defaulting to CUDA 12.4"
    fi
    
    # Install PyTorch based on CUDA version
    if [[ "$CUDA_VERSION" == "12.8" ]] || [[ "$CUDA_VERSION" == "12.9" ]]; then
        log_info "Installing PyTorch 2.7.1 with CUDA 12.8 support..."
        "$PIP_CMD" install torch==2.7.1+cu128 torchvision==0.22.1+cu128 torchaudio==2.7.1+cu128 \
            --index-url https://download.pytorch.org/whl/cu128 \
            || error_exit "Failed to install PyTorch with CUDA 12.8"
    else
        log_info "Installing PyTorch 2.4.0 with CUDA 12.4 support..."
        "$PIP_CMD" install torch==2.4.0 torchvision==0.19.0 torchaudio==2.4.0 \
            --index-url https://download.pytorch.org/whl/cu124 \
            || error_exit "Failed to install PyTorch with CUDA 12.4"
    fi
    
    log_success "PyTorch installed"
    
    # Install Flash Attention v2 (optional, for performance optimization)
    # Note: flash-attn requires torch to be installed first and needs --no-build-isolation
    # It also requires CUDA toolkit and compilation tools, so it may fail on some systems
    log_info "Installing Flash Attention v2 (optional performance optimization)..."
    log_info "This may take several minutes as it compiles from source..."
    
    # Try installing with --no-build-isolation first (allows using installed torch)
    if "$PIP_CMD" install --no-cache-dir --no-build-isolation "flash-attn>=2.5.0" 2>&1 | tee -a setup.log; then
        log_success "Flash Attention v2 installed"
    else
        log_warning "Flash Attention v2 installation failed"
        log_info "Attempting alternative installation method..."
        
        # Try with MAX_JOBS=1 to reduce memory usage during compilation
        if MAX_JOBS=1 "$PIP_CMD" install --no-cache-dir --no-build-isolation "flash-attn>=2.5.0" 2>&1 | tee -a setup.log; then
            log_success "Flash Attention v2 installed (with reduced parallelism)"
        else
            log_warning "Flash Attention v2 installation failed (will use standard attention)"
            log_info "This is not critical - the evaluation will still work, just slower"
            log_info "Flash Attention v2 requires:"
            log_info "  - CUDA toolkit (nvcc compiler)"
            log_info "  - Sufficient GPU memory for compilation"
            log_info "  - Build tools (gcc, make, etc.)"
            log_info "You can install it manually later if needed"
        fi
    fi
}

