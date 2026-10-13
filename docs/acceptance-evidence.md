# Acceptance evidence — which solutions are actually proven

Base: audit 2026-09-06 (`2180c94`) + remediation Fase 0–5 (branches
`codex/aud-fase{0..5}`). `stable` needs implementation + behavioral
test + CI + reproduced-defect regression. Anything else is `preview`
or `blocked`, no matter how green the unit tests are.

Legend for CI: hermetic (fixture, no daemon), disposable (real Docker
in CI), arch (clean Arch container), win-ci (Pester on Windows),
manual (needs a human + real hardware/credentials).

## Homelab apps

| Solution | Maturity | Proven | Gaps |
|---|---|---|---|
| Jellyfin | preview | Compose valid; media ro; recipe + probe; pins/rotation | library select/play, GPU, index E2E |
| Syncthing | preview | Compose valid; recipe + probe | second-device pairing round-trip |
| Vaultwarden | preview | Disposable enable→HTTP→disable; backup/restore round-trip; recipe | first-user onboarding E2E; TLS account flow |
| Uptime Kuma | preview | Compose valid; recipe + probe | monitor provision + alert cycle |
| Portainer | preview | Socket-proxy allowlist; compose valid | op allow/deny matrix via proxy |
| Nextcloud | preview | MariaDB wiring; recipe + probe | account, upload/download, cron, trusted-hosts |
| Prometheus | preview | Compose valid; recipe + probe | scrape targets + alert on failure |
| Grafana | preview | Compose valid; recipe + probe | datasource + dashboard with real data |
| Paperless | preview | Broker + PAPERLESS_REDIS + readiness; consume/export; recipe | PDF import → searchable OCR E2E |
| n8n | preview | Compose valid; recipe + probe | workflow run + credential restore |
| Backup/restore | hardening | Hermetic + disposable data equality + exactness (extra/posterior) | DB-under-write on real engines |
| Lifecycle states | hardening | Hermetic desired/observed/deferred/failed matrix | daemon-flap soak |

## AI / proxies

| Solution | Maturity | Proven | Gaps |
|---|---|---|---|
| kimi/qwen/deeps proxies | supported (install-gated) | Provenance pins; transactional build; manifest parity; login/browser flows hermetic | real build + login + chat on clean host |
| mimo-ai-proxy | supported (API) | Key validation + inference probe hermetic; secret redaction | real supervised inference; Windows parity |
| 9Router | external manager | Units/watchdog/env hermetic | real routes; npm/socat bootstrap on clean host |
| qwen-worker/antigravity/ollie/airlock/unlimited | experimental | Catalog presence + provenance block | snapshots + runtime proof each |
| Hermes | blocked/experimental | Gate + manifest honesty; optional skip | audited distribution; 9Router convoys |
| LLM server (Ollama) | hardening | Foreground pull + inference proof hermetic | real pull + cold-load timing |
| Policy broker | install-policy | Scope labels; action matrix hermetic | execution broker is ADR future work |

## Platform / packaging

| Solution | Maturity | Proven | Gaps |
|---|---|---|---|
| Arch package | hardening | arch-clean-host CI: live repo resolution (15 profiles), asset build+install, `pz` entrypoints, fail-closed status | upgrade path from last release |
| Debian/RPM packages | as-built | `pz` wrapper shipped (same file) | install test per family |
| Profiles (15) | hardening | Ghost purge; multilib bootstrap; optional mechanism; ordering + propagation hermetic | full `pz install` per profile on clean Arch |
| Windows bootstrap | hardening | Graph + resume states; manifest parity reader (Pester in win-ci) | native clean install + reboot + engine |
| Pairing/SSH | hardening | Port/key/first-contact matrix hermetic | real two-host run |
| Onboarding wizard | hardening | Real discover/pair/plan-bind (Qt offscreen) | usability study |
| Objectives home | new | 5 journeys render + entry actions resolve; narrow viewport | usability study |

## Reconciling history

Roadmap `verified` marks predating 2026-09-06 used broader language
than the gates above. They are preserved as history, not deleted.
This file is the current source of truth for what each solution has
actually proven; anything marked `preview`/`blocked` here stays that
way until its Gaps column gains a linked job or artifact.
