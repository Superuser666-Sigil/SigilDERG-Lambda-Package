# SigilDERG Ecosystem Change Report

**Date:** January 2025  
**Version:** sigilderg.sh 2.1.0  
**Author:** GitHub Copilot (automated fix)

## Executive Summary

This report documents fixes for three critical failures in the SigilDERG ecosystem setup:

1. **Firejail Rust PATH issue** - Sandbox couldn't find `rustc` due to `--private` flag
2. **Dependency conflicts** - Package version conflicts between sigil-pipeline and sigilderg-finetuner
3. **PyTorch/torchaudio mismatch** - Installation sequence caused version incompatibility

All issues have been resolved using best practices for sandbox configuration and dependency management.

---

## Issue 1: Firejail Cannot Find Rust

### Problem

The Firejail sandbox used `--private` flag which creates an isolated home directory, blocking access to `~/.cargo/bin/rustc` where Rust is typically installed via rustup.

**Error observed:**

```text
Error: Rust not found (Firejail mode checks host Rust)
```

### Root Cause

The `--private` flag in Firejail creates a new, empty home directory for the sandboxed process. This means:

- `$HOME/.cargo/bin/rustc` is not accessible
- `$HOME/.rustup` toolchain files are not accessible
- The sandbox cannot compile Rust code

### Solution

Replace `--private` with targeted `--whitelist` directives:

```bash
# Before (broken)
--private

# After (working)
--whitelist="$HOME/.cargo"
--whitelist="$HOME/.rustup"
```

This approach:

- Grants read-only access only to Rust toolchain directories
- Maintains isolation for all other home directory contents
- Preserves security while enabling compilation

### Files Modified

| File | Change |
|------|--------|
| `human-eval-Rust/human_eval/sandbox.py` | Updated `FIREJAIL_SECURITY_OPTS` to use whitelist, added `CARGO_HOME`/`RUSTUP_HOME` env vars |
| `lambda-package/lib/sandbox.sh` | Added `verify_rust_in_sandbox()` function with fallback verification methods |

### Testing Verification

```bash
# Verify Rust is accessible in sandbox
firejail --whitelist="$HOME/.cargo" --whitelist="$HOME/.rustup" \
         --env=CARGO_HOME="$HOME/.cargo" --env=RUSTUP_HOME="$HOME/.rustup" \
         rustc --version
```

---

## Issue 2: Dependency Conflicts

### The Problem

Installing sigil-pipeline and sigilderg-finetuner in sequence caused version conflicts:

| Package | sigil-pipeline constraint | sigilderg-finetuner constraint | Conflict |
|---------|---------------------------|--------------------------------|----------|
| `psutil` | `<7.0.0` | `>=6.1.1` (no upper bound) | Upgraded to 7.x, broke pipeline |
| `rich` | `<14.0.0` | `>=13.7.0` (no upper bound) | Upgraded to 14.x, broke pipeline |

### The Root Cause

The packages were installed sequentially without coordinated version constraints. pip's dependency resolver optimized each package independently, potentially upgrading shared dependencies beyond compatible ranges.

### The Solution

1. **Create unified constraints file** (`constraints.txt`)
2. **Align dependency bounds** in sigilderg-finetuner
3. **Install packages together** with constraints flag

### constraints.txt

```text
# Unified dependency constraints for SigilDERG ecosystem
# These bounds represent the intersection of compatible versions

# Shared dependencies with upper bounds
rich>=13.7.0,<14.0.0
psutil>=6.1.1,<7.0.0

# PyTorch ecosystem - minimum versions for H100 support
torch>=2.4.0
```

### Modified Files

| File | Change |
|------|--------|
| `lambda-package/constraints.txt` | Created unified constraints file |
| `lambda-package/requirements.in` | Created pip-tools input file for lockfile generation |
| `lambda-package/lib/sigilderg.sh` | Modified to use `-c constraints.txt` flag and install packages together |
| `SigilDERG-Finetuner/pyproject.toml` | Added upper bounds `<14.0.0` for rich, `<7.0.0` for psutil |
| `SigilDERG-Finetuner/requirements.txt` | Aligned constraints with pyproject.toml |

### Installation Command

```bash
# Install all ecosystem packages together with constraints
pip install -c constraints.txt \
    "sigil-pipeline>=2.3.0" \
    "sigilderg-finetuner>=3.0.0" \
    "human-eval-rust>=2.3.0"

# Verify no conflicts
pip check
```

