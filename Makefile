##############################################################################
# secure-delivery-platform
#
# Run `make help` for the full target list.
#
# COST WARNING: `make apply ENV=dev` creates real, chargeable AWS resources at
# roughly $0.18/hour, about $130/month if left running. Run `make destroy
# ENV=dev` when you have finished. `make up` (kind) is free and is the intended
# daily workflow.
##############################################################################

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Environment to act on. Override on the command line: make plan ENV=prod
ENV ?= dev

TF_DIR        := terraform/environments/$(ENV)
BOOTSTRAP_DIR := terraform/bootstrap
MODULES_DIR   := terraform/modules
KIND_CONFIG   := kind/kind-cluster.yaml
KIND_CLUSTER  := secure-delivery

# GitOps. Chapter 2. All of this runs on kind and costs nothing.
#
# The chart version is pinned rather than floating, for the same reason
# .terraform.lock.hcl is committed: an install that resolves to whatever is
# newest on the day it runs is not reproducible. Check for newer releases with:
#   helm search repo argo/argo-cd --versions
ARGOCD_NS         := argocd
ARGOCD_CHART_VER  := 10.2.3
ARGOCD_VALUES     := platform/argocd/values.yaml
ARGOCD_ROOT_APP   := platform/bootstrap/root-app.yaml
ARGOCD_HELM_REPO  := https://argoproj.github.io/argo-helm

# The demo application. Built locally and side-loaded into the kind nodes,
# because chapter 2 has no registry and no CI. See docs/architecture.md.
APP_DIR      := app/src
DEMO_VERSION := 0.1.0
DEMO_IMAGE   := demo-app:$(DEMO_VERSION)
DEMO_NS      := demo

# Host ports for port-forwarding. NOT 8080 or 8443: the kind node already binds
# those on this host, see kind/kind-cluster.yaml.
ARGOCD_PORT  := 8081
DEMO_PORT    := 8082

KUBECTL := kubectl --context kind-$(KIND_CLUSTER)

# Terraform is quieter and safer when it knows it is not attached to a terminal
# for anything it might otherwise prompt about.
TF_INPUT_FALSE := -input=false

# Colours, only when stdout is a terminal.
ifneq (,$(findstring xterm,$(TERM)))
	BOLD  := $(shell tput bold)
	RED   := $(shell tput setaf 1)
	GREEN := $(shell tput setaf 2)
	AMBER := $(shell tput setaf 3)
	RESET := $(shell tput sgr0)
else
	BOLD  :=
	RED   :=
	GREEN :=
	AMBER :=
	RESET :=
endif

.PHONY: help up down status plan apply destroy bootstrap init fmt validate lint \
        lint-tf lint-ansible lint-yaml scan scan-checkov scan-trivy kubeconfig \
        cost check-env check-tools clean \
        argocd-up argocd-down argocd-ui argocd-password argocd-status \
        demo-image demo-ui check-cluster

##############################################################################
# Help
##############################################################################

help: ## Show this help
	@echo ""
	@echo "$(BOLD)secure-delivery-platform$(RESET)"
	@echo ""
	@echo "$(BOLD)Local development (free)$(RESET)"
	@grep -E '^(up|down|status|kubeconfig):.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-16s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)GitOps on kind (free)$(RESET)"
	@grep -E '^(argocd-up|argocd-down|argocd-ui|argocd-password|argocd-status|demo-image|demo-ui):.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-16s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)AWS (costs money)$(RESET)"
	@grep -E '^(bootstrap|init|plan|apply|destroy|cost):.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(AMBER)%-16s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)Quality$(RESET)"
	@grep -E '^(lint|lint-tf|lint-ansible|lint-yaml|scan|scan-checkov|scan-trivy|fmt|validate):.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'
	@echo ""
	@echo "  ENV defaults to $(BOLD)dev$(RESET). Example: make plan ENV=prod"
	@echo "  $(RED)prod is plan only.$(RESET) apply and destroy are refused."
	@echo ""

##############################################################################
# Local kind cluster. Free. This is the daily workflow.
##############################################################################

