# Evidence

## Chapter 1: AWS foundations

Captured 5 August 2026 against a private AWS account in eu-west-2.
The cluster was created, verified and destroyed in the same session.

| File | What it proves |
|---|---|
| 01 | 36 resources created from Terraform, no manual steps |
| 02 | Both nodes Ready, no external IP, core pods running |
| 03 | ECR tag immutability and scan on push enabled |
| 04 | Cluster active on Kubernetes 1.35 with OIDC provider present |
| 05 | Kubernetes API restricted to a single address, not open |
| 06 | 36 resources destroyed, billing stopped |

## Chapter 2: GitOps delivery

Captured on the local kind cluster, which runs Kubernetes 1.34 and has no AWS
account behind it. Scripts for both recordings are in
[docs/demonstrations.md](../docs/demonstrations.md).

| File | What it proves |
|---|---|
| 07 | Root app and demo-app both Synced and Healthy, deployed from Git |
| 08 | The Deployment deleted by hand, pods terminating |
| 09 | ArgoCD recreated it unprompted, new pod names, same intent |
| 10 | A tampered container image reverted within seconds, with an audit trail |
| 11 | A bad commit pushed to Git and pulled by the cluster with no deploy command |
| 12 | `git revert` restoring service, three commits of history, nothing force-pushed |

Chapter 2 runs entirely on kind, so there is no account ID, no public IP and no
cloud console in any of these. The checks in the section below still apply to the
terminal chrome.

## Chapter 3: supply chain security

To be captured. The script is demonstration 3 in
[docs/demonstrations.md](../docs/demonstrations.md).

| File | What it proves |
|---|---|
| 13 | The pipeline: scan, OIDC role assumption with no stored key, push, sign, attest |
| 14 | `cosign verify` passing against the image the cluster is actually running |
| 15 | An unsigned image pushed to the real ECR repository outside the pipeline, successfully |
| 16 | Kyverno rejecting that image at admission, with the reason on screen |
| 17 | The same image signed with a valid personal Cosign identity, still rejected |
| 18 | ECR refusing to overwrite an existing tag, immutability doing its own job |

**Unlike chapters 1 and 2, chapter 3 screenshots contain the AWS account ID**,
because an ECR image reference embeds it. That is not redacted, and the reasoning
is in [docs/demonstrations.md](../docs/demonstrations.md) under "Capturing
evidence": the same account ID is committed to
[platform/manifests/demo-app/deployment.yaml](../platform/manifests/demo-app/deployment.yaml)
in this public repository, so blanking it out of an image would be theatre rather
than a control. What must not appear is any live ECR authentication token.

## What is redacted, and why

These screenshots were taken on a working machine and published to a public
repository, so everything identifying either the operator or the account has been
removed. Redactions are solid fill drawn into the PNG, so the pixels are
overwritten rather than merely covered.

| Redacted | Where | Why |
|---|---|---|
| Home broadband IP address | 05 | The single CIDR allowed to reach the Kubernetes API |
| AWS account ID | 01, 03, 04 | Appears in ARNs, the ECR URI and the console address bar |
| NAT gateway public IP | 01 | A real routable address that was allocated to the account |
| Console account alias and username | 03, 04, 05 | Identifies the operator |
| Shell prompt hostname | 01, 02, 06 | Identifies the operator's machine |
| Terminal tab bar | 01, 02, 06 | Named unrelated systems belonging to other parties. The strip is cropped away rather than covered |

The documentation elsewhere in this repository uses `203.0.113.10/32` from the
RFC 5737 documentation range wherever an example public address is needed, and
`123456789012` wherever an example account ID is needed. Neither is real.

Chapter 2 evidence is captured on the local kind cluster, which has no AWS
account behind it and therefore nothing to redact.
