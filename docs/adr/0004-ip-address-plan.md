# ADR-0004: One reviewed address plan; subnet CIDRs derived, not chosen

**Status:** Accepted · **Date:** 2026-11

## Context

Peering requires non-overlapping CIDRs. Tight routes and cross-region SG rules need the *other* VPC's exact subnet CIDRs. Reading them from the other stack's state couples every stack to every other.

## Decision

- `live/prod/network-plan.yaml` is the single source of truth for VPC CIDRs, AZs, accounts, regions and **subnet layouts per role** (hub, spoke).
- Subnet CIDRs are computed as `cidrsubnet(vpc_cidr, newbits, netnum_base + az_index)` by the `network_plan` module. Any stack can compute any VPC's subnet CIDRs without remote state. Only resource IDs (VPC, route tables) come from remote state, and only in `connectivity`.
- Each VPC is a /16 from 10.0.0.0/8: hubs 10.10–10.19, spokes 10.20, 10.30, 10.40, 10.50, with the next /16 in each block reserved for that jurisdiction's DR VPC.
- The plan is mirrored into AWS VPC IPAM pools (per jurisdiction) so nothing created outside this repo can take an overlapping range.

## Consequences

- An address change is always a visible, reviewed diff to one file.
- Changing the layout of an existing VPC would replace subnets, so layouts are append-only (new tiers use new netnums).