up: ## Create the local kind cluster
	@command -v kind >/dev/null 2>&1 || { \
	  echo "$(RED)kind is not installed.$(RESET)"; \
	  echo "  go install sigs.k8s.io/kind@latest"; \
	  echo "  or see https://kind.sigs.k8s.io/docs/user/quick-start/#installation"; \
	  exit 1; }
	@if kind get clusters 2>/dev/null | grep -qx "$(KIND_CLUSTER)"; then \
	  echo "$(AMBER)Cluster '$(KIND_CLUSTER)' already exists.$(RESET) Run 'make down' first to recreate it."; \
	else \
	  kind create cluster --config $(KIND_CONFIG) --wait 120s; \
	fi
	@kubectl cluster-info --context kind-$(KIND_CLUSTER)
	@echo "$(GREEN)Local cluster ready.$(RESET) Context: kind-$(KIND_CLUSTER)"

down: ## Delete the local kind cluster
	@command -v kind >/dev/null 2>&1 || { echo "kind is not installed, nothing to delete."; exit 0; }
	@if kind get clusters 2>/dev/null | grep -qx "$(KIND_CLUSTER)"; then \
	  kind delete cluster --name $(KIND_CLUSTER); \
	  echo "$(GREEN)Local cluster deleted.$(RESET)"; \
	else \
	  echo "No cluster named '$(KIND_CLUSTER)' exists."; \
	fi

status: ## Show local cluster nodes and pods
	@kubectl --context kind-$(KIND_CLUSTER) get nodes -o wide
	@echo ""
	@kubectl --context kind-$(KIND_CLUSTER) get pods -A

kubeconfig: check-env ## Point kubectl at the EKS cluster for ENV
	@if [ "$(ENV)" = "prod" ]; then \
	  echo "$(RED)prod is never applied, so there is no cluster to connect to.$(RESET)"; \
	  exit 1; \
	fi
	aws eks update-kubeconfig \
	  --region "$$(cd $(TF_DIR) && terraform output -raw aws_region)" \
	  --name   "$$(cd $(TF_DIR) && terraform output -raw cluster_name)"

##############################################################################
# GitOps. Chapter 2. Runs entirely on kind and costs nothing.
#
# The security argument, in one sentence: nothing outside this cluster holds a
# credential that can write to it, because the cluster pulls from Git rather
# than a pipeline pushing to the cluster. See docs/architecture.md section 17.
##############################################################################

argocd-up: check-cluster demo-image ## Install ArgoCD and bootstrap the root app
	@command -v helm >/dev/null 2>&1 || { \
	  echo "$(RED)helm is not installed.$(RESET)"; \
	  echo "  https://helm.sh/docs/intro/install/"; \
	  exit 1; }
	@test -f $(ARGOCD_VALUES) || { echo "$(RED)Missing $(ARGOCD_VALUES)$(RESET)"; exit 1; }
	@test -f $(ARGOCD_ROOT_APP) || { echo "$(RED)Missing $(ARGOCD_ROOT_APP)$(RESET)"; exit 1; }
	@echo "$(BOLD)==> Installing ArgoCD chart $(ARGOCD_CHART_VER) from $(ARGOCD_VALUES)$(RESET)"
	@helm repo add argo $(ARGOCD_HELM_REPO) --force-update >/dev/null
	@helm repo update argo >/dev/null
	helm upgrade --install argocd argo/argo-cd \
	  --version $(ARGOCD_CHART_VER) \
	  --namespace $(ARGOCD_NS) --create-namespace \
	  --values $(ARGOCD_VALUES) \
	  --kube-context kind-$(KIND_CLUSTER) \
	  --wait --timeout 10m
	@echo ""
	@echo "$(BOLD)==> Applying the root application$(RESET)"
	@echo "This is the ONE manual step. Everything after it is pulled from Git."
	$(KUBECTL) apply -f $(ARGOCD_ROOT_APP)
	@echo ""
	@echo "$(GREEN)ArgoCD is running and the root app is applied.$(RESET)"
	@echo ""
	@echo "  make argocd-status      sync and health of every app"
	@echo "  make argocd-password    the initial admin password"
	@echo "  make argocd-ui          UI on http://localhost:$(ARGOCD_PORT) (user: admin)"
	@echo "  make demo-ui            the demo app on http://localhost:$(DEMO_PORT)"
	@echo ""
	@echo "$(AMBER)The demo app may take a moment to appear while the root app syncs.$(RESET)"

