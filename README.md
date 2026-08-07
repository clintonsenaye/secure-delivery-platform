# secure-delivery-platform

A Kubernetes platform on AWS where nothing runs unless it can prove where it
came from.

**All three chapters.** Chapter 1 built the ground everything else stands on:
network, cluster, registry, host hardening. Chapter 2 added GitOps delivery with
ArgoCD. Chapter 3 adds the build pipeline, keyless image signing, and the
admission policy that rejects anything it cannot verify.

The three arguments, one per chapter:

> **1.** Nothing holds an AWS access key, because identity is proven rather than
> presented. *(The IAM OIDC provider.)*
>
> **2.** The pipeline never holds cluster credentials, because the cluster pulls
> from Git rather than the pipeline pushing to the cluster. There is no
> credential to steal, because there is no credential.
>
> **3.** The cluster will not run an image unless it can prove that this
> repository's pipeline built it, from this repository's source, and that nobody
> has touched the bytes since.

Each is argued in full, limits included, in
[docs/architecture.md](docs/architecture.md): sections 8, 17 and 23.

**The demonstration that matters** is
[demonstration 3](docs/demonstrations.md): an unsigned image is pushed to the
real registry with real credentials, then signed with a perfectly valid personal
Cosign signature, and Kyverno refuses it both times. The policy does not ask
whether an image is signed. It asks *who* signed it.

---

## Cost warning, first

| What | Cost |
|---|---|
| `make up` (local kind cluster) | **free** |
| `make plan ENV=prod` | **free**, prod is never applied |
| `make apply ENV=ci` | **about $0.01/month.** ECR, an OIDC provider and two IAM roles. No cluster. |
| `make apply ENV=dev` | **about $0.18/hour, roughly $130/month if left running** |

About $0.15/hour of the dev figure is the EKS control plane plus the NAT gateway.
That is fixed cost, charged before a single pod runs, and it is unavoidable with
this architecture.

**`ENV=ci` is the whole AWS footprint of chapter 3**, and it is deliberately
tiny: identity federation, one role for the pipeline, one read only role for
plans, and a registry. Chapter 3 needs no cluster in AWS at all. Both admission
policies and the entire bypass demonstration run on kind. Apply it once and leave
it up.

