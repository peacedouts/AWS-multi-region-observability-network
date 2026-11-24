# ADR-0002: The center talks to a regional gateway, never to a regional database

**Status:** Accepted · **Date:** 2026-11

## Context

The brief says the central API needs read access to every regional database, and writes must be routed to the right region. The obvious implementation is to route the hub to each Aurora reader/writer endpoint on 5432.

## Decision

Each region exposes a **regional gateway**: an internal ALB with mutual TLS in a dedicated *interconnect* subnet tier, in front of a small Fargate service in the app tier. It is the only thing the hubs can route to. The gateway:

- holds the region's database credentials (IAM DB auth) and chooses **reader endpoint for reads, writer endpoint for writes**;
- re-authorizes the end user (JWT `regions` claim) and writes an **access-audit record in the region**;
- applies field-level filtering/redaction the jurisdiction requires;
- returns **presigned URLs** for video so clip bytes go from regional S3 straight to the reviewer;
- exposes a coarse-grained API (batch/paginated) designed for high-latency links.

## Consequences

- **Good:** no database credentials, schema knowledge or data-access IAM leave the region. Write routing is a property of the system, not a convention. Regional DPOs can audit access without the center. The data tier has no route to the hubs at all (route + NACL), which shrinks the attack surface to a single TLS port.
- **Bad:** one more service per region to run and version. Its API becomes a cross-team contract.
- **Mitigation:** the gateway is one codebase deployed per region with per-region config generated from `network-plan.yaml`, and contract-tested from the central API's CI.