demo-image: check-cluster ## Build the demo image and load it into the kind nodes
	@command -v docker >/dev/null 2>&1 || { echo "$(RED)docker is not installed.$(RESET)"; exit 1; }
	@echo "$(BOLD)==> Building $(DEMO_IMAGE)$(RESET)"
	@commit="$$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"; \
	 dirty=""; \
	 git diff --quiet 2>/dev/null || dirty="-dirty"; \
	 built="$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	 echo "  version $(DEMO_VERSION), commit $${commit}$${dirty}, built $$built"; \
	 docker build \
	   --build-arg VERSION="$(DEMO_VERSION)" \
	   --build-arg GIT_COMMIT="$${commit}$${dirty}" \
	   --build-arg BUILD_TIME="$$built" \
	   -t $(DEMO_IMAGE) $(APP_DIR)
	@echo "$(BOLD)==> Loading $(DEMO_IMAGE) into kind$(RESET)"
	@echo "Chapter 2 has no registry, so the image is side-loaded straight into"
	@echo "the nodes. The manifests are provably from Git; these bytes are not."
	@echo "That gap is what chapter 3 closes with signing and admission control."
	kind load docker-image $(DEMO_IMAGE) --name $(KIND_CLUSTER)

argocd-status: check-cluster ## Show sync and health of every application
	@echo ""
	@$(KUBECTL) get applications -n $(ARGOCD_NS) \
	  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision \
	  2>/dev/null || echo "$(AMBER)No applications yet. Run 'make argocd-up'.$(RESET)"
	@echo ""
	@$(KUBECTL) get deploy,pods,svc -n $(DEMO_NS) 2>/dev/null || true
	@echo ""

argocd-password: check-cluster ## Print the initial ArgoCD admin password
	@$(KUBECTL) get secret argocd-initial-admin-secret -n $(ARGOCD_NS) \
	  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null \
	  || { echo "$(AMBER)No initial admin secret found.$(RESET)"; \
	       echo "It is deleted after the password is changed, which is the correct end state."; \
	       exit 0; }
	@echo ""
	@echo "$(AMBER)Change this and delete the secret once you have logged in:$(RESET)"
	@echo "  $(KUBECTL) -n $(ARGOCD_NS) delete secret argocd-initial-admin-secret"

argocd-ui: check-cluster ## Port-forward the ArgoCD UI to localhost:8081
	@echo "$(GREEN)ArgoCD UI:$(RESET) http://localhost:$(ARGOCD_PORT)   user: admin"
	@echo "Password: make argocd-password.  Ctrl-C to stop."
	@echo ""
	@echo "Plain HTTP is deliberate: this port-forward is already a TLS tunnel"
	@echo "through the Kubernetes API. See platform/argocd/values.yaml."
	$(KUBECTL) port-forward svc/argocd-server -n $(ARGOCD_NS) $(ARGOCD_PORT):80

demo-ui: check-cluster ## Port-forward the demo app to localhost:8082
	@echo "$(GREEN)Demo app:$(RESET) http://localhost:$(DEMO_PORT)"
	@echo "  /          greeting, version and the pod serving it"
	@echo "  /version   provenance: commit, build time, binary digest"
	@echo "  /metrics   Prometheus exposition"
	@echo ""
	$(KUBECTL) port-forward svc/demo-app -n $(DEMO_NS) $(DEMO_PORT):80

argocd-down: check-cluster ## Remove ArgoCD and everything it manages. CONFIRM=yes.
	@if [ "$(CONFIRM)" != "yes" ]; then \
	  echo "$(RED)This removes ArgoCD and every application it manages.$(RESET)"; \
	  echo "Re-run with an explicit confirmation:"; \
	  echo "  make argocd-down CONFIRM=yes"; \
	  exit 1; \
	fi
	@echo "Deleting child applications first, so their finalizers can clean up"
	@echo "workloads properly rather than orphaning them."
	-@$(KUBECTL) delete -f $(ARGOCD_ROOT_APP) --ignore-not-found --timeout=60s
	-@$(KUBECTL) delete applications --all -n $(ARGOCD_NS) --timeout=120s
	-@helm uninstall argocd --namespace $(ARGOCD_NS) --kube-context kind-$(KIND_CLUSTER)
	-@$(KUBECTL) delete namespace $(ARGOCD_NS) --ignore-not-found --timeout=120s
	@echo "$(GREEN)ArgoCD removed.$(RESET)"