**So the intended workflow is: work locally on kind, keep `ci` applied, and only
apply `dev` when you specifically need real IRSA or a real load balancer. Then
destroy it the same session.**

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
│   └── demonstrations.md          scripts for the three recorded demos
├── .github/workflows/             CHAPTER 3: the pipeline
│   ├── build-sign-attest.yml      scan, build, push, SBOM, sign, attest, commit
│   └── terraform-plan.yml         fmt, validate, scan and plan on every PR
├── policies/                      CHAPTER 3: what the cluster refuses to run
│   ├── require-signed-images.yaml deny anything without a valid signature
│   └── require-provenance.yaml    deny anything without SLSA build provenance
├── terraform/
│   ├── bootstrap/                 creates the S3 state bucket (run once)
│   ├── modules/
│   │   ├── network/               VPC, subnets, routing, NAT egress
│   │   ├── cluster/               EKS, node group, IAM OIDC provider
│   │   ├── registry/              ECR with immutable tags
│   │   └── github_oidc/           CHAPTER 3: the role GitHub assumes
│   └── environments/
│       ├── ci/                    CHAPTER 3: ECR + OIDC. ~$0.01/month, no cluster
│       ├── dev/                   cheap, spot, applied
│       └── prod/                  production sizing, PLAN ONLY
├── ansible/roles/cis_baseline/    CIS Level 1 for Ubuntu hosts
├── kind/kind-cluster.yaml         free local cluster
├── platform/                      CHAPTER 2: everything ArgoCD reads
│   ├── argocd/values.yaml         the committed Helm install
│   ├── bootstrap/root-app.yaml    the ONE file applied by hand
│   ├── apps/                      only Application objects live here
│   │   ├── kyverno/               the policy engine        (sync wave -2)
│   │   ├── kyverno-policies/      points at policies/      (sync wave -1)
│   │   └── demo-app/                                       (sync wave  0)
│   └── manifests/                 the workloads those Applications point at
│       └── demo-app/
└── app/src/                       the deliberately boring demo service
```

The sync waves are load bearing from chapter 3 onwards. Without them a cluster
rebuilt from nothing could admit the demo app in the window before the policies
exist: the pods would run, every Application would report Synced and Healthy, and
the gate would simply not have been consulted.

---

## Getting started

### 1. Local, free, no AWS account needed

```bash
make up          # creates a 3 node kind cluster
make status
make down
```

### 1b. GitOps and the supply chain gate on that local cluster

One command installs ArgoCD from the committed values file and applies the root
application. ArgoCD then pulls the rest, in sync wave order: Kyverno, then the
two policies, then the demo app.

```bash
make up
make argocd-up
```

**Chapter 3 changed what this does.** There is no longer a `kind load
docker-image` step. The demo image comes from ECR, built and signed by the
pipeline and referenced by digest, so `make argocd-up` also refreshes the ECR
credential the kind cluster needs to pull it and that Kyverno needs to read the
signature.

That means a fresh clone needs the pipeline to have run at least once:

```bash
make apply ENV=ci    # ECR, the GitHub OIDC provider and two IAM roles, ~$0.01/month
make ci-config       # prints the GitHub repository variables to set
# push to main; the workflow builds and signs the image, then opens a
# pull request recording the digest. Review and merge it, then:
git pull
make up && make argocd-up
```

Until then, `platform/manifests/demo-app/deployment.yaml` holds a placeholder
digest and the demo app sits in `ImagePullBackOff`. That is the honest behaviour:
there is no verified image to run yet, and chapter 3's whole point is that
nothing else will do.

Then:

```bash
make argocd-status        # sync and health of every application
make supply-chain-status  # policies, enforcement mode, and what is running
make argocd-password      # the initial admin password
make argocd-ui            # UI on http://localhost:8081  (user: admin)
make demo-ui              # the demo app on http://localhost:8082
```

To check the signature of what is actually running, read from the live
Deployment rather than from Git or from a pipeline log:

```bash
make verify-running-image
```

The ECR credential lasts **twelve hours**. When it expires, image pulls fail with
a 401 and Kyverno reports what looks like a signature error. Refresh it:

```bash
make ecr-login
```

That credential is the one thing chapter 3 adds back to the credential
inventory, and it exists only because this is kind. On EKS the kubelet pulls with
the node's instance role and Kyverno reads the registry through IRSA, so it does
not exist at all. See [docs/architecture.md section 27](docs/architecture.md).

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

The three recorded demonstrations, self-healing, rollback by `git revert`, and
the supply chain bypass, are scripted step by step in
[docs/demonstrations.md](docs/demonstrations.md).

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
terraform output -raw backend_hcl > ../environments/ci/backend.hcl
terraform output -raw backend_hcl > ../environments/dev/backend.hcl
terraform output -raw backend_hcl > ../environments/prod/backend.hcl
cd -
```

**Configure and apply the `ci` environment. Do this one first, and leave it up.**

This is the whole AWS footprint of chapter 3: an ECR repository, the GitHub OIDC
identity provider, and two IAM roles. No VPC, no NAT gateway, no cluster. About a
penny a month.

```bash
cp terraform/environments/ci/terraform.tfvars.example terraform/environments/ci/terraform.tfvars
$EDITOR terraform/environments/ci/terraform.tfvars   # set owner, github_repository, state_bucket_arn

make plan  ENV=ci
make apply ENV=ci
make ci-config          # prints the GitHub repository variables to set
```

`make ci-config` prints the repository **variables** to set, plus the exact
Cosign certificate identity that must appear in both files under
[policies/](policies/). A mismatch there produces `no matching signatures`, which
reads like a signing failure and is a policy typo, so diff them rather than
eyeballing them.

**There are no repository secrets to set. Not one.** No AWS access key, because
the pipeline proves its identity rather than presenting one. No signing key,
because signing is keyless. No token for the deploy job beyond the `GITHUB_TOKEN`
GitHub mints for the run.

That last one has a visible cost. Because `main` is protected, the pipeline opens
a pull request rather than pushing the digest, and GitHub does not trigger
workflows from events caused by `GITHUB_TOKEN`, so the pull request's own
required check never starts. **Close the pull request and reopen it**: the reopen
event comes from you, the gate runs, and it becomes mergeable. The pipeline
prints that instruction with the URL every time.

