# secure-delivery-platform

A Kubernetes platform on AWS where nothing runs unless it can prove where it
came from.

**Chapters 1 and 2 of 3.** Chapter 1 built the ground everything else stands on:
network, cluster, registry, host hardening. Chapter 2 adds GitOps delivery with
ArgoCD, and it **runs entirely on a free local kind cluster.** There is no
pipeline and no admission policy yet, and that is deliberate.

The argument chapter 2 exists to make:

> **The pipeline never holds cluster credentials, because the cluster pulls from
> Git rather than the pipeline pushing to the cluster. There is no credential to
> steal, because there is no credential.**

That is argued in full, limits included, in
[docs/architecture.md section 17](docs/architecture.md).

---

## Cost warning, first

| What | Cost |
|---|---|
| `make up` (local kind cluster) | **free** |
| `make plan ENV=prod` | **free**, prod is never applied |
| `make apply ENV=dev` | **about $0.18/hour, roughly $130/month if left running** |

About $0.15/hour of the dev figure is the EKS control plane plus the NAT gateway.
That is fixed cost, charged before a single pod runs, and it is unavoidable with
this architecture.

**So the intended workflow is: work locally on kind, and only apply to AWS when
you specifically need real IAM, real IRSA or a real load balancer. Then destroy
it the same session.**

```bash
make cost                      # the full breakdown
make destroy ENV=dev CONFIRM=yes
```

---

## What is here

```text
.
├── Makefile                       one entry point for everything
├── .trivyignore.yaml              the accepted risk register
├── docs/
│   ├── architecture.md            why it is built this way
│   └── demonstrations.md          scripts for the two recorded demos
├── terraform/
│   ├── bootstrap/                 creates the S3 state bucket (run once)
│   ├── modules/
│   │   ├── network/               VPC, subnets, routing, NAT egress
│   │   ├── cluster/               EKS, node group, IAM OIDC provider
│   │   └── registry/              ECR with immutable tags
│   └── environments/
│       ├── dev/                   cheap, spot, applied
│       └── prod/                  production sizing, PLAN ONLY
├── ansible/roles/cis_baseline/    CIS Level 1 for Ubuntu hosts
├── kind/kind-cluster.yaml         free local cluster
├── platform/                      CHAPTER 2: everything ArgoCD reads
│   ├── argocd/values.yaml         the committed Helm install
│   ├── bootstrap/root-app.yaml    the ONE file applied by hand
│   ├── apps/                      only Application objects live here
│   │   └── demo-app/
│   └── manifests/                 the workloads those Applications point at
│       └── demo-app/
└── app/src/                       the deliberately boring demo service
```

---

## Getting started

### 1. Local, free, no AWS account needed

```bash
make up          # creates a 3 node kind cluster
make status
make down
```

### 1b. GitOps on that local cluster, still free

One command installs ArgoCD from the committed values file, builds and
side-loads the demo image, and applies the root application:

```bash
make up
make argocd-up
```

Then:

```bash
make argocd-status     # sync and health of every application
make argocd-password   # the initial admin password
make argocd-ui         # UI on http://localhost:8081  (user: admin)
make demo-ui           # the demo app on http://localhost:8082
```

Ports 8081 and 8082, not 8080 and 8443, because the kind node already binds
those on the host. See `kind/kind-cluster.yaml`.

**This requires the repository to be public and pushed**, because ArgoCD clones
it anonymously over HTTPS with no credential at all. That is the point rather
than a convenience: see [docs/architecture.md section 17](docs/architecture.md).
If the repo is private, ArgoCD reports `authentication required: Repository not
found` on the root application and nothing syncs.

The demo service exposes four endpoints:

| Path | What it shows |
|---|---|
| `/` | greeting, version, commit, and the pod serving it |
| `/healthz` | liveness and readiness |
| `/version` | provenance: commit, build time, and a SHA256 the binary computes of itself |
| `/metrics` | Prometheus exposition, custom plus standard Go and process collectors |

To tear it down:

```bash
make argocd-down CONFIRM=yes
```

The two recorded demonstrations, self-healing and rollback by `git revert`, are
scripted step by step in [docs/demonstrations.md](docs/demonstrations.md).

### 2. AWS

You need AWS credentials configured. This project uses whatever
`aws sts get-caller-identity` resolves to; **it never reads or stores an access
key of its own.** Use an SSO profile or an instance role.

```bash
aws sts get-caller-identity      # confirm who you are
```

**Bootstrap the state backend, once ever:**

```bash
cp terraform/bootstrap/terraform.tfvars.example terraform/bootstrap/terraform.tfvars
$EDITOR terraform/bootstrap/terraform.tfvars    # set owner
make bootstrap
```

Then write the generated backend config into each environment:

```bash
cd terraform/bootstrap
terraform output -raw backend_hcl > ../environments/dev/backend.hcl
terraform output -raw backend_hcl > ../environments/prod/backend.hcl
cd -
```

**Configure the dev environment:**

```bash
cp terraform/environments/dev/terraform.tfvars.example terraform/environments/dev/terraform.tfvars
curl -s https://checkip.amazonaws.com     # your public IP
$EDITOR terraform/environments/dev/terraform.tfvars
```

`public_access_cidrs` is **required and has no default**. That is on purpose: an
open Kubernetes API would contradict the premise of this project, so supplying
your own address has to be a conscious act. The variable's validation rule
rejects `0.0.0.0/0` outright.

**Plan, apply, connect, destroy:**

