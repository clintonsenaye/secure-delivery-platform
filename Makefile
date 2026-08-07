##############################################################################
# secure-delivery-platform
#
# Run `make help` for the full target list.
#
# COST WARNING: `make apply ENV=dev` creates real, chargeable AWS resources at
# roughly $0.18/hour, about $130/month if left running. Run `make destroy
# ENV=dev` when you have finished. `make up` (kind) is free and is the intended
# daily workflow.
#
# `make apply ENV=ci` is the chapter 3 supply chain footprint: an ECR repository,
# the GitHub OIDC identity provider and two IAM roles. No cluster, no VPC, no NAT
# gateway. Roughly a penny a month, and it is meant to be applied once and LEFT
# UP, because it holds the signed images running pods reference by digest.
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

# The demo application.
#
# CHAPTER 3 CHANGED HOW THIS ARRIVES. In chapter 2 the image was built on this
# laptop and side-loaded into the kind nodes with `kind load docker-image`, and
# nothing verified those bytes. There is no side-load target any more. The image
# now comes from ECR, built and signed by
# .github/workflows/build-sign-attest.yml, and referenced by digest in
# platform/manifests/demo-app/deployment.yaml.
#
# APP_DIR survives because the bypass demonstration in docs/demonstrations.md
# builds a rogue image locally, on purpose, to prove Kyverno rejects it.
APP_DIR       := app/src
DEMO_NS       := demo
DEMO_MANIFEST := platform/manifests/demo-app/deployment.yaml

# Supply chain. Chapter 3.
#
# The Kyverno chart version is NOT set here. It is pinned in
# platform/apps/kyverno/application.yaml, which is the single source of truth,
# because ArgoCD is what installs it. A second copy in this file would be a
# second thing to forget to update.
KYVERNO_NS        := kyverno
POLICY_DIR        := policies
ECR_PULL_SECRET   := ecr-pull
CI_TF_DIR         := terraform/environments/ci

# The placeholder digest committed to deployment.yaml before the pipeline has
# ever run. `make argocd-up` warns when it is still present.
PLACEHOLDER_DIGEST := sha256:0000000000000000000000000000000000000000000000000000000000000000

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
        demo-ui check-cluster \
        ci-config ecr-login kyverno-status verify-running-image supply-chain-status

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
	@grep -E '^(argocd-up|argocd-down|argocd-ui|argocd-password|argocd-status|demo-ui):.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-16s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)Supply chain, chapter 3 (free on kind)$(RESET)"
	@grep -E '^(ci-config|ecr-login|kyverno-status|verify-running-image|supply-chain-status):.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)AWS$(RESET)"
	@grep -E '^(bootstrap|init|plan|apply|destroy|cost):.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(AMBER)%-16s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "  ENV=$(BOLD)ci$(RESET) is the chapter 3 supply chain footprint: ECR, the"
	@echo "  GitHub OIDC provider and two IAM roles. About a $(BOLD)penny a month$(RESET),"
	@echo "  no cluster, and meant to be left up. ENV=dev is the expensive one."
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
	@if [ "$(ENV)" = "ci" ]; then \
	  echo "$(RED)ci has no cluster.$(RESET) It is ECR, an OIDC provider and two IAM"; \
	  echo "roles. That is the point: chapter 3's AWS footprint contains no"; \
	  echo "compute at all. Use 'make up' for the local cluster."; \
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