Two clicks per deploy, in exchange for a project with zero stored credentials.
[Section 30](docs/architecture.md) sets out all five ways to solve this and why
this is the right one at this volume and the wrong one at scale.

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
make lint-yaml       # yamllint over ansible, kind, platform, policies, workflows
make lint-ansible    # ansible-lint
make scan            # checkov and trivy over the Terraform
make check-tools     # which tools you have installed
```

Missing tools are reported and skipped rather than failing the build, so
`make lint` is useful on a fresh machine. Install them with:

```bash
pipx install checkov ansible-lint
pip install yamllint
# tflint:  https://github.com/terraform-linters/tflint
# trivy:   https://trivy.dev/latest/getting-started/installation/
# kind:    https://kind.sigs.k8s.io/docs/user/quick-start/#installation
# cosign:  https://docs.sigstore.dev/cosign/system_config/installation/
```

The same checks run in CI on every pull request, in
[.github/workflows/terraform-plan.yml](.github/workflows/terraform-plan.yml),
plus a real `terraform plan` against `ci`, `dev` and `prod`.

The build pipeline in
[.github/workflows/build-sign-attest.yml](.github/workflows/build-sign-attest.yml)
adds two more gates before anything is built: a **Gitleaks** scan over the whole
history, and a **Trivy** filesystem scan failing on HIGH or CRITICAL. Neither
holds a cloud credential, so they run on pull requests from forks as well.

**Every action in both workflows is pinned to a full commit SHA.**
`actions/checkout@v4` is a mutable tag, and a pipeline arguing that tags are
untrustworthy should not trust them for its own dependencies.

The fair objection is that nobody hand updates forty character hashes, so the
actions go stale and full of unpatched bugs.
[.github/dependabot.yml](.github/dependabot.yml) is the answer: Dependabot
understands SHA pinned actions specifically and updates the hash **and** the
version comment together, so the pin stays readable and the update goes through
review like any other change. Updates do not stop happening. They stop happening
invisibly.

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

Chapter 3 delivers on that:
[.github/workflows/terraform-plan.yml](.github/workflows/terraform-plan.yml) runs
`terraform plan` against prod on every pull request, using a **read only** IAM
role that is deliberately a different role from the one the build pipeline uses.
That turns prod from dead code into a continuously verified specification.

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

### `IMMUTABLE_WITH_EXCLUSION` on the ECR repository is not a retreat

Chapter 1 argued that immutable tags were one of two load bearing decisions.
Chapter 3 then discovers that Cosign stores signatures **as tags**, derived from
the digest they describe: `sha256-abc....sig` and `sha256-abc....att`. Attaching
a second attestation updates an existing tag, which a fully immutable repository
refuses, so signing fails with what looks like a permissions error.

The tempting fix is to set the whole repository to `MUTABLE`. Instead, only the
`sha256-*` namespace is excluded from immutability. Those tags are already
content addressed, so writing one can only change metadata about one exact
digest; it cannot repoint a name at different bytes, which is the attack
immutability exists to prevent. Application tags stay immutable, and `dev` is
untouched. [Section 26](docs/architecture.md).

### The ECR lifecycle policy will delete your signatures if you let it

"Keep the most recent 30 tagged images" counts `.sig` and `.att` artefacts as
images. Every build produces two, so the cap is reached after about ten builds
and ECR starts expiring the signatures of the images you deployed first, which
are the ones most likely to still be running.

**The failure is quiet and delayed.** Nothing breaks at expiry, because
admission already happened. It surfaces weeks later when a pod is rescheduled and
Kyverno reports "no matching signatures" for an image that verified fine on the
day it shipped. The fix is separate retention rules keyed on tag prefix.
[Section 26](docs/architecture.md).

### The policies match `imageReferences: ["*"]`, not your registry

Scoping the rule to `*.dkr.ecr.*.amazonaws.com/...` reads as "verify our images".
What it actually means is "verify only images matching this pattern, and admit
everything else unchecked". A pod referencing `docker.io/library/nginx` would
match nothing and be admitted with no verification at all, while the policy
reported as passing.

`"*"` is the correct value. Nothing runs in that namespace that is not built by
this pipeline. Genuine exceptions go in `skipImageReferences` as explicit,
reviewable single lines.

### The Ansible role is not for the EKS nodes

`cis_baseline` hardens general purpose Ubuntu hosts: bastions, self hosted CI
runners, self managed VMs. EKS managed nodes run Amazon Linux 2023 from an AWS
supplied AMI, are not reachable over SSH, and are fixed by replacement rather
than by logging in. See [docs/architecture.md](docs/architecture.md).

---

## The three chapters

| Chapter | Adds | Runs where |
|---|---|---|
| 1 (done) | Network, cluster, registry, host hardening, local cluster | AWS, then destroyed |
| 2 (done) | ArgoCD, app-of-apps, GitOps delivery | kind, free |
| 3 (done) | Build pipeline, keyless signing, SLSA provenance, admission policies | kind, plus ~$0.01/month of AWS |

Chapter 3 used exactly the three things chapter 1 and 2 said it would: the
**OIDC mechanism**, so nothing holds an access key; **immutable ECR tags**, so a
verified signature stays meaningful; and **the `/version` endpoint**, which has
been reporting `image_digest` as explicitly unset since the day it shipped and
now reports the digest that was signed and verified at admission.

**The gap chapter 3 closed**, stated in
[docs/architecture.md section 20](docs/architecture.md) before it was fixed:

> The manifests are in Git and provably so. The image bytes are not. They came
> from a laptop and nothing verifies them.

**The gap chapter 3 closed on itself.** The largest item on its own gap list was
that `main` had no branch protection: the gate proves an image came from this
pipeline, and the pipeline builds whatever is on `main`. Protection is now on,
and turning it on **immediately broke the delivery pipeline**, which pushed the
digest straight to `main` and was refused with `GH013`.

The fix was to make the automation follow the same rule a human does. The deploy
job now opens a pull request rather than pushing, and it cannot merge one. Two
alternatives were rejected: adding Actions to the ruleset bypass list, which
would exempt the one actor whose commits actually reach the cluster from the one
control that reviews what reaches it; and pointing ArgoCD at an unprotected
branch, which protects the branch nobody deploys from. That is written up in full
in [section 30](docs/architecture.md).

**The gaps chapter 3 leaves** are listed in
[section 32](docs/architecture.md).

### Three limits worth knowing before you read the code

**A signed backdoor is still signed.** These policies prove origin and integrity.
They say nothing about whether the code is any good. Provenance is not quality,
and anyone who can merge to `main` can still get anything signed. Branch
protection means the strength of every signature here is now the strength of the
review on the pull request that produced it.

**The gate can be turned off by deleting a file.** Prune is on, so removing
`policies/require-signed-images.yaml` removes the policy from the cluster.
Nothing stops serving, no alert fires, and every Application still reports Synced
and Healthy. That is a process problem wearing a technical costume, and branch
protection is what turns it from a one line push into a reviewed change.

**Chapter 3 still stores no credentials, and that was nearly lost.** Chapter 2's
credential table had three rows and said in bold there was no fourth. It now has
seven, but every one added by chapter 3 is minted per job and expires with it.
The only stored secret in the project is the 12 hour ECR pull token, and it
exists purely because this runs on kind rather than EKS.

The obvious fix for the branch protection problem was a GitHub App, which would
have meant a permanent private key in repository secrets. It was declined for two
clicks per deploy. **A pipeline that signs container images, pushes to a private
registry and commits to a protected branch, with zero secrets configured**, is
the strongest single thing here. The full table is in
[section 27](docs/architecture.md).

The other limits are in
[docs/architecture.md section 28](docs/architecture.md).

---

## Further reading

- [docs/architecture.md](docs/architecture.md) - every design decision, in plain English
- [docs/demonstrations.md](docs/demonstrations.md) - the three recorded demos, step by step
- [policies/](policies/) - the two things this cluster refuses to run
- [.github/workflows/build-sign-attest.yml](.github/workflows/build-sign-attest.yml) - the pipeline, commented at length
- [ansible/roles/cis_baseline/README.md](ansible/roles/cis_baseline/README.md) - the hardening role
- [evidence/README.md](evidence/README.md) - what the screenshots prove, and what was redacted from them
- [.trivyignore.yaml](.trivyignore.yaml) - every security finding this project has consciously accepted

