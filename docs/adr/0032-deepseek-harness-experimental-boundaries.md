# ADR 0032: DeepSeek Harness stays an isolated experimental app

Date: 2026-10-20
Status: accepted for implementation; release gates remain open.

## Context

PhaseZero already exposes DeepSeek Proxy (`deepsproxy`) and DeepSeek model
providers. Neither represents the official DeepSeek Harness application.
Upstream tag `dsh-v0.2.1-rc.2` resolves to commit
`687f282e8625c6b8d11ff58211a90524be2e4317`; npm publishes
`@deepseek-ai/dsh@0.2.1-rc.2` with an immutable integrity value. This version
is a date-stamped observation, not a permanent recommendation.

Upstream states that Harness is experimental, unaudited, and can run
model-generated code and commands with access to files, processes, network,
and available credentials. File sandbox policy does not restrict network or
processes; Windows ACL enforcement may be partial.

## Decision

- Register `app.deepseek-harness` independently from `app.deepseek-proxy` and
  model-provider choices.
- Install Node and Harness in a per-user, versioned directory using exact
  upstream hashes and a committed npm lockfile. Stage before activation; keep
  the previous runtime until activation succeeds; remove only owned files.
- Keep account login and API-key setup in separate `DSH_HOME` trees. Never
  copy either credential into PhaseZero state, argv, status, or logs. Do not
  switch routes or send inference automatically.
- Require a user-selected workspace and show the requested file policy,
  approval mode, and observed enforcement separately. Report `partial` or
  `unknown` as such; never call it full isolation.
- Launch from an empty, route-private directory. Upstream loads `.env` from
  its invoking directory before a workspace is selected and has no Web CLI
  flag to preselect that workspace; PhaseZero records the requested folder
  and asks the user to confirm it in Harness's workspace picker. This prevents
  a selected project's `.env` from silently changing the account/API route.
- The API route keeps its key in Harness's own credential store in the API
  `DSH_HOME`. PhaseZero does not copy the key through process arguments,
  environment, state, or logs. Account route uses its separate Harness home.
  Same-user processes remain inside the trust boundary documented upstream.
- Keep third-party plugins/MCPs opt-in. Proxy and 9Router routes remain
  advanced and blocked while request-bound account grants cannot be enforced.
- Start only on user request, bind only to loopback, and open the authenticated
  Web UI through the upstream token handoff held in volatile process memory.
  Tokenized startup URLs never enter persistent logs or status output.
- Require 512 MiB free disk and 2 GiB measured available memory before install;
  recheck memory before a new start and cap Node V8 old-space at 2 GiB. This
  does not bound native allocations, child processes, CPU, or external tools;
  no complete resource sandbox is claimed.
- Keep all surfaces marked Experimental until the applicable account, clean
  Arch/Windows, sandbox, recovery, UI, and cost gates pass.

## Consequences

Installing the package does not start it, enable autostart, or change host
routes. A successful package install is not evidence of login, quota, sandbox
enforcement, or a working model. Unavailable external gates remain explicit
and do not block fixture-backed implementation work.
