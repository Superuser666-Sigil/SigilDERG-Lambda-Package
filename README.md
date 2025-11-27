# SigilDERG Lambda Package

**Documentation and setup scripts for evaluation of the SigilDERG ecosystem**

This repository contains the evaluation setup script and documentation for running HumanEval-Rust benchmarks on the SigilDERG ecosystem models.

## Quick Start

For complete setup and evaluation instructions, see the **[Evaluation Setup Guide](eval_setup_readme.md)**.

## Ecosystem Overview

The SigilDERG ecosystem consists of three integrated components:

1. **[SigilDERG-Data_Production](https://github.com/Superuser666-Sigil/SigilDERG-Data_Production)** - Generates high-quality Rust code datasets
2. **[SigilDERG-Finetuner](https://github.com/Superuser666-Sigil/SigilDERG-Finetuner)** - Fine-tunes language models on Rust code using QLoRA
3. **[human-eval-Rust](https://github.com/Superuser666-Sigil/human-eval-Rust)** - Evaluates model performance on standardized Rust programming problems

For a comprehensive overview of how these components work together, see the **[SigilDERG Ecosystem Architecture](https://github.com/Superuser666-Sigil/SigilDERG-Data_Production/blob/main/ARCHITECTURE.md)**.

## Repository Contents

- **[`eval_setup.sh`](eval_setup.sh)** - Main entry point and orchestration script for HumanEval-Rust benchmarks
- **[`eval_setup_config.sh`](eval_setup_config.sh)** - Centralized configuration and constants
- **[`lib/`](lib/)** - Modular function libraries for setup and execution:
  - `logging.sh`, `environment.sh`, `system_deps.sh` - Core utilities and validation
  - `python_env.sh`, `pytorch.sh`, `sigilderg.sh` - Python and ML environment setup
  - `rust.sh`, `sandbox.sh`, `cli_tools.sh` - Toolchain and tool installation
  - `evaluation.sh`, `tmux.sh` - Evaluation execution and session management
- **[`scripts/evaluate_humaneval.py`](scripts/evaluate_humaneval.py)** - Standalone Python evaluation script
- **[`eval_setup_readme.md`](eval_setup_readme.md)** - Detailed documentation for the evaluation setup script

## What This Package Provides

This package provides a **reproducible, H100-targeted evaluation pipeline** that can be run end-to-end to evaluate SigilDERG models on the HumanEval-Rust benchmark. The evaluation harness is organized as a modular system for maintainability and clarity. The setup script:

- Provisions a reproducible Python + Rust + GPU environment
- Installs the SigilDERG ecosystem components
- Runs base vs Rust-QLoRA HumanEval-Rust evaluation
- Generates comparison reports for both policy and non-policy modes
- Produces detailed metadata for reproducibility

## Requirements

- **OS**: Ubuntu 22.04 (validated)
- **GPU**: NVIDIA H100 (validated) or other CUDA-capable GPU
- **CPU**: 26+ vCPUs recommended
- **RAM**: 225GB+ recommended
- **Storage**: Fast SSD for datasets and checkpoints

## Usage

```bash
# Make script executable
chmod +x eval_setup.sh

# Non-interactive run (CI/reproducibility)
NONINTERACTIVE=1 ./eval_setup.sh

# Interactive run
./eval_setup.sh
```

For detailed usage instructions, configuration options, and output structure, see the **[Evaluation Setup Guide](eval_setup_readme.md)**.

## Related Documentation

- **[Ecosystem Architecture](https://github.com/Superuser666-Sigil/SigilDERG-Data_Production/blob/main/ARCHITECTURE.md)** - Complete overview of the SigilDERG ecosystem
- **[Evaluation Setup Guide](eval_setup_readme.md)** - Detailed documentation for this evaluation package

## License

Copyright (c) 2025 Dave Tofflemire, SigilDERG Project

