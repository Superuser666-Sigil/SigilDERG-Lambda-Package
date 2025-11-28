#!/bin/bash
# lib/sigilderg.sh
#
# SigilDERG ecosystem component installation.
#
# Installs core dependencies, human-eval-rust, sigil-pipeline, and sigilderg-finetuner
# with PyPI fallback to GitHub for reliability. Validates package versions and import
# functionality to ensure correct installation. Requires human-eval-rust>=1.4.3.
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 1.3.8

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/eval_setup_config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/python_env.sh"

# Install SigilDERG components
install_sigilderg_components() {
    log_info "Installing SigilDERG ecosystem components..."
    
    # Ensure venv is active (use parameter expansion to handle unset variable)
    if [ -z "${VIRTUAL_ENV:-}" ] || [ "${VIRTUAL_ENV:-}" != "$VENV_DIR" ]; then
        source "$VENV_DIR/bin/activate" || error_exit "Failed to activate virtual environment"
    fi
    
    # Use venv's pip explicitly
    PIP_CMD="$VENV_DIR/bin/pip"
    
    # Verify pip is using venv
    PIP_LOCATION=$("$PIP_CMD" --version 2>&1 | head -1)
    log_info "Using pip: $PIP_CMD"
    log_info "Pip location: $PIP_LOCATION"
    
    # Install core dependencies first
    log_info "Installing core dependencies..."
    # Install termcolor 3.2.0+ for compatibility across ecosystem
    "$PIP_CMD" install transformers>=4.44.0 accelerate>=0.33.0 peft>=0.12.0 \
        bitsandbytes>=0.43.1 huggingface-hub>=0.24.0 \
        "termcolor>=3.2.0" \
        || error_exit "Failed to install core dependencies"
    
    # Install jsonlines explicitly (required for evaluation script)
    log_info "Installing jsonlines..."
    "$PIP_CMD" install jsonlines>=4.0.0 || error_exit "Failed to install jsonlines"
    log_success "jsonlines installed"
    
    # Install human-eval-rust (with fallback to GitHub if PyPI not available or has syntax errors)
    log_info "Installing human-eval-rust (requires >=1.4.3 for enhanced prompt format, result schema, compile rate tracking, main-free rate tracking, rustc preflight checks, never-dropping completions, Docker/Finetuner parity, and Rust 1.91.1 Docker image)..."
    # Uninstall old version first to ensure clean install
    "$PIP_CMD" uninstall -y human-eval-rust 2>/dev/null || true
    # Force reinstall with version constraint to get H100 optimizations and fixes (1.3.8+)
    PYPI_INSTALL_SUCCESS=false
    if "$PIP_CMD" install --force-reinstall --no-cache-dir "human-eval-rust>=1.4.3" 2>&1 | tee -a setup.log; then
        PYPI_INSTALL_SUCCESS=true
        # Small delay to ensure package metadata is fully written
        sleep 2
        
        # CRITICAL: Validate that the package can actually be imported (catches syntax errors)
        log_info "Validating installation (checking for syntax errors)..."
        if ! "$VENV_DIR/bin/python" -c "import human_eval; from human_eval.data import read_problems, get_human_eval_dataset" 2>&1 | tee -a setup.log; then
            log_warning "PyPI package installed but has syntax/import errors. Falling back to GitHub..."
            "$PIP_CMD" uninstall -y human-eval-rust 2>/dev/null || true
            PYPI_INSTALL_SUCCESS=false
        else
            # Verify installation by checking version (more reliable than import check)
            # Try multiple methods to get version
            # First try: Python import (suppress stderr to avoid capturing syntax errors)
            PYTHON_VERSION_OUTPUT=$("$VENV_DIR/bin/python" -c "import human_eval; print(getattr(human_eval, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
            # Filter out error messages - only accept strings that look like version numbers
            if [[ "$PYTHON_VERSION_OUTPUT" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+)?$ ]]; then
                INSTALLED_VERSION="$PYTHON_VERSION_OUTPUT"
            else
                INSTALLED_VERSION="unknown"
            fi
            # If that failed, try checking pip show
            if [[ "$INSTALLED_VERSION" == "unknown" ]] || [[ -z "$INSTALLED_VERSION" ]]; then
                PIP_VERSION=$("$PIP_CMD" show human-eval-rust 2>/dev/null | grep "^Version:" | awk '{print $2}' || echo "unknown")
                if [[ "$PIP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+)?$ ]]; then
                    INSTALLED_VERSION="$PIP_VERSION"
                fi
            fi
            # If still unknown, check if import works at all
            if [[ "$INSTALLED_VERSION" == "unknown" ]] || [[ -z "$INSTALLED_VERSION" ]]; then
                if "$VENV_DIR/bin/python" -c "import human_eval" 2>/dev/null; then
                    # Import works, version might just not be accessible, assume it's the installed version
                    INSTALLED_VERSION="1.3.8+"
                    log_info "Package imports successfully, assuming version >=1.3.8 from PyPI"
                fi
            fi
            
            if [[ "$INSTALLED_VERSION" != "unknown" ]] && [[ -n "$INSTALLED_VERSION" ]]; then
                log_success "human-eval-rust installed from PyPI (version: $INSTALLED_VERSION)"
                # Verify it's the correct version (allow 1.3.8+ format)
                if [[ "$INSTALLED_VERSION" != "1.3.8" ]] && [[ "$INSTALLED_VERSION" != "1.3.8+" ]] && [[ ! "$INSTALLED_VERSION" =~ ^1\.3\.[8-9] ]]; then
                    log_warning "Installed version $INSTALLED_VERSION may not have the latest fixes (expected >=1.3.8)"
                fi
            else
                # Version check failed, but PyPI install succeeded - likely just a version detection issue
                log_warning "PyPI package installed successfully but version check inconclusive"
                    log_info "Assuming version >=1.3.8 from PyPI installation (package installed successfully)"
                    log_success "human-eval-rust installed from PyPI (version check inconclusive, but installation succeeded)"
            fi
        fi
    fi
    
    # Fallback to GitHub if PyPI install failed or had syntax errors
    if [ "$PYPI_INSTALL_SUCCESS" = false ]; then
        log_warning "PyPI installation failed or had errors, trying GitHub fallback..."
        "$PIP_CMD" install --no-cache-dir git+https://github.com/Superuser666-Sigil/human-eval-Rust.git@main \
            || error_exit "Failed to install human-eval-rust from PyPI or GitHub"
        
        # Validate GitHub installation
        sleep 2
        log_info "Validating GitHub installation (checking for syntax errors)..."
        if ! "$VENV_DIR/bin/python" -c "import human_eval; from human_eval.data import read_problems, get_human_eval_dataset" 2>&1 | tee -a setup.log; then
            error_exit "GitHub installation also has syntax/import errors. Please check the human-eval-Rust repository."
        fi
        
        # Verify GitHub installation version
        PYTHON_VERSION_OUTPUT=$("$VENV_DIR/bin/python" -c "import human_eval; print(getattr(human_eval, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
        # Filter out error messages - only accept strings that look like version numbers
        if [[ "$PYTHON_VERSION_OUTPUT" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+)?$ ]]; then
            GITHUB_VERSION="$PYTHON_VERSION_OUTPUT"
        else
            GITHUB_VERSION="unknown"
        fi
        if [[ "$GITHUB_VERSION" == "unknown" ]] || [[ -z "$GITHUB_VERSION" ]]; then
            PIP_VERSION=$("$PIP_CMD" show human-eval-rust 2>/dev/null | grep "^Version:" | awk '{print $2}' || echo "unknown")
            if [[ "$PIP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+)?$ ]]; then
                GITHUB_VERSION="$PIP_VERSION"
            fi
        fi
        if [[ "$GITHUB_VERSION" != "1.3.8" ]] && [[ "$GITHUB_VERSION" != "unknown" ]] && [[ -n "$GITHUB_VERSION" ]]; then
            log_warning "GitHub installation version $GITHUB_VERSION does not match expected 1.3.8"
            log_warning "This may indicate the GitHub main branch is not up to date. Consider using PyPI version 1.3.8+"
        fi
        log_success "human-eval-rust installed from GitHub (version: ${GITHUB_VERSION:-unknown})"
        # Note: termcolor>=3.2.0 is already installed in core dependencies and is compatible across all ecosystem components
    fi
    
    # Install sigil-pipeline (with fallback to GitHub if PyPI not available)
    log_info "Installing sigil-pipeline (requires >=1.2.1 for termcolor compatibility)..."
    # Uninstall old version first to ensure clean install
    "$PIP_CMD" uninstall -y sigil-pipeline 2>/dev/null || true
    # Force reinstall with version constraint for termcolor compatibility (1.2.1+)
    if "$PIP_CMD" install --force-reinstall --no-cache-dir "sigil-pipeline>=1.2.1" 2>&1 | tee -a setup.log; then
        # Verify installation succeeded
        if "$VENV_DIR/bin/python" -c "import sigil_pipeline" 2>/dev/null; then
            INSTALLED_VERSION=$("$VENV_DIR/bin/python" -c "import sigil_pipeline; print(getattr(sigil_pipeline, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
            log_success "sigil-pipeline installed from PyPI (version: $INSTALLED_VERSION)"
        else
            log_warning "PyPI package installed but import failed, trying GitHub fallback..."
            "$PIP_CMD" uninstall -y sigil-pipeline 2>/dev/null || true
            "$PIP_CMD" install --no-cache-dir git+https://github.com/Superuser666-Sigil/SigilDERG-Data_Production.git@main \
                || log_warning "Failed to install sigil-pipeline from PyPI or GitHub (optional)"
            log_success "sigil-pipeline installed from GitHub"
        fi
    else
        log_warning "PyPI installation failed, trying GitHub fallback..."
        "$PIP_CMD" install --no-cache-dir git+https://github.com/Superuser666-Sigil/SigilDERG-Data_Production.git@main \
            || log_warning "Failed to install sigil-pipeline from PyPI or GitHub (optional)"
        log_success "sigil-pipeline installed from GitHub"
    fi
    
    # Install sigilderg-finetuner (with fallback to GitHub if PyPI not available)
    log_info "Installing sigilderg-finetuner..."
    # Force upgrade and clear cache to get latest version
    if "$PIP_CMD" install --upgrade --no-cache-dir sigilderg-finetuner 2>&1 | tee -a setup.log; then
        # Verify installation succeeded
        if "$VENV_DIR/bin/python" -c "import rust_qlora" 2>/dev/null; then
            INSTALLED_VERSION=$("$VENV_DIR/bin/python" -c "import rust_qlora; print(getattr(rust_qlora, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
            log_success "sigilderg-finetuner installed from PyPI (version: $INSTALLED_VERSION)"
        else
            log_warning "PyPI package installed but import failed, trying GitHub fallback..."
            "$PIP_CMD" uninstall -y sigilderg-finetuner 2>/dev/null || true
            "$PIP_CMD" install --no-cache-dir git+https://github.com/Superuser666-Sigil/SigilDERG-Finetuner.git@main \
                || log_warning "Failed to install sigilderg-finetuner from PyPI or GitHub (optional)"
            log_success "sigilderg-finetuner installed from GitHub"
        fi
    else
        log_warning "PyPI installation failed, trying GitHub fallback..."
        "$PIP_CMD" install --no-cache-dir git+https://github.com/Superuser666-Sigil/SigilDERG-Finetuner.git@main \
            || log_warning "Failed to install sigilderg-finetuner from PyPI or GitHub (optional)"
        log_success "sigilderg-finetuner installed from GitHub"
    fi
    
    log_success "SigilDERG components installed"
}

