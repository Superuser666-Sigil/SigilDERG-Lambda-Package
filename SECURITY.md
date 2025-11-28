# Security Policy

## Overview

The Lambda Package executes LLM-generated Rust code as part of the HumanEval-Rust
benchmark. This code is **untrusted** and may contain malicious patterns. Security
is a primary concern.

## Sandboxing

### Firejail (Default)

All code execution uses [Firejail](https://firejail.wordpress.com/) by default.
Firejail provides:

- **Process isolation** - Separate namespaces for PID, network, mount
- **Filesystem restrictions** - Read-only mounts, private /tmp, whitelisted Rust toolchain
- **Network isolation** - No network access by default
- **Resource limits** - Memory, CPU, fork bomb prevention
- **seccomp filtering** - Blocks dangerous system calls

**Rust Toolchain Access:**

The sandbox uses `--whitelist` instead of `--private` to allow access to the Rust
toolchain while maintaining security:

- `--whitelist=$HOME/.cargo` - Cargo binaries and registry cache
- `--whitelist=$HOME/.rustup` - Rustup toolchain installations

This approach allows `rustc` and `cargo` to function within the sandbox while
blocking access to all other home directory contents.

### Unsandboxed Mode

Running without a sandbox is **strongly discouraged** and requires:

1. Setting `SANDBOX_MODE=none` environment variable
2. Typing "YES" when prompted for confirmation
3. Understanding that generated code runs with user privileges

**Never run unsandboxed with untrusted models or on production systems.**

## Supported Versions

| Version | Supported |
|---------|-----------|
| 2.0.x   | Yes       |
| 1.x.x   | No        |

## Reporting a Vulnerability

If you discover a security vulnerability:

1. **Do NOT** open a public issue
2. Email: <davetmire85@gmail.com>
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

### Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial assessment**: Within 7 days
- **Resolution timeline**: Communicated after assessment

### Safe Harbor

We consider security research conducted in good faith to be authorized and will
not pursue legal action against researchers who:

- Make a good faith effort to avoid privacy violations and data destruction
- Only interact with accounts they own or have explicit permission to test
- Do not exploit vulnerabilities beyond demonstration of the issue
- Report findings promptly and do not disclose publicly before resolution

## Security Measures

### Code Execution

- All generated code runs in Firejail sandbox by default
- Pattern blocklist rejects obviously dangerous code
- Timeouts prevent infinite loops and resource exhaustion
- Parallel execution limits prevent fork bombs

### Ecosystem Packages

- Minimum versions enforced for security fixes
- PyPI-first installation with GitHub fallback
- Import validation catches syntax/import errors
- Version verification ensures expected packages

### Environment

- Ubuntu 22.04 and H100 validation by default
- Python 3.12.11 pinned via pyenv
- Complete environment captured in metadata

## Best Practices

### For Reviewers

1. Use a dedicated Lambda instance (not shared infrastructure)
2. Do not disable sandboxing unless absolutely necessary
3. Review `eval_metadata.json` for complete environment info
4. Check `setup.log` for any warnings during setup

### For Contributors

1. Never commit API keys or secrets
2. Test security-sensitive changes with sandboxing enabled
3. Document any security implications in PRs
4. Follow secure coding practices for bash and Python

## Contact

- **Security issues**: <davetmire85@gmail.com>
- **General issues**: <https://github.com/Superuser666-Sigil/SigilDERG-Lambda-Package/issues>

