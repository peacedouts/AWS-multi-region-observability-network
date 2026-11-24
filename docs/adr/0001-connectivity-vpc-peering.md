# ADR-0001: Inter-region VPC peering in a dual hub-and-spoke topology

**Status:** Accepted · **Date:** 2026-11

## Context

A central API layer must reach data services in four regional VPCs (US, EU, CA, APAC), each in its own account and region. Regional VPCs must never be able to reach each other (residency). The connection count today is small (2 hubs × 4 regions), and new jurisdictions will be added over time. Some existing spokes may have been addressed without coordination.

## Options considered

| | VPC peering | Transit Gateway (+ TGW peering) | PrivateLink (cross-region) | Cloud WAN |
|---|---|---|---|---|
| Spoke↔spoke isolation | **By default** (non-transitive) | Must be engineered with TGW route tables | By default (service-level) | Policy-based segments |
| Recurring cost | Data transfer only | Per attachment-hour + per-GB processing | Per endpoint-hour + per-GB | Highest |
| Bandwidth / path | No bottleneck, no device in path | TGW in path | NLB + endpoint in path | Core network in path |
| Overlapping CIDRs | Not supported | Not supported | **Supported** | Not supported |
| Native metrics | **None** | Per attachment | Endpoint + NLB | Yes |
| Cross-region SG references | No | No | n/a | No |
| Operational complexity | Low at this scale; O(hubs × spokes) connections | Medium | Medium (per-service endpoints) | High |

## Decision

Use **inter-region VPC peering**: each hub peers with every spoke (8 connections), and the two hubs peer with each other (1 connection) for a cross-hub fallback path. Routes on both sides are limited to specific subnets (hub app tier ↔ spoke interconnect tier), enforced by a module precondition.

## Consequences

- **Good:** the isolation that residency needs comes from AWS semantics, not from configuration we could get wrong. Lowest cost and latency. Simple, auditable route tables.
- **Bad:** no native metrics, so we build a probe matrix (see `docs/monitoring.md`). SG rules across the boundary must use CIDRs. The mesh grows with hubs × spokes.
- **Revisit when:** more than ~10–15 VPCs, on-prem/hybrid connectivity is needed, or a spoke's CIDR overlaps and can't be changed. In that last case only that spoke moves to PrivateLink: the hub calls a cross-region interface endpoint for the gateway's NLB.
- **Contract that makes this reversible:** the hub only ever talks to *the regional gateway in the interconnect tier*. Swapping the transport under that contract changes no service, SG model, audit or alarm.
