# ADR-002: Ecosystem Orchestration

## Status

Accepted

## Context

The SigilDERG ecosystem consists of three main packages:

1. **sigil-pipeline** - Generates high-quality Rust training datasets
2. **sigilderg-finetuner** - Fine-tunes LLMs on Rust code using QLoRA
3. **human-eval-rust** - Evaluates Rust code generation quality

These packages are developed independently but must work together seamlessly for
the Lambda AI grant demonstration. We needed an orchestration layer that:

1. Provisions a complete, reproducible environment from scratch
2. Installs all ecosystem components with verified versions
3. Runs comparative evaluations between base and fine-tuned models
4. Produces human-readable and machine-readable results
5. Captures complete metadata for reproducibility

## Decision

We create **lambda-package** as a dedicated orchestration layer:

1. **Bash-based setup** - `eval_setup.sh` handles environment provisioning
2. **Modular library structure** - Each concern in its own `lib/*.sh` file
3. **Python evaluation driver** - `evaluate_humaneval.py` runs benchmarks
4. **PyPI-first with GitHub fallback** - Resilient package installation
5. **tmux persistence** - Evaluations survive SSH disconnections
6. **Comprehensive metadata capture** - `eval_metadata.json` records everything

The orchestration flow:

```
eval_setup.sh
├── eval_setup_config.sh (configuration)
├── lib/logging.sh (colored output)
├── lib/environment.sh (OS/GPU validation)
├── lib/system_deps.sh (apt packages)
├── lib/python_env.sh (pyenv + venv)
├── lib/pytorch.sh (PyTorch + Flash Attention)
├── lib/sigilderg.sh (ecosystem packages)
├── lib/rust.sh (Rust toolchain)
├── lib/sandbox.sh (Firejail verification)
├── lib/cli_tools.sh (GitHub/HuggingFace CLIs)
├── lib/evaluation.sh (script deployment)
└── lib/tmux.sh (session management)
```

## Consequences

### Positive

- **Single entry point** - One command provisions everything
- **Idempotent** - Safe to re-run; skips completed steps
- **Transparent** - All logic visible in bash scripts
- **Portable** - Works on any Ubuntu 22.04 + H100 instance
- **Auditable** - Grant reviewers can inspect entire process
- **Modular** - Easy to update individual components

### Negative

- **Bash complexity** - Large bash scripts can be hard to debug
- **Platform-specific** - Only validated for Ubuntu 22.04 + H100
- **Network dependency** - Requires internet for package downloads
- **Long setup time** - Full provisioning takes 15-30 minutes

## Alternatives Considered

### Container-Based Orchestration

Pre-built Docker images would simplify setup but:

- Obscures the installation process from reviewers
- Requires Docker availability (not always reliable on Lambda)
- Large image sizes increase startup time
- Updates require image rebuilds

### Ansible/Terraform

Infrastructure-as-code tools provide reproducibility but:

- Add significant complexity for a single-machine setup
- Require tool installation before use
- Overkill for this use case

### Python-Only Setup

A single Python script could handle everything but:

- Python version management is the first step (chicken-and-egg)
- Bash is better for system package installation
- Hybrid approach leverages strengths of each

## Related

- [ADR-001: Firejail-First Sandboxing](ADR-001-firejail-first-sandboxing.md)
- [ADR-003: Reproducibility Guarantees](ADR-003-reproducibility-guarantees.md)
- [SigilDERG Architecture](https://github.com/Superuser666-Sigil/SigilDERG-Data_Production/blob/main/ARCHITECTURE.md)

