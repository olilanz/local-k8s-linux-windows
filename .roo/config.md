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

## Shared Helper Usage Policy

To keep stage scripts simple for human readers:

1. Place reusable privilege and command wrappers in [`scripts/lib/common.sh`](scripts/lib/common.sh).
2. Use [`require_privileged_access()`](scripts/lib/common.sh:89) instead of re-implementing root/sudo checks per script.
3. Use [`as_root()`](scripts/lib/common.sh:109) for privileged commands rather than raw `sudo` in stage scripts.
4. Use [`k0s_kubectl()`](scripts/lib/common.sh:117) for cluster API calls that require privilege.
5. Keep stage scripts focused on stage intent and operator-readable flow; move plumbing into shared helpers.

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

## Environment Hygiene and Rebuild Policy

- Iterative script testing can contaminate local cluster state.
- Treat unexpected behavior as potential environment contamination before assuming script logic failure.
- When contamination is suspected, run `99-cleanup.sh` and then reboot before rebuilding.
- A cleanup-plus-reboot cycle is expected periodically during development, especially after Kubernetes network configuration changes.

## Script Execution Order Policy

- After reboot, rebuild sequentially in numeric script-name order.
- Execute one stage at a time and validate stage outcomes before continuing.
- Do not skip ordering guarantees during recovery or test rebuilds.

## Iterative Testing Contract

- Scripts may be executed repeatedly during development and troubleshooting.
- Stage scripts must remain idempotent at their declared stage boundary.
- Incremental script improvement is expected, but reruns must stay safe and deterministic.

## Logging Strategy for Stage Scripts

- Prefer per-run log files using `logs/<script-name>-<timestamp>.log`.
- Keep console output high-signal by mirroring key progress lines only.
- Preserve detailed command and diagnostic output in the log files for post-run analysis.

## Change Management Rule

When introducing new intermediate steps:

1. Keep stages simple.
2. Preserve deterministic stage boundaries.
3. Update this configuration and the README together when behavior contracts change.
