# Run with:  cd modules/network_plan && terraform init && terraform test
# No AWS credentials needed: this module is pure data.

run "prod_plan_derives_expected_subnets" {
  command = plan

  variables {
    plan_file = "../../live/prod/network-plan.yaml"
  }

  assert {
    condition     = length(output.vpc_cidrs) == 6
    error_message = "Expected 2 hubs + 4 spokes in the prod plan."
  }

  assert {
    condition     = output.spokes["eu"].subnet_cidrs_by_tier.interconnect == ["10.30.240.0/24", "10.30.241.0/24", "10.30.242.0/24"]
    error_message = "EU interconnect subnets moved. Peering routes and gateway SG rules depend on them."
  }

  assert {
    condition     = output.hubs["euw1"].subnet_cidrs_by_tier.app == ["10.11.16.0/20", "10.11.32.0/20", "10.11.48.0/20"]
    error_message = "hub-euw1 app subnets moved. Spoke gateway SG rules depend on them."
  }

  assert {
    condition     = !contains(keys(output.hubs["use1"].subnet_cidrs_by_tier), "data")
    error_message = "Hubs must not have a data tier: nothing is stored centrally."
  }

  assert {
    condition     = length(distinct([for h in output.hubs : h.account_id])) == length(output.hubs)
    error_message = "Each hub must have its own AWS account so one account-level failure can't take out both."
  }
}

run "overlapping_vpc_cidrs_are_rejected" {
  command = plan

  variables {
    plan_file = "tests/fixtures/overlapping-plan.yaml"
  }

  # spoke-ca is moved inside spoke-us's range; the plan must fail.
  expect_failures = [output.vpc_cidrs]
}
