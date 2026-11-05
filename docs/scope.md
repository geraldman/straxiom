# STRAXIOM: Scope Statement

Agentic SOC with agent red-teaming. Aligned with project brief v1.2 (2026-11-05). Code licensed Apache-2.0 (D-020).

## Thesis

SOC teams are adopting LLM agents to triage alerts. But an agent that reads attacker-controlled log content and holds query tools is itself an attack surface. STRAXIOM builds a small agentic SOC on open tooling, then attacks it, hardens it, and measures the result.

## What gets built

1. A reproducible lab (VMs plus Docker Compose) that produces endpoint and network telemetry in OpenObserve.
2. Detection-as-code: about 10 rules, tested in CI, with measured precision and false-positive rate.
3. A UEBA-style baseline that enriches alerts.
4. An agentic triage and hunting system with analyst approval, a full audit trail, and hard guardrails.
5. A repeatable red-team suite covering five attack categories, with before-and-after results across defense layers D0 to D5.
6. Reusable LLM monitoring (OpenTelemetry-based) demonstrated on a small RAG app.
7. A small specialized local model, prompted first and fine-tuned only if a go/no-go gate justifies it.

## Priority tiers

| Tier | Items |
| --- | --- |
| Must-have | Pipeline to OpenObserve, about 10 detections with CI, triage agent with an allowlisted query tool and audit log, red-team harness covering all five categories, threat model, README, demo |
| Should-have | UEBA, natural-language hunting, approval UI, notifications, CI running the red-team suite |
| Stretch | Full Suricata coverage, RAG app detections, ATT&CK heatmap, live Windows victim, fine-tune |

## Non-goals

- Autonomous remediation. The agent recommends, and nothing executes.
- Multi-tenant features.
- Real-time scale.
- A production-grade UI.
- Attack categories beyond the five in the plan.
- Replacing OpenObserve's own features.
- A Wazuh 5.x migration (post-project idea).
- A custom Sysmon replacement (D-018).

## Definition of done

- The README rebuilds the lab on a clean machine (tested, not assumed).
- At least 10 detections with CI and per-rule metrics.
- At least 200 labeled evaluation cases, at least half benign or hard negatives, with a held-out set untouched until the final run.
- Five red-team categories, each with at least 50 payloads and at least 5 runs per configuration, plus a before-and-after table reporting attack success and benign utility at each defense layer.
- A published threat model and a limitations section.
- A 2 to 3 minute demo video.
- Every tool version, image and kernel recorded in `versions.yml`.

## Constraints

- One engineer, full-time, 30+ hours a week, four weeks (the schedule is the engineer's statement, unverified).
- Lab laptop with about 13.9 GB usable RAM (about 8.0 GB available for VMs). One Linux victim at a time next to the stack VM.
- Isolated host-only lab network (192.168.100.0/24). Any internet path is allowlisted and logged. During evaluation, the only allowed route is to the model host.
- Mostly free tooling. A hosted API baseline and a cloud GPU for fine-tuning are optional.

## If the schedule slips

At the end of week 2, cut in this order: live Windows VM (use datasets), fine-tune, RAG app detections, natural-language hunting polish, Suricata (keep Zeek), ATT&CK heatmap.

**Never cut:** the red-team harness, the audit log, the threat model, and the evaluation.

## Rules of the build

- Attacks run only inside the isolated lab, against snapshotted VMs, with standard benign tooling (Atomic Red Team). No real systems, credentials or personal data.
- Log, dataset and feed content is untrusted data, never instructions.
- Metrics are defined before runs, stochastic runs are repeated, spread and failures are reported, and negative results are published.
- No secrets in the repo. Only generic payloads are published.
- Every design decision is recorded in `docs/decisions.md`.
