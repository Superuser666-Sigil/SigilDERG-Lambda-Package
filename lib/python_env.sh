#!/bin/bash
# lib/python_env.sh
#
# Python environment setup (pyenv, Python installation, virtual environment).
#
# Handles pyenv installation, Python version installation, and virtual environment
# creation and activation. Manages Python 3.12.11 installation via pyenv and creates
# the dedicated virtual environment at ~/.venvs/sigilderg-humaneval.
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 2.0.0

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/eval_setup_config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/environment.sh"

# Initialize pyenv in current shell
init_pyenv() {
    export PYENV_ROOT="$HOME/.pyenv"
    [[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"
    if [ -d "$PYENV_ROOT" ]; then
        eval "$(pyenv init - bash 2>/dev/null || pyenv init - 2>/dev/null)" || {
            log_warning "Could not initialize pyenv, trying alternative method"
            export PATH="$PYENV_ROOT/bin:$PATH"
        }
    fi
}

# Install pyenv
install_pyenv() {
    log_info "Setting up pyenv..."
    
    # Try to initialize pyenv first (in case it's already installed)
    init_pyenv
    
    if command_exists pyenv; then
        log_success "pyenv already installed and initialized"
        return 0
    fi
    
    log_info "Installing pyenv..."
    curl -fsSL https://pyenv.run | bash || error_exit "Failed to install pyenv"
    
    # Initialize pyenv in current shell after installation
    init_pyenv
    
    # Verify it's working
    if ! command_exists pyenv; then
        log_error "pyenv installed but not available in PATH"
        log_error "Trying to source ~/.bashrc..."
        source ~/.bashrc 2>/dev/null || true
        init_pyenv
    fi
    
    if ! command_exists pyenv; then
        error_exit "pyenv still not available after installation and initialization"
    fi
    
    # Add to shell profile for persistence (if not already there)
    if [ -f ~/.bashrc ] && ! grep -q 'pyenv init' ~/.bashrc; then
        {
            echo ''
            echo '# pyenv'
            echo 'export PYENV_ROOT="$HOME/.pyenv"'
            echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
            echo 'eval "$(pyenv init - bash 2>/dev/null || pyenv init - 2>/dev/null)"'
        } >> ~/.bashrc
        log_success "Added pyenv to ~/.bashrc"
    fi
    
    log_success "pyenv installed and initialized"
}

# Install Python 3.12.11
install_python() {
    log_info "Installing Python $PYTHON_VERSION via pyenv..."
    
    # Ensure pyenv is initialized
    init_pyenv
    
    if ! command_exists pyenv; then
        error_exit "pyenv not available. Please restart the script or source ~/.bashrc"
    fi
    
    # Check if Python is already installed
    if pyenv versions --bare 2>/dev/null | grep -q "^${PYTHON_VERSION}$"; then
        log_success "Python $PYTHON_VERSION already installed"
    else
        log_info "This may take 10-15 minutes..."
        pyenv install "$PYTHON_VERSION" || error_exit "Failed to install Python $PYTHON_VERSION"
        log_success "Python $PYTHON_VERSION installed"
    fi
    
    # Set local version
    pyenv local "$PYTHON_VERSION" || error_exit "Failed to set local Python version"
    
    # Verify Python version
    PYTHON_VER=$(python --version 2>&1 | awk '{print $2}' || echo "")
    if [[ "$PYTHON_VER" == "$PYTHON_VERSION" ]]; then
        log_success "Python $PYTHON_VERSION set as local version and verified"
    else
        log_warning "Python version check: expected $PYTHON_VERSION, got $PYTHON_VER"
        log_info "Trying to reinitialize pyenv..."
        init_pyenv
        pyenv local "$PYTHON_VERSION"
    fi
}

# Create and activate virtual environment
setup_venv() {
    log_info "Setting up virtual environment at $VENV_DIR..."
    
    # Ensure pyenv Python is being used
    init_pyenv
    
    if [ ! -d "$VENV_DIR" ]; then
        mkdir -p "$(dirname "$VENV_DIR")"
        # Use pyenv's python explicitly
        PYENV_PYTHON=$(pyenv which python 2>/dev/null || which python)
        log_info "Using Python: $PYENV_PYTHON"
        "$PYENV_PYTHON" -m venv "$VENV_DIR" || error_exit "Failed to create virtual environment"
        log_success "Virtual environment created"
    else
        log_warning "Virtual environment already exists at $VENV_DIR"
    fi
    
    # Activate virtual environment
    source "$VENV_DIR/bin/activate" || error_exit "Failed to activate virtual environment"
    
    # Verify venv is active (use parameter expansion to handle unset variable)
    if [ -z "${VIRTUAL_ENV:-}" ]; then
        error_exit "Virtual environment not activated (VIRTUAL_ENV not set)"
    fi
    
    if [ "${VIRTUAL_ENV:-}" != "$VENV_DIR" ]; then
        error_exit "Virtual environment mismatch: expected $VENV_DIR, got ${VIRTUAL_ENV:-}"
    fi
    
    # Verify we're using venv's pip
    PIP_BIN=$(which pip 2>/dev/null || echo "")
    if [[ -z "$PIP_BIN" ]] || [[ "$PIP_BIN" != "$VENV_DIR/bin/pip"* ]]; then
        log_warning "pip is not from venv: ${PIP_BIN:-not found}"
        log_info "Using venv pip explicitly: $VENV_DIR/bin/pip"
        export PIP_BIN="$VENV_DIR/bin/pip"
    else
        export PIP_BIN="pip"
        log_success "Using venv pip: $PIP_BIN"
    fi
    
    # Verify Python version
    PYTHON_VER=$(python --version 2>&1 | awk '{print $2}')
    if [[ "$PYTHON_VER" != "$PYTHON_VERSION" ]]; then
        log_warning "Python version mismatch: expected $PYTHON_VERSION, got $PYTHON_VER"
        log_info "This may be okay if the venv was created with a different Python"
    else
        log_success "Python version verified: $PYTHON_VER"
    fi
    
    # Upgrade pip using venv's pip explicitly
    log_info "Upgrading pip, wheel, and setuptools..."
    "$VENV_DIR/bin/python" -m pip install --upgrade pip wheel setuptools build twine || error_exit "Failed to upgrade pip"
    
    log_success "Virtual environment activated and verified"
}