argocd-up: check-cluster ## Install ArgoCD and bootstrap the root app
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
	@echo "$(BOLD)==> Checking the committed image reference$(RESET)"
	@if grep -q "$(PLACEHOLDER_DIGEST)" $(DEMO_MANIFEST); then \
	  echo "$(AMBER)The demo deployment still holds the placeholder digest.$(RESET)"; \
	  echo ""; \
	  echo "Chapter 3 does not side-load an image any more. The digest in"; \
	  echo "$(DEMO_MANIFEST) is written by the"; \
	  echo "build pipeline after it signs the image. Until the pipeline has run"; \
	  echo "once, the demo app will sit in ImagePullBackOff, which is the honest"; \
	  echo "behaviour: there is no verified image to run yet."; \
	  echo ""; \
	  echo "  1. make apply ENV=ci        creates ECR and the GitHub OIDC role"; \
	  echo "  2. make ci-config           prints the repository variables to set"; \
	  echo "  3. push to main             the workflow builds, signs and commits"; \
	  echo "  4. git pull                 pick up the committed digest"; \
	  echo ""; \
	else \
	  echo "$(GREEN)Deployment references a real digest.$(RESET)"; \
	  grep -m1 'image:' $(DEMO_MANIFEST) | sed 's/^ *//'; \
	fi
	@echo ""
	@echo "$(BOLD)==> Applying the root application$(RESET)"
	@echo "This is the ONE manual step. Everything after it is pulled from Git."
	$(KUBECTL) apply -f $(ARGOCD_ROOT_APP)
	@echo ""
	@echo "$(BOLD)==> Waiting for the kyverno namespace$(RESET)"
	@echo "Sync wave -2 installs the policy engine before anything it gates."
	@for i in $$(seq 1 60); do \
	  if $(KUBECTL) get namespace $(KYVERNO_NS) >/dev/null 2>&1; then \
	    echo "$(GREEN)kyverno namespace exists.$(RESET)"; break; \
	  fi; \
	  sleep 5; \
	  if [ "$$i" = "60" ]; then \
	    echo "$(AMBER)Timed out. Check 'make argocd-status', then run 'make ecr-login' by hand.$(RESET)"; \
	  fi; \
	done
	@$(MAKE) --no-print-directory ecr-login || \
	  echo "$(AMBER)ECR login skipped. Run 'make ecr-login' once AWS credentials are available.$(RESET)"
	@echo ""
	@echo "$(GREEN)ArgoCD is running and the root app is applied.$(RESET)"
	@echo ""
	@echo "  make argocd-status         sync and health of every app"
	@echo "  make supply-chain-status   policies, and what is actually running"
	@echo "  make argocd-password       the initial admin password"
	@echo "  make argocd-ui             UI on http://localhost:$(ARGOCD_PORT) (user: admin)"
	@echo "  make demo-ui               the demo app on http://localhost:$(DEMO_PORT)"
	@echo ""
	@echo "$(AMBER)Apps appear over a minute or two, in sync wave order:$(RESET)"
	@echo "  -2 kyverno   ->  -1 kyverno-policies  ->  0 demo-app"

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
	-@$(KUBECTL) delete applications --all -n $(ARGOCD_NS) --timeout=180s
	-@helm uninstall argocd --namespace $(ARGOCD_NS) --kube-context kind-$(KIND_CLUSTER)
	-@$(KUBECTL) delete namespace $(ARGOCD_NS) --ignore-not-found --timeout=120s
	@# Chapter 3. Deleting the kyverno Application removes the chart's resources,
	@# but the admission webhook configurations are registered by Kyverno at
	@# runtime rather than by the chart, so they can outlive it. An orphaned
	@# webhook with failurePolicy: Fail pointing at a service that no longer
	@# exists makes the whole cluster refuse admissions, which looks like a
	@# broken cluster rather than a leftover. Removing them explicitly is cheap
	@# insurance against a very confusing five minutes.
	-@$(KUBECTL) delete validatingwebhookconfiguration,mutatingwebhookconfiguration \
	  -l webhook.kyverno.io/managed-by=kyverno --ignore-not-found --timeout=60s
	-@$(KUBECTL) delete namespace $(KYVERNO_NS) --ignore-not-found --timeout=120s
	@echo "$(GREEN)ArgoCD, Kyverno and the policies removed.$(RESET)"
	@echo ""
	@echo "The ECR repository and the IAM roles are untouched. They are in"
	@echo "terraform/environments/ci, they cost about a penny a month, and they"
	@echo "hold the signed images this cluster ran. Leave them."