```bash
make plan ENV=dev                       # review this properly
make apply ENV=dev                      # applies the saved plan
aws eks update-kubeconfig --region eu-west-2 --name secure-delivery-dev
kubectl get nodes
make destroy ENV=dev CONFIRM=yes        # when you are finished
```

### 3. Quality gates

```bash
make lint            # everything below
make lint-tf         # fmt, validate, tflint
make lint-yaml       # yamllint
make lint-ansible    # ansible-lint
make scan            # checkov and trivy over the Terraform
make check-tools     # which tools you have installed
```

Missing tools are reported and skipped rather than failing the build, so
`make lint` is useful on a fresh machine. Install them with:

```bash
pipx install checkov ansible-lint
pip install yamllint
# tflint: https://github.com/terraform-linters/tflint
# trivy:  https://trivy.dev/latest/getting-started/installation/
# kind:   https://kind.sigs.k8s.io/docs/user/quick-start/#installation
```

---

## Notes on things that surprise people

### The bootstrap uses local state, and that state is not committed

`terraform/bootstrap` creates the S3 bucket that every other root module stores
its state in. It cannot store its own state in a bucket that does not exist yet,
so it uses local state, and that file is gitignored.

**This is safe because the bootstrap is fully reproducible from code.** It
creates two things, a bucket and its settings, both of which are declared in
`terraform/bootstrap/main.tf`. If the local state file is lost, nothing is
broken: the bucket keeps working, and the state can be rebuilt with two imports.

```bash
cd terraform/bootstrap
terraform init
terraform import aws_s3_bucket.state secure-delivery-tfstate-<account-id>-eu-west-2
terraform plan     # should show no changes to the bucket itself
```

The bucket also has `prevent_destroy = true`, so a stray `terraform destroy`
cannot remove the thing holding all your state.

### There is no DynamoDB lock table

State locking uses `use_lockfile = true`, the S3 backend's native locking, which
writes a `.tflock` object next to the state file using an atomic S3 conditional
write. The old `dynamodb_table` argument is deprecated.

This removes a whole resource, its IAM permissions, its cost, and the failure
mode where the lock table and the bucket drift apart.

### prod is never applied

`make apply ENV=prod` and `make destroy ENV=prod` both refuse, enforced in the
Makefile rather than left to discipline.

prod exists to be **planned**. A plan still type checks the whole configuration,
resolves every module input and output, and catches real errors against a real
AWS account. It proves the modules are genuinely reusable, because dev and prod
differ only in values. And it demonstrates production sizing without paying about
$185/month for an idle cluster.

Chapter 3 adds a CI check that runs `terraform plan` against prod on every pull
request, which turns it from dead code into a continuously verified
specification.

### Deleting the ArgoCD root app does not take the platform down

`platform/bootstrap/root-app.yaml` deliberately carries **no** ArgoCD finalizer,
while every child application does.

With the finalizer, `kubectl delete application root -n argocd` would cascade:
every child Application deleted, and each child's finalizer taking its workloads
with it. One keystroke, whole platform gone.

Without it, that command removes only the root object. Children keep syncing,
nothing stops serving, and re-applying the file adopts them all back with no
downtime. What you lose is reconciliation of the *list* of applications, which
is a real hazard because the cluster looks healthy while quietly no longer being
GitOps.

The children keep their finalizers, so deleting an app's file from Git still
tears its workloads down properly. Deliberate deletion works; accidental
catastrophe does not. Argued in full in
[docs/architecture.md section 18](docs/architecture.md).

### `platform/apps/` may only contain Application objects

The root app reads that directory recursively. A Deployment left in there would
be applied straight into the `argocd` namespace, bypassing the child Application
meant to own it. That is why workload manifests live in `platform/manifests/`,
which the root app never reads. The separation is structural rather than a
naming convention, so it cannot be got wrong by accident.

### The Ansible role is not for the EKS nodes

`cis_baseline` hardens general purpose Ubuntu hosts: bastions, self hosted CI
runners, self managed VMs. EKS managed nodes run Amazon Linux 2023 from an AWS
supplied AMI, are not reachable over SSH, and are fixed by replacement rather
than by logging in. See [docs/architecture.md](docs/architecture.md).

---

## Where this is going

| Chapter | Adds |
|---|---|
| 1 (done) | Network, cluster, registry, host hardening, local cluster |
| 2 (done) | ArgoCD, app-of-apps, GitOps delivery on kind |
| 3 | Build pipeline, image signing, admission policy that rejects unsigned images |

The three things chapter 3 depends on most are the **IAM OIDC provider** (so
nothing needs an access key), **immutable ECR tags** (so a verified signature
stays meaningful), and **the `/version` endpoint** built in chapter 2, which
already reports the commit a binary was built from and will report the signed
image digest once there is one.

**The known gap chapter 3 exists to close:** in chapter 2 the manifests are in
Git and provably so, but the container image is built on a laptop and
side-loaded into kind. Nothing verifies those bytes. That is written up honestly
in [docs/architecture.md section 20](docs/architecture.md) rather than left to be
discovered.

---

## Further reading

- [docs/architecture.md](docs/architecture.md) - every design decision, in plain English
- [docs/demonstrations.md](docs/demonstrations.md) - the two recorded demos, step by step
- [ansible/roles/cis_baseline/README.md](ansible/roles/cis_baseline/README.md) - the hardening role
- [evidence/README.md](evidence/README.md) - what the screenshots prove, and what was redacted from them
- [.trivyignore.yaml](.trivyignore.yaml) - every security finding this project has consciously accepted
