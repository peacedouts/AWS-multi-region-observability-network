# ADR-0005: Cognito user pool per hub, federated to the corporate IdP

**Status:** Accepted · **Date:** 2026-11

## Context

The regional stacks authenticate with Amazon Cognito (bearer tokens, JWT claims). Reviewers of the central platform are internal staff whose identities live in the corporate IdP. Cognito user pools are regional, while the platform runs two active-active hubs in different regions and must fail over between them without user-visible errors (ADR-0003).

## Options considered

| Option | For | Against |
|---|---|---|
| Trust the corporate IdP directly | No regional identity dependency | Introduces a second token model next to the regional stacks' Cognito; group-to-claim mapping lives outside AWS |
| One Cognito pool for both hubs | Matches the regional stacks | That pool's region becomes a single point of failure for sign-in on both hubs |
| **One Cognito pool per hub, both federated to the IdP, both trusted everywhere** | Matches the regional stacks; no single identity region; one SSO login | Two pools to keep identical (Terraform); refresh tokens are pool-specific |

## Decision

Each hub has its own Cognito user pool, federated to the corporate IdP, with identical configuration and an IdP-group → `regions` claim mapping. Both hubs and every regional gateway accept tokens from either pool. Tokens are validated in the services, not by the ALB's Cognito sign-in action, so a session is not tied to one hub.

## Consequences

- A hub failure doesn't log anyone out: tokens issued by the failed hub's pool are still accepted by the surviving hub until they expire, after which a silent SSO redirect gets a token from the surviving pool.
- One pool being impaired only affects new sign-ins through that hub. The corporate IdP remains a shared dependency for *new* sign-ins on both hubs, which was already true.
- Pool configuration drift is the main risk; both pools come from one Terraform module with the same inputs.