##############################################################################
# Supply chain. Chapter 3.
#
# The claim: the cluster will not run an image unless it can prove that this
# repository's pipeline built it, from this repository's source, and that nobody
# has touched the bytes since.
#
# Almost all of this runs on kind and costs nothing. The only real AWS footprint
# is ENV=ci, which is ECR plus an OIDC provider plus two IAM roles, at roughly a
# penny a month and with no cluster involved. See docs/architecture.md
# section 27 for exactly where that boundary falls and why it is drawn there.
##############################################################################

ci-config: ## Print the GitHub repository variables and policy values to set
	@test -d $(CI_TF_DIR)/.terraform || { \
	  echo "$(RED)$(CI_TF_DIR) is not initialised.$(RESET)"; \
	  echo "  make init ENV=ci"; \
	  exit 1; }
	@echo ""
	@echo "$(BOLD)Set these as GitHub repository VARIABLES$(RESET)"
	@echo "  Settings -> Secrets and variables -> Actions -> Variables"
	@echo ""
	@echo "  There is deliberately no SECRET to set. No AWS access key exists."
	@echo ""
	@printf "  %-22s %s\n" "AWS_ROLE_ARN" "$$(cd $(CI_TF_DIR) && terraform output -raw gha_push_role_arn 2>/dev/null || echo '<apply first>')"
	@printf "  %-22s %s\n" "AWS_PLAN_ROLE_ARN" "$$(cd $(CI_TF_DIR) && terraform output -raw gha_plan_role_arn 2>/dev/null || echo '<apply first>')"
	@printf "  %-22s %s\n" "AWS_REGION" "$$(cd $(CI_TF_DIR) && terraform output -raw aws_region 2>/dev/null || echo eu-west-2)"
	@printf "  %-22s %s\n" "TF_STATE_BUCKET" "$$(cd terraform/bootstrap && terraform output -raw state_bucket_name 2>/dev/null || echo '<run make bootstrap>')"
	@echo ""
	@echo "$(BOLD)The OIDC subject claim the trust policies require$(RESET)"
	@echo ""
	@echo "  Since 15 July 2026 GitHub embeds the repository's permanent numeric"
	@echo "  IDs in this claim. A policy built from names alone does not match,"
	@echo "  and StringEquals refuses the request. See architecture.md section 29."
	@echo ""
	@echo "  terraform says:"
	@echo "    $$(cd $(CI_TF_DIR) && terraform output -raw repository_claim 2>/dev/null || echo '<apply first>')"
	@echo "  github says:"
	@if command -v gh >/dev/null 2>&1; then \
	  repo="$$(cd $(CI_TF_DIR) && terraform output -raw github_repository 2>/dev/null || echo '')"; \
	  if [ -n "$$repo" ]; then \
	    echo "    $$(gh api "repos/$$repo" --jq '"repo:\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"' 2>/dev/null || echo '<gh api failed, are you authenticated?>')"; \
	  else \
	    echo "    <apply first>"; \
	  fi; \
	else \
	  echo "    <gh not installed: gh api repos/OWNER/NAME --jq '\"repo:\\(.owner.login)@\\(.owner.id)/\\(.name)@\\(.id)\"'>"; \
	fi
	@echo ""
	@echo "$(AMBER)Those two lines must be identical, character for character.$(RESET)"
	@echo "If role assumption is being refused, they are not, and the difference"
	@echo "is the whole diagnosis. The workflow logs never show the claim; read it"
	@echo "from a CloudTrail AssumeRoleWithWebIdentity event instead:"
	@echo ""
	@echo "  aws cloudtrail lookup-events \\"
	@echo "    --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \\"
	@echo "    --max-results 5 --query 'Events[].CloudTrailEvent' --output text \\"
	@echo "    | jq -r '.userIdentity.userName? // .requestParameters?, .errorMessage?'"
	@echo ""
	@echo "$(BOLD)These must match policies/*.yaml exactly$(RESET)"
	@echo ""
	@echo "  subject:"
	@echo "    $$(cd $(CI_TF_DIR) && terraform output -raw cosign_certificate_identity 2>/dev/null || echo '<apply first>')"
	@echo "  issuer:"
	@echo "    $$(cd $(CI_TF_DIR) && terraform output -raw cosign_certificate_oidc_issuer 2>/dev/null || echo '<apply first>')"
	@echo ""
	@echo "$(AMBER)A mismatch between those and the policy files produces$(RESET)"
	@echo "$(AMBER)'no matching signatures', which reads like a signing failure$(RESET)"
	@echo "$(AMBER)and is a policy typo. Diff them rather than eyeballing them:$(RESET)"
	@echo ""
	@echo "  grep -h 'subject:' $(POLICY_DIR)/*.yaml"
	@echo ""
	@echo "$(BOLD)Registry$(RESET)"
	@printf "  %-22s %s\n" "repository" "$$(cd $(CI_TF_DIR) && terraform output -raw ecr_repository_url 2>/dev/null || echo '<apply first>')"
	@echo ""

