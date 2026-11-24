# Service Control Policies

Prevention layer. Attached at the OU level by the organization's management
pipeline (out of scope for this repo; shown here because the network design
depends on them).

| Policy | Attached to | Purpose |
|---|---|---|
| `region-lock-<jurisdiction>.json` | each regional account (EU shown; US/CA/APAC identical with their `allowed_regions` from `network-plan.yaml`) | Resources for a jurisdiction can only be created in that jurisdiction's regions. The single strongest residency control: a typo cannot put EU data in `us-east-1`. |
| `data-residency-guardrails.json` | Regional Workloads OU | No multi-region KMS keys, no replication/snapshot copy/sharing except by an audited in-jurisdiction DR role, and spokes may only peer with VPCs owned by the two hub accounts. |
| `protect-network-baseline.json` | All workload OUs | Only the Terraform deployer role (or audited break-glass) can change peering, routes, SGs, NACLs; nobody can switch off flow logs, CloudTrail, Config or GuardDuty. |

`network_guardrails` (EventBridge) detects what SCPs allow but we still want to
know about, such as every break-glass change.
