# Rule Zero Approach

## Overview

The SigilDERG ecosystem is built on a foundational principle called **Rule Zero**:

> **"If an output cannot explain itself, it has no trust."**

This principle guides every component of the ecosystem, from data generation to model
fine-tuning to evaluation. The Lambda Package serves as the primary validation and
demonstration of this approach.

## What is Rule Zero?

Rule Zero establishes that all AI-generated outputs must be:

1. **Auditable** - Every decision can be traced back to its inputs and reasoning
2. **Explainable** - The logic behind outputs can be understood by humans
3. **Verifiable** - Claims can be checked against objective criteria
4. **Reproducible** - Given the same inputs, the same outputs are produced

In the context of Rust code generation, this means:

- Generated code must compile (verifiable by `rustc`)
- Generated code must pass linting (verifiable by `clippy`)
- Generated code must be functionally correct (verifiable by tests)
- The evaluation process must be reproducible (version-pinned dependencies)

## How Each Ecosystem Component Implements Rule Zero

### sigil-pipeline (Data Generation)

The sigil-pipeline generates high-quality Rust training data with Rule Zero principles:

- **Traceable Sources**: All code comes from vetted crates on crates.io
- **Quality Filtering**: Only code that compiles and passes clippy is included
- **Structured Output**: Data is formatted in auditable JSONL with metadata
- **Provenance**: Each sample records its source crate and version

### sigilderg-finetuner (Model Training)

The finetuner trains models on Rule Zero-compliant datasets:

- **Validated Inputs**: Only ingests data from sigil-pipeline
- **Reproducible Training**: Seed-controlled, version-pinned dependencies
- **Checkpoint Metadata**: Training configuration captured at each checkpoint
- **Policy Enforcement**: Optional policy hooks enforce code quality during generation

### human-eval-rust (Evaluation)

The evaluation harness validates outputs against objective criteria:

- **Compilation Verification**: Every completion is compiled with `rustc`
- **Static Analysis**: Clippy warnings are tracked and reported
- **Functional Correctness**: Test cases verify behavioral correctness
- **Sandboxed Execution**: Firejail isolation prevents untrusted code impact
- **Comprehensive Metrics**: pass@k, compile rate, main-free rate, clippy pass rate

### lambda-package (Orchestration)

This package ties everything together for grant reviewers:

- **Reproducible Environment**: Exact Python, PyTorch, and Rust versions
- **Version Guarantees**: Minimum versions for all ecosystem components
- **Metadata Capture**: Complete environment snapshot in `eval_metadata.json`
- **Comparison Reports**: Human-readable and machine-readable results

## The Reasoning Chain

At its core, Rule Zero is implemented through **Reasoning Chains** - structured
records that capture:

```json
{
  "input": "User prompt or request",
  "context": "Resolved context from canonical sources",
  "reasoning": "Concise, checkable explanation",
  "suggestion": "Proposed output",
  "verdict": "Allow | Deny | Defer | ManualReview",
  "trust": {
    "score": 0.0,
    "allowed": false
  }
}
```

For the Rust code generation use case:

- **Input**: HumanEval prompt (function signature + docstring)
- **Context**: Model weights, temperature, sampling parameters
- **Reasoning**: The model's generation process (implicit in weights)
- **Suggestion**: Generated Rust code completion
- **Verdict**: Determined by compilation + tests + policy checks
- **Trust Score**: Derived from pass@k metrics

## Future Integration

The fine-tuned model produced by this ecosystem is designed to integrate into
the [Sigil MMF Codex](https://github.com/Superuser666-Sigil/sigil-mmf-codex-priv)
as a **Rust Mentor** module.

In this role, the model will:

1. Receive Rust programming questions from users
2. Generate responses with explicit reasoning
3. Have its outputs validated against Rust safety policies
4. Persist interactions in an auditable canonical store
5. Build trust incrementally through correct, verifiable outputs

This integration represents the culmination of the Rule Zero approach:
a code assistant that earns trust through demonstrable correctness rather than
claiming it through assertion.

## Validation Through This Package

The Lambda Package demonstrates Rule Zero compliance by:

1. **Provisioning a reproducible environment** with version-pinned dependencies
2. **Running HumanEval-Rust benchmarks** on both base and fine-tuned models
3. **Capturing comprehensive metadata** for audit and reproduction
4. **Generating comparison reports** showing measurable improvements
5. **Executing in isolated sandboxes** preventing untrusted code impact

Grant reviewers can use this package to independently verify that the SigilDERG
ecosystem produces measurable, reproducible improvements in Rust code generation
quality.

## References

- [SigilDERG Ecosystem Architecture](https://github.com/Superuser666-Sigil/SigilDERG-Data_Production/blob/main/ARCHITECTURE.md)
- [Sigil MMF Codex - Rule Zero Manifest](https://github.com/Superuser666-Sigil/sigil-mmf-codex-priv/blob/main/codex_manifest_rule_zero.md)
- [HumanEval-Rust Documentation](https://github.com/Superuser666-Sigil/human-eval-Rust)