ecr-login: check-cluster ## Refresh the 12 hour ECR credential in the demo and kyverno namespaces
	@command -v aws >/dev/null 2>&1 || { echo "$(RED)aws CLI is not installed.$(RESET)"; exit 1; }
	@echo "$(BOLD)==> Refreshing the ECR pull credential$(RESET)"
	@echo ""
	@echo "This is the ONE credential chapter 3 adds back to the cluster, and it"
	@echo "exists only because this is kind. On EKS the kubelet pulls with the"
	@echo "node's instance role and Kyverno reads the registry through IRSA, so"
	@echo "neither of these secrets exists at all."
	@echo ""
	@echo "$(AMBER)The token below is valid for TWELVE HOURS.$(RESET) When it expires,"
	@echo "image pulls fail with a 401 and Kyverno reports what looks like a"
	@echo "signature error. Re-run this target."
	@echo ""
	@region="$$(cd $(CI_TF_DIR) && terraform output -raw aws_region 2>/dev/null || echo eu-west-2)"; \
	 registry="$$(cd $(CI_TF_DIR) && terraform output -raw ecr_registry 2>/dev/null || true)"; \
	 if [ -z "$$registry" ]; then \
	   acct="$$(aws sts get-caller-identity --query Account --output text)"; \
	   registry="$$acct.dkr.ecr.$$region.amazonaws.com"; \
	   echo "Derived registry from the current identity: $$registry"; \
	 fi; \
	 password="$$(aws ecr get-login-password --region "$$region")"; \
	 for ns in $(DEMO_NS) $(KYVERNO_NS); do \
	   $(KUBECTL) get namespace "$$ns" >/dev/null 2>&1 || { \
	     echo "$(AMBER)Namespace $$ns does not exist yet, skipping.$(RESET)"; continue; }; \
	   $(KUBECTL) create secret docker-registry $(ECR_PULL_SECRET) \
	     --namespace "$$ns" \
	     --docker-server="$$registry" \
	     --docker-username=AWS \
	     --docker-password="$$password" \
	     --dry-run=client -o yaml | $(KUBECTL) apply -f - ; \
	 done
	@# Kyverno caches registry clients, so a refreshed secret is not picked up
	@# until the admission controller reconnects. Restarting it is cheap and
	@# avoids a class of "I refreshed the token and it still fails" confusion.
	@if $(KUBECTL) get deploy -n $(KYVERNO_NS) -l app.kubernetes.io/component=admission-controller \
	     -o name 2>/dev/null | grep -q .; then \
	  echo ""; \
	  echo "Restarting the Kyverno admission controller so it picks up the new token."; \
	  $(KUBECTL) rollout restart deploy -n $(KYVERNO_NS) -l app.kubernetes.io/component=admission-controller; \
	  $(KUBECTL) rollout status deploy -n $(KYVERNO_NS) -l app.kubernetes.io/component=admission-controller --timeout=120s || true; \
	fi
	@echo ""
	@echo "$(GREEN)ECR credential refreshed.$(RESET)"