##############################################################################
# Terraform. These cost money.
##############################################################################

bootstrap: ## One time: create the S3 remote state bucket
	@echo "$(BOLD)Creating the Terraform state backend.$(RESET)"
	@echo "This uses LOCAL state, because it creates the bucket that everything"
	@echo "else stores state in. The local state file is gitignored."
	@echo ""
	@test -f $(BOOTSTRAP_DIR)/terraform.tfvars || { \
	  echo "$(RED)Missing $(BOOTSTRAP_DIR)/terraform.tfvars$(RESET)"; \
	  echo "  cp $(BOOTSTRAP_DIR)/terraform.tfvars.example $(BOOTSTRAP_DIR)/terraform.tfvars"; \
	  exit 1; }
	cd $(BOOTSTRAP_DIR) && terraform init $(TF_INPUT_FALSE)
	cd $(BOOTSTRAP_DIR) && terraform apply $(TF_INPUT_FALSE)
	@echo ""
	@echo "$(GREEN)Done.$(RESET) Now write the backend config into each environment:"
	@echo "  cd $(BOOTSTRAP_DIR) && terraform output -raw backend_hcl > ../environments/dev/backend.hcl"
	@echo "  cd $(BOOTSTRAP_DIR) && terraform output -raw backend_hcl > ../environments/prod/backend.hcl"

init: check-env ## terraform init for ENV, using its backend.hcl
	@test -f $(TF_DIR)/backend.hcl || { \
	  echo "$(RED)Missing $(TF_DIR)/backend.hcl$(RESET)"; \
	  echo "  Run 'make bootstrap' first, then:"; \
	  echo "    cd $(BOOTSTRAP_DIR) && terraform output -raw backend_hcl > ../environments/$(ENV)/backend.hcl"; \
	  exit 1; }
	cd $(TF_DIR) && terraform init $(TF_INPUT_FALSE) -backend-config=backend.hcl

plan: init ## terraform plan for ENV (safe, changes nothing)
	@test -f $(TF_DIR)/terraform.tfvars || { \
	  echo "$(RED)Missing $(TF_DIR)/terraform.tfvars$(RESET)"; \
	  echo "  cp $(TF_DIR)/terraform.tfvars.example $(TF_DIR)/terraform.tfvars"; \
	  echo "  Then set public_access_cidrs to your own IP:"; \
	  echo "    curl -s https://checkip.amazonaws.com"; \
	  exit 1; }
	cd $(TF_DIR) && terraform plan $(TF_INPUT_FALSE) -out=tfplan
	@echo ""
	@echo "Plan written to $(TF_DIR)/tfplan. Apply it with: make apply ENV=$(ENV)"

apply: check-env ## terraform apply for ENV. CREATES CHARGEABLE RESOURCES.
	@if [ "$(ENV)" = "prod" ]; then \
	  echo "$(RED)Refusing to apply prod.$(RESET)"; \
	  echo ""; \
	  echo "prod is a PLAN ONLY environment. It exists so that 'terraform plan'"; \
	  echo "continuously verifies production sizing without paying roughly"; \
	  echo "\$$185/month to keep an idle cluster alive."; \
	  echo ""; \
	  echo "Use 'make plan ENV=prod'. See terraform/environments/prod/main.tf."; \
	  exit 1; \
	fi
	@test -f $(TF_DIR)/tfplan || { \
	  echo "$(RED)No saved plan found.$(RESET) Run 'make plan ENV=$(ENV)' first."; \
	  echo "Applying a reviewed plan file, rather than re-planning at apply time,"; \
	  echo "means what you approved is exactly what gets built."; \
	  exit 1; }
	@echo "$(AMBER)This creates real AWS resources at roughly \$$0.18/hour.$(RESET)"
	cd $(TF_DIR) && terraform apply $(TF_INPUT_FALSE) tfplan
	@rm -f $(TF_DIR)/tfplan
	@echo ""
	@echo "$(GREEN)Applied.$(RESET) Connect with:"
	@cd $(TF_DIR) && terraform output -raw kubeconfig_command 2>/dev/null || true
	@echo ""
	@echo "$(AMBER)Remember: make destroy ENV=$(ENV) when you are finished.$(RESET)"

