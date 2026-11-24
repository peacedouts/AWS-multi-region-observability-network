# ADR-0003: Two active-active hubs and a two-part availability objective

**Status:** Proposed (needs product sign-off on SLO wording) · **Date:** 2026-11

## Context

The brief asks for 99.9999% uptime: about 31.5 s of failure per year. Two facts limit what's possible:

1. Published AWS SLAs for the building blocks (ALB, Fargate, Global Accelerator, Aurora Multi-AZ) are 99.95–99.99%. Six nines can only come from independent redundancy plus retries, never from one stack.
2. Data residency forbids copying a region's data elsewhere. A region's data can never be more available than that region's infrastructure.

## Decision

- Run **two stateless, active-active hubs** in different regions (`us-east-1`, `eu-west-1`) and different AWS accounts, behind Global Accelerator, peered to every region and to each other.
- Design so failures are **absorbed by retries** instead of detected and failed over: client retries on the other hub (idempotency keys on writes), hub→hub forwarding when one path to a region fails, GA draining in the background, one-hub-at-a-time deploys.
- Define **two SLOs**:
  - *Platform availability* 99.9999%: requests for healthy regions succeed, measured at the edge after retries.
  - *Regional data availability* 99.99% per region, raised to about 99.995% with optional in-jurisdiction DR (e.g. EU: `eu-central-1` → `eu-west-1` Aurora Global Database).

## Consequences

- An entire hub region can fail with no user-visible errors beyond retried requests.
- A regional outage degrades that region only, visibly and gracefully ("EU temporarily unavailable"). The platform SLO is not breached by something residency makes unavoidable.
- Requires an internal client SDK with retry budget and hub fallback, and idempotent write APIs.
- In-jurisdiction DR roughly doubles each region's data-tier cost, so it is a per-region business decision. IP ranges are already reserved in the plan.