kyverno-status: check-cluster ## Show the installed policies and their enforcement mode
	@echo ""
	@echo "$(BOLD)Cluster policies$(RESET)"
	@$(KUBECTL) get clusterpolicy \
	  -o custom-columns=NAME:.metadata.name,BACKGROUND:.spec.background,READY:.status.conditions[0].status,MESSAGE:.status.conditions[0].message \
	  2>/dev/null || echo "$(AMBER)Kyverno is not installed yet.$(RESET)"
	@echo ""
	@echo "$(BOLD)Enforcement mode, read from the cluster rather than the files$(RESET)"
	@$(KUBECTL) get clusterpolicy -o json 2>/dev/null \
	  | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("  {:<28} failurePolicy={:<8} failureAction={}".format(p["metadata"]["name"], p["spec"].get("failurePolicy","Fail"), ",".join(sorted({r.get("failureAction", v.get("failureAction","")) for r in p["spec"]["rules"] for v in r.get("verifyImages",[{}])} - {""}) ) or p["spec"].get("validationFailureAction","?"))) for p in d.get("items",[])]' \
	  2>/dev/null || true
	@echo ""
	@echo "$(BOLD)Kyverno pods$(RESET)"
	@$(KUBECTL) get pods -n $(KYVERNO_NS) 2>/dev/null || true
	@echo ""
	@echo "$(BOLD)Recent policy decisions$(RESET)"
	@$(KUBECTL) get events -n $(DEMO_NS) --sort-by=.lastTimestamp 2>/dev/null | tail -12 || true
	@echo ""

verify-running-image: check-cluster ## Verify the signature of the image the cluster is actually running
	@command -v cosign >/dev/null 2>&1 || { \
	  echo "$(RED)cosign is not installed.$(RESET)"; \
	  echo "  https://docs.sigstore.dev/cosign/system_config/installation/"; \
	  exit 1; }
	@echo ""
	@echo "$(BOLD)==> Reading the image from the live Deployment$(RESET)"
	@echo "Not from Git, and not from the pipeline log. From the cluster."
	@image="$$($(KUBECTL) get deploy demo-app -n $(DEMO_NS) \
	   -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"; \
	 if [ -z "$$image" ]; then \
	   echo "$(AMBER)No demo-app Deployment found.$(RESET)"; exit 1; fi; \
	 echo "  $$image"; \
	 case "$$image" in \
	   *@sha256:*) ;; \
	   *) echo "$(RED)That is a TAG, not a digest. Chapter 3 has regressed.$(RESET)"; exit 1 ;; \
	 esac; \
	 identity="$$(cd $(CI_TF_DIR) && terraform output -raw cosign_certificate_identity 2>/dev/null || true)"; \
	 if [ -z "$$identity" ]; then \
	   identity="$$(grep -h -m1 'subject:' $(POLICY_DIR)/require-signed-images.yaml | sed 's/.*subject: *"\(.*\)"/\1/')"; \
	   echo "  (identity taken from the policy file, not from Terraform)"; \
	 fi; \
	 echo ""; \
	 echo "$(BOLD)==> Verifying against the identity the policy requires$(RESET)"; \
	 echo "  identity: $$identity"; \
	 echo "  issuer:   https://token.actions.githubusercontent.com"; \
	 echo ""; \
	 cosign verify \
	   --certificate-identity="$$identity" \
	   --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
	   "$$image" > /dev/null && \
	 echo "$(GREEN)Signature valid, and made by this repository's build workflow.$(RESET)"

supply-chain-status: check-cluster ## One screen: policies, running image, and its provenance
	@$(MAKE) --no-print-directory kyverno-status
	@echo "$(BOLD)What the demo namespace is running$(RESET)"
	@$(KUBECTL) get pods -n $(DEMO_NS) -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,IMAGE:.spec.containers[0].image 2>/dev/null || true
	@echo ""
	@echo "$(BOLD)What /version reports$(RESET)"
	@echo "  make demo-ui, then: curl -s localhost:$(DEMO_PORT)/version | jq ."
	@echo ""
	@echo "  Those fields are environment variables the pipeline wrote. They are"
	@echo "  a window onto a fact established elsewhere, not the evidence itself."
	@echo "  The evidence is: make verify-running-image"
	@echo ""