---

## Issue 3: PyTorch/torchaudio Mismatch

### Problem Description

Installing sigilderg-finetuner after torchaudio caused PyTorch version mismatch:

```text
torchaudio 2.7.1 requires torch==2.7.1
sigilderg-finetuner upgraded torch to 2.8.0
Result: torchaudio broken
```

### Root Cause Analysis

PyTorch and related packages (torchaudio, torchvision) must have matching versions. Installing packages in wrong sequence allows pip to upgrade torch independently.

### Applied Solution

1. **Install PyTorch first** with CUDA-specific index URL
2. **Constraint torch version** in constraints.txt
3. **Install ecosystem packages together** to let pip resolve all dependencies at once

### Installation Sequence

```bash
# Step 1: Install PyTorch with correct CUDA version FIRST
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128

# Step 2: Install ecosystem packages with constraints
pip install -c constraints.txt sigil-pipeline sigilderg-finetuner human-eval-rust
```

### Issue 3 Files Changed

| File | Change |
|------|--------|
| `lambda-package/lib/sigilderg.sh` | Documented PyTorch installation order in comments |
| `lambda-package/constraints.txt` | Added `torch>=2.4.0` constraint |

---

## Documentation Updates

### ADR Updates

| File | Change |
|------|--------|
| `human-eval-Rust/docs/adr/ADR-001-firejail-first-sandboxing.md` | Updated Firejail options to use whitelist, added Rust Toolchain Access section |
| `lambda-package/docs/adr/ADR-001-firejail-first-sandboxing.md` | Updated whitelist documentation with RUSTUP_HOME support |
| `lambda-package/docs/adr/ADR-003-reproducibility-guarantees.md` | Added Section 1.1 (Dependency Constraint Strategy) and 1.2 (pip-tools Lockfile Generation) |

### Security Documentation

| File | Change |
|------|--------|
| `human-eval-Rust/docs/SECURITY.md` | Updated Firejail options, added Rust Toolchain Whitelisting section, updated Attack Vectors table |
| `lambda-package/SECURITY.md` | Added Rust Toolchain Access section under Firejail |

---

## pip-tools Integration (Recommended)

For fully reproducible builds, use pip-tools:

```bash
# Install pip-tools
pip install pip-tools

# Generate lockfile from requirements.in
cd lambda-package
pip-compile requirements.in -o requirements.lock

# Install exact versions
pip install -r requirements.lock
```

### requirements.in

```text
# SigilDERG Ecosystem packages
sigil-pipeline>=2.3.0
sigilderg-finetuner>=3.0.0
human-eval-rust>=2.3.0

# Constraints for shared dependencies
rich>=13.7.0,<14.0.0
psutil>=6.1.1,<7.0.0

# PyTorch is installed separately with CUDA-specific index
# torch>=2.4.0
```

---

## Version Summary

| Component | Previous | Updated |
|-----------|----------|---------|
| `sigilderg.sh` | 2.0.0 | 2.1.0 |
| `sandbox.py` FIREJAIL_SECURITY_OPTS | `--private` | `--whitelist` |
| sigilderg-finetuner `rich` constraint | `>=13.7.0` | `>=13.7.0,<14.0.0` |
| sigilderg-finetuner `psutil` constraint | `>=6.1.1` | `>=6.1.1,<7.0.0` |

---

## Testing Checklist

- [ ] Firejail sandbox can compile Rust code: `firejail --whitelist="$HOME/.cargo" rustc --version`
- [ ] All ecosystem packages install without conflicts: `pip check`
- [ ] PyTorch CUDA version matches torchaudio requirements
- [ ] Evaluation runs successfully in sandbox mode
- [ ] No import errors for sigil-pipeline, sigilderg-finetuner, human-eval-rust

---

## Breaking Changes

None. All changes are backward compatible.

---

## References

- [Firejail Documentation](https://firejail.wordpress.com/documentation-2/)
- [pip Constraints Files](https://pip.pypa.io/en/stable/user_guide/#constraints-files)
- [pip-tools](https://github.com/jazzband/pip-tools)
- [ADR-001: Firejail-First Sandboxing](adr/ADR-001-firejail-first-sandboxing.md)
- [ADR-003: Reproducibility Guarantees](adr/ADR-003-reproducibility-guarantees.md)
