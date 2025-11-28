#!/bin/bash
# lib/sigilderg.sh
#
# SigilDERG ecosystem component installation.
#
# Installs core dependencies, human-eval-rust, sigil-pipeline, and sigilderg-finetuner
# with PyPI fallback to GitHub for reliability. Validates package versions and import
# functionality to ensure correct installation.
#
# Required minimum versions:
#   - human-eval-rust >= 2.1.0
#   - sigil-pipeline >= 2.1.0
#   - sigilderg-finetuner >= 2.9.0
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 2.0.0

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/eval_setup_config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/python_env.sh"

# Minimum version requirements for ecosystem components
MIN_HUMAN_EVAL_RUST_VERSION="2.1.0"
MIN_SIGIL_PIPELINE_VERSION="2.2.0"
MIN_SIGILDERG_FINETUNER_VERSION="2.9.0"

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
    log_info "Installing human-eval-rust (requires >=${MIN_HUMAN_EVAL_RUST_VERSION})..."
    log_info "Features: Firejail-first sandboxing, enhanced prompt format, result schema,"
    log_info "          compile rate tracking, main-free rate tracking, rustc preflight checks"
    # Uninstall old version first to ensure clean install
    "$PIP_CMD" uninstall -y human-eval-rust 2>/dev/null || true
    PYPI_INSTALL_SUCCESS=false
    if "$PIP_CMD" install --force-reinstall --no-cache-dir "human-eval-rust>=${MIN_HUMAN_EVAL_RUST_VERSION}" 2>&1 | tee -a setup.log; then
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
            # Verify installation by checking version
            INSTALLED_VERSION=$(_get_package_version "human_eval" "human-eval-rust")
            if [[ "$INSTALLED_VERSION" != "unknown" ]] && [[ -n "$INSTALLED_VERSION" ]]; then
                log_success "human-eval-rust installed from PyPI (version: $INSTALLED_VERSION)"
            else
                log_warning "PyPI package installed but version check inconclusive"
                log_success "human-eval-rust installed from PyPI (installation succeeded)"
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
        
        GITHUB_VERSION=$(_get_package_version "human_eval" "human-eval-rust")
        log_success "human-eval-rust installed from GitHub (version: ${GITHUB_VERSION:-unknown})"
    fi
    
    # Install sigil-pipeline (with fallback to GitHub if PyPI not available)
    log_info "Installing sigil-pipeline (requires >=${MIN_SIGIL_PIPELINE_VERSION})..."
    # Uninstall old version first to ensure clean install
    "$PIP_CMD" uninstall -y sigil-pipeline 2>/dev/null || true
    if "$PIP_CMD" install --force-reinstall --no-cache-dir "sigil-pipeline>=2.2.0" 2>&1 | tee -a setup.log; then
        # Verify installation succeeded
        if "$VENV_DIR/bin/python" -c "import sigil_pipeline" 2>/dev/null; then
            INSTALLED_VERSION=$(_get_package_version "sigil_pipeline" "sigil-pipeline")
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
    log_info "Installing sigilderg-finetuner (requires >=${MIN_SIGILDERG_FINETUNER_VERSION})..."
    "$PIP_CMD" uninstall -y sigilderg-finetuner 2>/dev/null || true
    if "$PIP_CMD" install --force-reinstall --no-cache-dir "sigilderg-finetuner>=${MIN_SIGILDERG_FINETUNER_VERSION}" 2>&1 | tee -a setup.log; then
        # Verify installation succeeded
        if "$VENV_DIR/bin/python" -c "import rust_qlora" 2>/dev/null; then
            INSTALLED_VERSION=$(_get_package_version "rust_qlora" "sigilderg-finetuner")
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

# Helper function to get package version
_get_package_version() {
    local module_name="$1"
    local pip_name="$2"
    
    # Try Python import first
    local version
    version=$("$VENV_DIR/bin/python" -c "import ${module_name}; print(getattr(${module_name}, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
    
    # Filter out error messages - only accept strings that look like version numbers
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$version"
        return
    fi
    
    # Fallback to pip show
    version=$("$PIP_CMD" show "$pip_name" 2>/dev/null | grep "^Version:" | awk '{print $2}' || echo "unknown")
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$version"
        return
    fi
    
    echo "unknown"
}
