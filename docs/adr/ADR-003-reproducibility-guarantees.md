# ADR-003: Reproducibility Guarantees

## Status

Accepted

## Context

The Lambda AI grant requires demonstrating measurable improvements in Rust code
generation quality. For grant reviewers to validate our claims, they must be able
to reproduce our results exactly.

Reproducibility challenges include:

1. **Package versions** - PyPI packages can change between runs
2. **Python versions** - Lambda base image has Python 3.10, we need 3.12
3. **CUDA versions** - Different instances may have different CUDA
4. **Random seeds** - LLM generation is stochastic
5. **Environment differences** - Paths, environment variables, etc.

## Decision

We implement **multi-layer reproducibility guarantees**:

### 1. Version Pinning

- Python version pinned to 3.12.11 via pyenv
- Ecosystem packages have minimum version requirements:
  - `human-eval-rust >= 2.3.0`
  - `sigil-pipeline >= 2.3.0`
  - `sigilderg-finetuner >= 3.0.0`
- PyTorch version selected based on detected CUDA version
- **Unified constraints file** (`constraints.txt`) ensures compatible versions across all packages:
  - Shared dependencies pinned to intersection of compatible ranges
  - Prevents pip dependency resolver from upgrading shared packages to incompatible versions
  - Used with `pip install -c constraints.txt` flag

### 1.1 Dependency Constraint Strategy

The ecosystem packages have overlapping dependency requirements that can conflict:

| Package | `rich` constraint | `psutil` constraint |
|---------|-------------------|---------------------|
| sigil-pipeline | `<14.0.0` | `<7.0.0` |
| sigilderg-finetuner | `>=13.7.0,<14.0.0` | `>=6.1.1,<7.0.0` |

The `constraints.txt` file captures the intersection:
```
rich>=13.7.0,<14.0.0
psutil>=6.1.1,<7.0.0
torch>=2.4.0
```

Installation uses: `pip install -c constraints.txt package1 package2 ...`

### 1.2 pip-tools Lockfile Generation

For fully reproducible builds, use `pip-tools` to generate a lockfile:

```bash
pip install pip-tools
pip-compile requirements.in -o requirements.lock
pip install -r requirements.lock
```

The `requirements.in` file lists all ecosystem packages with their constraints.
The generated `requirements.lock` contains exact versions of all transitive dependencies.

### 2. Environment Validation

- Strict OS check: Ubuntu 22.04 only (bypassable with `SKIP_ENV_CHECK=1`)
- GPU check: H100 only by default (bypassable)
- All checks logged with clear warnings when bypassed

### 3. Seed Control

- Random seed set to 1234 by default (configurable via `--seed` CLI argument or `SEED` environment variable)
- Seeds set for: Python random, NumPy, PyTorch (CPU and CUDA)
- Same seed produces same outputs given same model weights
- Environment variable allows seed configuration without modifying command-line arguments, useful for smoke tests and automated runs

### 4. Metadata Capture

`eval_metadata.json` captures:

```json
{
  "timestamp_utc": "2025-01-01T00:00:00Z",
  "host": "instance-hostname",
  "os": "Linux-6.x.x...",
  "python_version": "3.12.11",
  "device": "cuda",
  "cuda_available": true,
  "torch_cuda_device_name": "NVIDIA H100 80GB HBM3",
  "seed": 1234,
  "args": { ... },
  "packages": {
    "torch": "2.4.0",
    "transformers": "4.44.0",
    "human_eval": "2.1.0",
    ...
  },
  "pip_freeze": "complete pip freeze output"
}
```

### 5. Deterministic Defaults

- Batch size: 32 (optimal for H100)
- Workers: 24 (26 vCPUs - 2 reserved)
- Timeout: 10 seconds per sample
- Temperature: 0.2 (low variance)
- top_p: 0.95

## Consequences

### Positive

- **Verifiable claims** - Reviewers can reproduce exact results
- **Debug capability** - Environment differences are captured
- **Auditability** - Complete record of how results were produced
- **Confidence** - Results are not artifacts of lucky runs

### Negative

- **Strictness** - Setup may fail on non-standard environments
- **Overhead** - Metadata collection adds some runtime
- **Maintenance** - Version pins need periodic updates
- **Inflexibility** - Reproducibility limits experimentation

## Alternatives Considered

### Floating Versions

Using `pip install package` without versions would:

- Simplify setup scripts
- But make reproduction impossible after package updates
- Not acceptable for grant evaluation

### Container Snapshots

Pre-built containers with all dependencies would:

- Guarantee exact reproducibility
- But obscure the installation process
- And be harder to update

### Hash-Based Verification

Verifying package hashes would:

- Ensure bit-exact packages
- But be fragile to minor updates
- Add complexity without proportional benefit

## Related

- [ADR-002: Ecosystem Orchestration](ADR-002-ecosystem-orchestration.md)
- [Rule Zero Approach](../RULE_ZERO_APPROACH.md)