##############################################################################
# Terraform.
#
# ENV=ci   ECR, the GitHub OIDC provider and two IAM roles. ~$$0.01/month.
#          No cluster. Apply once and leave it up.
# ENV=dev  A whole EKS environment. ~$$0.18/hour. Destroy it the same session.
# ENV=prod Plan only. Never applied.
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
	@if [ "$(ENV)" = "ci" ]; then \
	  echo "$(GREEN)ENV=ci creates ECR, an OIDC provider and two IAM roles.$(RESET)"; \
	  echo "No cluster, no NAT gateway. Roughly a penny a month, and it is meant"; \
	  echo "to stay up: it holds the signed images the cluster runs by digest."; \
	else \
	  echo "$(AMBER)This creates real AWS resources at roughly \$$0.18/hour.$(RESET)"; \
	fi
	cd $(TF_DIR) && terraform apply $(TF_INPUT_FALSE) tfplan
	@rm -f $(TF_DIR)/tfplan
	@echo ""
	@if [ "$(ENV)" = "ci" ]; then \
	  echo "$(GREEN)Applied.$(RESET) Next:"; \
	  echo "  make ci-config     print the GitHub repository variables to set"; \
	  echo ""; \
	  echo "$(AMBER)Do NOT destroy this environment casually.$(RESET) It holds the signed"; \
	  echo "images every running pod references by digest."; \
	else \
	  echo "$(GREEN)Applied.$(RESET) Connect with:"; \
	  cd $(TF_DIR) && terraform output -raw kubeconfig_command 2>/dev/null || true; \
	  echo ""; \
	  echo "$(AMBER)Remember: make destroy ENV=$(ENV) when you are finished.$(RESET)"; \
	fi

destroy: check-env ## Destroy ENV. Requires CONFIRM=yes.
	@if [ "$(ENV)" = "prod" ]; then \
	  echo "$(RED)Refusing to destroy prod.$(RESET) It is never applied, so there is nothing to destroy."; \
	  exit 1; \
	fi
	@if [ "$(ENV)" = "ci" ]; then \
	  echo "$(RED)Think carefully before destroying ci.$(RESET)"; \
	  echo ""; \
	  echo "This environment holds the ECR repository containing every signed"; \
	  echo "image, every signature and every attestation. Every running pod"; \
	  echo "references one of those images BY DIGEST, so destroying it does not"; \
	  echo "merely lose artefacts: it makes running workloads unschedulable the"; \
	  echo "moment a pod is rescheduled, and unverifiable immediately."; \
	  echo ""; \
	  echo "It also costs about a penny a month, so there is very little to"; \
	  echo "gain. The repository is created with force_delete = false, so this"; \
	  echo "will refuse anyway while images remain."; \
	  echo ""; \
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
	@echo "  ci, the chapter 3 supply chain footprint:"
	@echo "    IAM OIDC provider          \$$0.00"
	@echo "    2 x IAM role and policy    \$$0.00"
	@echo "    ECR storage, ~12 MB/image  ~\$$0.01/month"
	@echo "    GitHub Actions, public     \$$0.00"
	@echo "    Sigstore public good       \$$0.00"
	@echo "    ---------------------------------------"
	@echo "    Total                      $(GREEN)~\$$0.01/month$(RESET)"
	@echo ""
	@echo "  There is no cluster in ci. The whole of chapter 3's admission"
	@echo "  control, both policies and the bypass demonstration run on kind."
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

lint-yaml: ## yamllint over Ansible, kind, platform, policies and workflows
	@echo "$(BOLD)==> yamllint$(RESET)"
	@if command -v yamllint >/dev/null 2>&1; then \
	  yamllint -c .yamllint.yml ansible/ kind/ platform/ policies/ .github/; \
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
	  ci|dev|prod) ;; \
	  *) echo "$(RED)ENV must be 'ci', 'dev' or 'prod', got '$(ENV)'.$(RESET)"; exit 1 ;; \
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
	@for t in terraform aws kubectl kind docker helm ansible ansible-lint tflint yamllint checkov trivy cosign syft jq yq gh; do \
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
