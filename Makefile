# Usage:
#   make validate
#   make plan  STACK=spoke INSTANCE=eu
#   make apply STACK=hub   INSTANCE=use1
TF       ?= terraform
STACK    ?=
INSTANCE ?=
ROOTS    := live/prod/spoke live/prod/hub live/prod/connectivity live/prod/observability live/bootstrap/deployer-role

# hub/observability take -var hub=, spoke takes -var spoke=, connectivity takes none
VAR_spoke         = -var spoke=$(INSTANCE)
VAR_hub           = -var hub=$(INSTANCE)
VAR_observability = -var hub=$(INSTANCE)
VAR_connectivity  =

.PHONY: fmt validate init plan apply

fmt:
	$(TF) fmt -recursive

validate:
	$(TF) fmt -recursive -check
	@for d in $(ROOTS); do echo "== $$d"; (cd $$d && $(TF) init -backend=false -input=false >/dev/null && $(TF) validate) || exit 1; done

init:
	cd live/prod/$(STACK) && $(TF) init -reconfigure -backend-config=backends/$(INSTANCE).hcl

plan: init
	cd live/prod/$(STACK) && $(TF) plan $(VAR_$(STACK)) -out=$(INSTANCE).tfplan

apply:
	cd live/prod/$(STACK) && $(TF) apply $(INSTANCE).tfplan
