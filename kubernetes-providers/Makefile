.DEFAULT_GOAL := help

SHELL := /usr/bin/env bash

SCRIPTS := scripts

.PHONY: help
help:
	@echo "Targets:"
	@echo "  mgmt-up           Create local CAPI management plane"
	@echo "  mgmt-down         Delete local CAPI management plane"
	@echo ""
	@echo "  local-up          Create local workload clusters (EKS/AKS/GKE-named)"
	@echo "  local-down        Delete local workload clusters"
	@echo "  local-deploy      mgmt-up + local-up"
	@echo "  local-destroy     local-down + mgmt-down"
	@echo "  local-redeploy    local-down + mgmt-down + mgmt-up + local-up"
	@echo ""
	@echo "  managed-init      Install CAPA/CAPZ/CAPG into mgmt plane (requires cloud creds)"
	@echo "  managed-up        Create EKS/AKS/GKE clusters via CAPI (requires cloud creds + flavors)"
	@echo "  managed-down      Delete managed clusters (deletes CAPI objects)"
	@echo "  managed-deploy    mgmt-up + managed-init + managed-up"
	@echo "  managed-destroy   managed-down + mgmt-down"
	@echo ""
	@echo "  kubeconfig-merge  (manual) Merge mgmt kubeconfig into ~/.kube/config"
	@echo "  kubeconfig-merge-workloads  (manual) Merge workload kubeconfigs into ~/.kube/config"
	@echo ""
	@echo "  net-up            Apply private networking full-mesh (requires creds/key material)"
	@echo "  net-down          Destroy private networking full-mesh (requires creds/key material)"
	@echo ""
	@echo "Notes:"
	@echo "  - Config defaults: config.json"
	@echo "  - Local overrides (gitignored): config.local.json"

.PHONY: mgmt-up mgmt-down
mgmt-up:
	@$(SCRIPTS)/create-management-plane-capi.sh

mgmt-down:
	@$(SCRIPTS)/delete-management-plane-capi.sh

.PHONY: local-up local-down local-deploy local-destroy local-redeploy
local-up:
	@$(SCRIPTS)/create-local-clusters.sh

local-down:
	@$(SCRIPTS)/delete-local-clusters.sh

local-deploy: mgmt-up local-up

local-destroy: local-down mgmt-down

local-redeploy: local-down mgmt-down mgmt-up local-up

.PHONY: managed-init managed-up managed-down managed-deploy managed-destroy
managed-init:
	@$(SCRIPTS)/init-managed-providers.sh

managed-up:
	@$(SCRIPTS)/create-managed-clusters.sh

managed-down:
	@$(SCRIPTS)/delete-managed-clusters.sh

managed-deploy: mgmt-up managed-init managed-up

managed-destroy: managed-down mgmt-down

.PHONY: kubeconfig-merge
kubeconfig-merge:
	@$(SCRIPTS)/merge-management-kubeconfig.sh

.PHONY: kubeconfig-merge-workloads
kubeconfig-merge-workloads:
	@$(SCRIPTS)/merge-workload-kubeconfig.sh $(CLUSTERS)

.PHONY: net-up net-down
net-up:
	@$(SCRIPTS)/connect-networks-fullmesh.sh

net-down:
	@cd networking/terraform/us && terraform destroy -auto-approve
	@cd networking/terraform/eu && terraform destroy -auto-approve