destroy: check-env ## Destroy ENV. Requires CONFIRM=yes.
	@if [ "$(ENV)" = "prod" ]; then \
	  echo "$(RED)Refusing to destroy prod.$(RESET) It is never applied, so there is nothing to destroy."; \
	  exit 1; \
	fi
	@if [ "$(CONFIRM)" != "yes" ]; then \
	  echo "$(RED)This destroys the whole $(ENV) environment.$(RESET)"; \
	  echo "Re-run with an explicit confirmation:"; \
	  echo "  make destroy ENV=$(ENV) CONFIRM=yes"; \
	  exit 1; \
	fi
	cd $(TF_DIR) && terraform destroy $(TF_INPUT_FALSE)
	@echo "$(GREEN)$(ENV) destroyed. Billing for it has stopped.$(RESET)"

cost: ## Print the running cost estimate
	@echo ""
	@echo "$(BOLD)Approximate running cost, eu-west-2 (verify against AWS pricing)$(RESET)"
	@echo ""
	@echo "  dev, while running:"
	@echo "    EKS control plane          \$$0.100/hr"
	@echo "    NAT gateway x1             \$$0.050/hr"
	@echo "    2 x t3.small SPOT          \$$0.016/hr"
	@echo "    Public IPv4 (NAT)          \$$0.005/hr"
	@echo "    40 GB gp3 EBS              \$$0.005/hr"
	@echo "    ---------------------------------------"
	@echo "    Total                      $(AMBER)~\$$0.18/hr = ~\$$4.30/day = ~\$$130/month$(RESET)"
	@echo ""
	@echo "  prod is plan only and costs nothing."
	@echo "  kind (make up) costs nothing."
	@echo ""
	@echo "  \$$0.15/hr of that is EKS control plane plus NAT gateway, which is"
	@echo "  fixed cost before a single pod runs. Destroy the environment when"
	@echo "  you are not using it."
	@echo ""

##############################################################################
# Quality gates
##############################################################################

lint: lint-tf lint-yaml lint-ansible scan ## Run every check
	@echo ""
	@echo "$(GREEN)All available checks passed.$(RESET)"

fmt: ## Rewrite Terraform files to canonical format
	terraform fmt -recursive terraform/

