# ADR-001: Firejail-First Sandboxing

## Status

Accepted

## Context

The HumanEval-Rust benchmark requires executing LLM-generated Rust code to verify
functional correctness. This code is untrusted and potentially malicious - it could
attempt to access the filesystem, network, or execute arbitrary commands.

Previous versions of the evaluation harness supported Docker-based sandboxing, but
Docker adds significant overhead and complexity, especially on Lambda Labs instances
where container setup is not always straightforward.

We needed a sandboxing solution that:

1. Provides strong isolation for untrusted code execution
2. Works reliably on Ubuntu 22.04 (Lambda Stack base image)
3. Has minimal setup overhead
4. Allows rustc/cargo to run normally within the sandbox
5. Fails safely if sandboxing is unavailable

## Decision

We adopt a **Firejail-first** sandboxing strategy:

1. **Firejail is the primary sandbox** - All code execution uses Firejail by default
2. **Explicit opt-in for unsandboxed** - Running without sandbox requires typing "YES"
3. **Automatic installation** - The setup script installs Firejail if missing
4. **Graceful degradation** - Clear prompts guide users when Firejail unavailable
5. **No Docker dependency** - Removed Docker as a sandboxing option

The sandbox provides:

- Process isolation via Linux namespaces
- Filesystem restrictions (read-only mounts, private /tmp)
- Network isolation (no network by default)
- Resource limits (memory, CPU, fork bombs)
- seccomp filtering for dangerous syscalls

## Consequences

### Positive

- **Simpler setup** - No Docker daemon required
- **Faster execution** - Lower overhead than containers
- **Better Lambda compatibility** - Works out-of-box on Lambda Stack
- **Explicit security stance** - Users must consciously opt-in to unsandboxed mode
- **Auditable** - Firejail configuration is transparent in bash scripts

### Negative

- **Linux-only** - Firejail does not work on macOS or Windows
- **No Windows testing** - Developers on Windows cannot test sandboxed execution
- **Requires sudo** - Firejail installation needs sudo access
- **Learning curve** - Team needs to understand Firejail profiles

## Alternatives Considered

### Docker-Based Sandboxing

Docker provides excellent isolation but:

- Requires daemon running with proper permissions
- Container image management adds complexity
- Startup overhead is significant for per-sample execution
- Lambda Labs instances sometimes have Docker issues

### bubblewrap

bubblewrap (bwrap) is another namespace-based sandbox but:

- Less feature-rich than Firejail
- Requires more manual configuration
- Smaller community and documentation

### No Sandboxing with Code Analysis

Static analysis could detect dangerous patterns but:

- Cannot catch all malicious code
- False positives would reduce benchmark accuracy
- Sophisticated attacks could evade pattern matching

## Related

- [human-eval-rust Sandboxing](https://github.com/Superuser666-Sigil/human-eval-Rust)
- [Firejail Documentation](https://firejail.wordpress.com/)

