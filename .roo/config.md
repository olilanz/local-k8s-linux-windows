# Roo Project Configuration

## Authoritative Source

- Primary source of truth: `README.md`
- In any conflict between assumptions, scripts, or helper notes and the README, treat the README as authoritative.
- Escalation rule: stop and report conflicts so the README can be updated first, then align implementation.

## README Usage Policy

`README.md` is written first for human understanding of what we are building and how to operate it.

Preferred didactic flow:

1. Purpose and scope
2. High target architecture (Mermaid diagram is optional, not required for every update), at the level of:
   - host OS
   - guest VMs
   - internal vSwitch
   - containerd instances
   - control plane and node join flow
3. Script structure and usage
4. Technical details and considerations

Scope boundary:

- Keep `README.md` mostly high-level.
- Allow brief implementation notes only when they directly affect operator decisions.
- Keep deeper internal implementation details in script headers and stage-local comments unless explicitly agreed for README inclusion.

## Project Intent

Build a deterministic, repeatable, idempotent script set that mimics core AKS-style behavior on local infrastructure:

- Hybrid Kubernetes cluster with Linux and Windows nodes
- Linux VM hosts k0s control-plane foundation
- Windows node joins as worker
- Calico-based networking aligned for Windows compatibility

This environment is for local experimentation, validation, and development workflows, not production deployment.

## Target Architecture

1. Linux VM bootstrap
2. k0s control-plane creation on Linux VM
3. Linux worker participation where applicable
4. Windows worker join
5. Calico networking configured for mixed OS operation

## Non-Negotiable Invariants

1. Networking model must be correct before or at cluster formation boundaries; unsafe network model mutation is rebuild-triggering.
2. Scripts must be deterministic and idempotent at their intended stage scope.
3. Scripts are executed one at a time by a human operator.
4. Script behavior must be explicit and understandable; avoid hidden state and implicit side effects.
5. Script headers must document assumptions and invariants clearly.

## Script Design Principles

1. One script equals one stage with a single clear outcome.
2. Prefer explicit checks, clear preconditions, and controlled resets where required.
3. Keep output clean and high-signal for operators.
4. Include contextual comments that explain why, not just what.
5. Record assumptions in a standard script header section.

## Script Header Standard

Each stage script should begin with a concise header containing:

- Purpose
- Preconditions
- Invariants
- Inputs and environment assumptions
- Idempotency contract
- Expected postconditions
- Safe rerun notes

## Operator Workflow Contract

- Run scripts sequentially, one stage at a time.
- Validate each stage before advancing.
- If a stage reveals drift or invariant violation, resolve before proceeding.
- Any discovered conflict with README guidance must be surfaced and reconciled in README first.

## Development Surface Notes

- Linux-oriented development may later run in WSL.
- Windows-oriented development may run in Visual Studio 2026 or VS Code on Windows.
- Script UX must remain readable to cross-platform operators.

## Change Management Rule

When introducing new intermediate steps:

1. Keep stages simple.
2. Preserve deterministic stage boundaries.
3. Update this configuration and the README together when behavior contracts change.