validate: ## terraform validate every module and environment
	@set -e; for d in $(MODULES_DIR)/* terraform/environments/* $(BOOTSTRAP_DIR); do \
	  if [ -f "$$d/versions.tf" ]; then \
	    echo "==> $$d"; \
	    ( cd "$$d" && terraform init -backend=false $(TF_INPUT_FALSE) >/dev/null && terraform validate ); \
	  fi; \
	done

lint-tf: ## terraform fmt check, validate, and tflint
	@echo "$(BOLD)==> terraform fmt$(RESET)"
	@terraform fmt -check -recursive terraform/ || { \
	  echo "$(RED)Formatting issues. Fix with: make fmt$(RESET)"; exit 1; }
	@echo "$(BOLD)==> terraform validate$(RESET)"
	@$(MAKE) --no-print-directory validate
	@echo "$(BOLD)==> tflint$(RESET)"
	@if command -v tflint >/dev/null 2>&1; then \
	  tflint --init >/dev/null 2>&1 || true; \
	  tflint --recursive --config="$$(pwd)/.tflint.hcl"; \
	else \
	  echo "$(AMBER)SKIPPED: tflint not installed.$(RESET)"; \
	  echo "  curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash"; \
	fi

lint-yaml: ## yamllint over Ansible, kind and platform manifests
	@echo "$(BOLD)==> yamllint$(RESET)"
	@if command -v yamllint >/dev/null 2>&1; then \
	  yamllint -c .yamllint.yml ansible/ kind/ platform/; \
	else \
	  echo "$(AMBER)SKIPPED: yamllint not installed.$(RESET)  pip install yamllint"; \
	fi

lint-ansible: ## ansible-lint over the playbook and role
	@echo "$(BOLD)==> ansible-lint$(RESET)"
	@if command -v ansible-lint >/dev/null 2>&1; then \
	  cd ansible && ansible-lint site.yml roles/; \
	else \
	  echo "$(AMBER)SKIPPED: ansible-lint not installed.$(RESET)  pipx install ansible-lint"; \
	fi

##############################################################################
# Infrastructure as code security scanning
#
# This project verifies container images from chapter 3 onwards. It would be
# inconsistent not to hold its own Terraform to the same standard, so the same
# gate runs against the infrastructure that defines the platform.
#
# Both scanners run. They overlap but do not agree: Checkov has deeper AWS
# specific policy coverage, Trivy is faster and also finds secrets. Findings that
# are deliberate decisions are suppressed inline with a #checkov:skip comment
# carrying a written reason, so a suppression is a documented argument rather
# than a silent exclusion.
##############################################################################

scan: scan-checkov scan-trivy ## Run all IaC security scanners

scan-checkov: ## Checkov policy scan over terraform/
	@echo "$(BOLD)==> checkov$(RESET)"
	@if command -v checkov >/dev/null 2>&1; then \
	  checkov --directory terraform/ \
	          --framework terraform \
	          --quiet \
	          --compact \
	          --download-external-modules false; \
	else \
	  echo "$(AMBER)SKIPPED: checkov not installed.$(RESET)  pipx install checkov"; \
	fi

scan-trivy: ## Trivy config scan over terraform/ and secret scan over the repo
	@echo "$(BOLD)==> trivy config$(RESET)"
	@if command -v trivy >/dev/null 2>&1; then \
	  trivy config terraform/ --severity HIGH,CRITICAL --exit-code 1 \
	    --ignorefile .trivyignore.yaml; \
	  echo "$(BOLD)==> trivy secret$(RESET)"; \
	  trivy fs . --scanners secret --severity MEDIUM,HIGH,CRITICAL --exit-code 1; \
	else \
	  echo "$(AMBER)SKIPPED: trivy not installed.$(RESET)"; \
	  echo "  https://trivy.dev/latest/getting-started/installation/"; \
	fi

##############################################################################
# Helpers
##############################################################################

check-env:
	@case "$(ENV)" in \
	  dev|prod) ;; \
	  *) echo "$(RED)ENV must be 'dev' or 'prod', got '$(ENV)'.$(RESET)"; exit 1 ;; \
	esac
	@test -d $(TF_DIR) || { echo "$(RED)No such environment: $(TF_DIR)$(RESET)"; exit 1; }

check-cluster:
	@command -v kind >/dev/null 2>&1 || { \
	  echo "$(RED)kind is not installed.$(RESET) https://kind.sigs.k8s.io/"; exit 1; }
	@kind get clusters 2>/dev/null | grep -qx "$(KIND_CLUSTER)" || { \
	  echo "$(RED)No kind cluster named '$(KIND_CLUSTER)'.$(RESET)"; \
	  echo "  Create it first with: make up"; \
	  exit 1; }
	@$(KUBECTL) cluster-info >/dev/null 2>&1 || { \
	  echo "$(RED)Cannot reach the cluster on context kind-$(KIND_CLUSTER).$(RESET)"; \
	  echo "  Try: make down && make up"; \
	  exit 1; }

check-tools: ## Report which tools are installed
	@echo ""
	@printf "%-16s %s\n" "TOOL" "STATUS"
	@for t in terraform aws kubectl kind docker ansible ansible-lint tflint yamllint checkov trivy; do \
	  if command -v $$t >/dev/null 2>&1; then \
	    printf "%-16s $(GREEN)%s$(RESET)\n" "$$t" "installed"; \
	  else \
	    printf "%-16s $(AMBER)%s$(RESET)\n" "$$t" "missing"; \
	  fi; \
	done
	@echo ""

clean: ## Remove local Terraform working directories and saved plans
	find terraform -type d -name '.terraform' -prune -exec rm -rf {} +
	find terraform -type f -name 'tfplan' -delete
	@echo "$(GREEN)Cleaned.$(RESET) Note: .terraform.lock.hcl files are kept deliberately."
