# Architecture Decision Records (ADRs)

This directory contains Architecture Decision Records (ADRs) for the Lambda Package.

## What is an ADR?

An Architecture Decision Record captures an important architectural decision made
along with its context and consequences. ADRs help future maintainers understand
why certain decisions were made.

## ADR Format

Each ADR follows this structure:

1. **Status** - Proposed, Accepted, Deprecated, Superseded
2. **Context** - What is the issue that we're seeing that is motivating this decision?
3. **Decision** - What is the change that we're proposing and/or doing?
4. **Consequences** - What becomes easier or more difficult because of this change?
5. **Alternatives Considered** - What other options were evaluated?

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [ADR-001](ADR-001-firejail-first-sandboxing.md) | Firejail-First Sandboxing | Accepted |
| [ADR-002](ADR-002-ecosystem-orchestration.md) | Ecosystem Orchestration | Accepted |
| [ADR-003](ADR-003-reproducibility-guarantees.md) | Reproducibility Guarantees | Accepted |

## Creating a New ADR

1. Copy [template.md](template.md) to `ADR-NNN-short-title.md`
2. Fill in all sections
3. Update this README with the new ADR
4. Submit for review

