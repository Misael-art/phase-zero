# ADR 0005 — Install policy is not execution sandbox

Date: 2026-09-07. Context: PZ-AUD-023.

## Status

Accepted (delimitation). The runtime execution broker is future work.

## Context

`linux/server/ai-policy-broker.sh` gates five install/pull classes
(`ollama-pull`, `openclaw-install`, `hermes-install`, …) in
conservative/permissive modes. Its verdicts were surfaced next to agent
state (`securityState.policyActive`), inviting the reading that agents
run inside a sandbox. They do not.

## Decision

1. The broker is labeled `scope: "install-policy"` with
   `executionEnforced: false` in every output (status/check/list) and in
   the homelab aggregate `securityState`. No gate is removed; the label
   removes the false implication.
2. Runtime tool execution stays bounded by each caller's allowlist:
   the Homelab agent only runs allowlisted `pz` subcommands with
   metacharacter rejection, single-use pairing, sessions, rate limits
   and an audit log (`linux/server/homelab_agent.py`, contract-tested).
   The dashboard web additionally requires session + CSRF.
3. A true execution broker (identity, quotas, approvals,
   filesystem/egress isolation, idempotency) needs its own ADR, threat
   model and adapters. Until it exists, no UI copy may call install
   policy a sandbox.

## Consequences

- `policyActive: true` never proves an action was safely executed; it
  proves an install class is currently gated.
- Tests assert the scope fields so the label cannot silently regress.
- Chat answered via gateway, tool executed under policy, and memory
  written to the right workspace remain three separate proofs with
  three separate test surfaces.
