# Demonstrations

Three recordings.

| # | Chapter | What it shows |
|---|---|---|
| 1 | 2 | **Self-healing.** ArgoCD restoring something no Kubernetes controller would |
| 2 | 2 | **Rollback via `git revert`.** A bad commit reaching the cluster, and being undone |
| 3 | 3 | **The bypass.** An unsigned image pushed to the real registry, and Kyverno refusing it with the reason on screen |

All three run on the local kind cluster. Demonstration 3 additionally reads from
and writes to a real ECR repository, which costs about a penny a month and needs
no cluster in AWS. All three assume:

```bash
make up            # if the cluster is not already running
make argocd-up     # installs ArgoCD, applies the root app
make argocd-status # demo-app should read Synced / Healthy
```

Evidence is captured into `evidence/`, continuing the numbering from chapter 1.
See `evidence/README.md` for the table each file is listed in.

---

## Terminal layout

Both demonstrations use three panes. The watch pane is what sells the recording,
because the audience sees the cluster react rather than hearing you claim it did.

| Pane | Contents |
|---|---|
| **Left** | a `watch` loop, running throughout |
| **Right** | where you type |
| **Third** | `make demo-ui`, left running, so `localhost:8082` stays up |

Port numbers: ArgoCD on **8081**, demo app on **8082**. Not 8080 or 8443, which
the kind node already binds on this host.

---

## Demonstration 1: self-healing

### The point, and the mistake nearly everyone makes on camera

**Do not delete a pod.**

If you delete a pod, the ReplicaSet recreates it. That is plain Kubernetes and
has been true since 2015. It demonstrates nothing about ArgoCD, and anyone
watching who knows Kubernetes will discount the whole video.

To prove ArgoCD is doing the healing you have to break something **no Kubernetes
controller would ever repair**: delete the Deployment itself, or change it to
something Git does not say. Nothing in vanilla Kubernetes brings back a deleted
Deployment. If it comes back, ArgoCD brought it back.

Say this out loud on the recording. Being the person who explains why the obvious
demo is wrong is worth more than the demo.

### Setup

Left pane:

```bash
watch -n1 'kubectl --context kind-secure-delivery get application demo-app -n argocd \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status \
  && echo && kubectl --context kind-secure-delivery get deploy,pods -n demo'
```

Third pane:

```bash
make demo-ui      # http://localhost:8082
```

Have the ArgoCD UI open on the demo-app resource tree as well:

```bash
make argocd-ui    # http://localhost:8081, user admin
make argocd-password
```

### Steps

**1. Establish the baseline.**

Left pane shows `Synced` / `Healthy`, one Deployment, two pods. Browser shows the
greeting and a pod name. Read the pod name out loud or highlight it. It is your
reference point for the rest of the recording.

```bash
curl -s localhost:8082
```

> Capture: `evidence/07-argocd-app-synced.png`
> The ArgoCD UI showing demo-app Synced and Healthy, resource tree expanded.

**2. Delete the Deployment.**

```bash
kubectl --context kind-secure-delivery delete deployment demo-app -n demo
```

Say clearly: *nothing in Kubernetes will bring this back.*

> Capture: `evidence/08-selfheal-deployment-deleted.png`
> The watch pane at the moment the Deployment is gone and pods are terminating.

**3. Watch it come back.**

Pods terminate, the Deployment disappears, the Application goes `OutOfSync`, and
within seconds ArgoCD recreates the Deployment. The pods return with **new
names**.

```bash
curl -s localhost:8082
```

Same greeting, different pod name. That is the proof: the intent survived, the
instance did not.

> Capture: `evidence/09-selfheal-restored.png`
> Back to Synced / Healthy, with the new pod names visible.

**4. Second break: the one that actually happens.**

A deleted Deployment is dramatic but nobody does it by accident. This is the
realistic one.

```bash
kubectl --context kind-secure-delivery scale deployment demo-app -n demo --replicas=5
```

Watch it scale to five, then watch ArgoCD pull it back to two.

Narrate: *this is the 3am hotfix that nobody wrote down. Under GitOps it survives
about ten seconds. If you want five replicas, you change the number in Git and
open a pull request. That is not bureaucracy, it is the difference between a
cluster you can rebuild and one you cannot.*

**5. Third break: image tampering. This is the security one.**

```bash
kubectl --context kind-secure-delivery set image deployment/demo-app \
  demo-app=nginx:latest -n demo
```

ArgoCD reverts it within seconds.

Narrate: *an attacker with cluster write access just swapped my application
image. The change lasted seconds and it is in the ArgoCD event history. Under a
push pipeline that change is invisible and permanent until the next deploy, which
might be a fortnight away.*

Then immediately add the limit, because it is the most valuable sentence in the
recording:

*Note where this stops. It worked because the attacker changed the cluster, not
Git. If they had commit access to main, ArgoCD would deploy their image
obediently and self-heal would defend it. That is exactly what chapter 3 is for.*

> Capture: `evidence/10-image-tamper-reverted.png`
> The ArgoCD event history showing the out-of-sync detection and automated sync.

**6. Show the audit trail.**

In the ArgoCD UI, open demo-app and show the sync history: each drift detection
and each automated sync, timestamped. **Self-healing is not just correction, it
is detection with a record.**

**7. Reset.** Left pane back to `Synced` / `Healthy`, two pods.

---

## Demonstration 2: rollback via git revert

### The point

Rollback is not a special mode, a button, or a `helm rollback` command. It is
**an ordinary commit that happens to undo an earlier one.** Which makes it
reviewable, attributable, and forward-only: there is no state your history cannot
explain.

### Setup

Left pane:

```bash
watch -n1 'kubectl --context kind-secure-delivery get application demo-app -n argocd \
  -o custom-columns=SYNC:.status.sync.status,REV:.status.sync.revision \
  && echo && kubectl --context kind-secure-delivery get pods -n demo \
  && echo && curl -s localhost:8082'
```

That last line puts the application's live response on screen for the whole
recording, changing as it happens.

Third pane: `make demo-ui` left running.

### Steps

**1. Baseline.**

The watch pane shows `Chapter 2: the cluster pulls from Git` and a `REV` column
holding the current commit SHA.

```bash
git log --oneline -1
```

Point out that the SHA in `REV` and the SHA in `git log` are the same.

**2. Make a change that is visibly wrong.**

Edit `GREETING` in `platform/manifests/demo-app/deployment.yaml`:

```yaml
- name: GREETING
  value: "BROKEN DEPLOY - do not ship"
```

```bash
git add platform/manifests/demo-app/deployment.yaml
git commit -m "demo: change greeting (this is the bad deploy)"
git push
```

**3. Do nothing.**

This is the beat that matters. Do not run a deploy command. Do not open the
ArgoCD UI and press anything. **Just wait, on camera, in silence.**

Within about 30 to 35 seconds the watch pane flips to `OutOfSync`, ArgoCD syncs,
the pods roll, and the curl output changes to the broken text.

Say: *I did not deploy anything. I pushed to Git and waited. The cluster
noticed.*

If you would rather not have the silence in the edit,
`argocd app get demo-app --refresh` forces the poll immediately. Keep the wait if
you can. The silence is the demonstration.

> Capture: `evidence/11-bad-commit-deployed.png`
> The watch pane showing the broken greeting live, with the bad commit's SHA in
> the REV column.

**4. Roll back.**

```bash
git revert --no-edit HEAD
git push
git log --oneline -3
```

Three commits now: the good one, the bad one, the revert.

Narrate: *I did not delete the bad commit or force-push over it. The mistake is
still in the history, and so is the correction, each with a timestamp and an
author. In a regulated environment that history is the audit evidence.*

**5. Watch it heal.**

`OutOfSync`, sync, pods roll, and the curl output returns to the original
greeting. The `REV` column now shows the **revert commit's** SHA.

Point at it: *the cluster is not "back to the old version". It is at a new commit
that happens to describe the old state.* Forward-only history, no ambiguity about
what is running.

> Capture: `evidence/12-git-revert-restored.png`
> The restored greeting alongside `git log --oneline -3` showing all three
> commits.

**6. Close the loop.**

```bash
kubectl --context kind-secure-delivery get application demo-app -n argocd \
  -o jsonpath='{.status.sync.revision}{"\n"}'
git rev-parse HEAD
```

Same SHA. The cluster's state and the repository's state are the same fact.

**7. The closing line.**

*At no point in either demonstration did anything outside this cluster hold a
credential that could write to it. I pushed to Git. The cluster pulled. The
connection was outbound the entire time.*

---

## Demonstration 3: the bypass, and Kyverno refusing it

Chapter 3. This is the one that proves the platform's central claim, so it is
worth more rehearsal than the other two.

### The point, and the mistake nearly everyone makes on camera

**Do not demonstrate this by trying to run an image from Docker Hub.**

Deploying `nginx` into a namespace and watching it get rejected proves almost
nothing, because a viewer cannot tell whether the policy checked a signature or
simply blocked an unfamiliar registry. Worse, it is the demo that a badly written
policy passes: a rule scoped to `imageReferences: ["*.dkr.ecr.*"]` would reject
nothing at all, and the recording would look identical.

The convincing version has three properties:

1. The rejected image is in **your own registry**, pushed with **your own
   legitimate credentials**. Nothing about the registry or the network stops it.
2. The rejected image is **byte for byte a real build of this application**, not
   something obviously foreign.
3. The demonstration ends by signing the rogue image with **a perfectly valid
   Cosign signature made by you**, and showing that Kyverno **still** refuses it.

Step 7 is the one that lands. It is what separates "the policy checks that
something is signed" from "the policy checks *who* signed it", and only the
second is a supply chain control.

Say that out loud on the recording. Being the person who explains why the obvious
demo is weak is worth more than the demo.

### Prerequisites

The pipeline must have run at least once, so there is a real signed image to
contrast against.

```bash
make up
make argocd-up
make argocd-status          # kyverno, kyverno-policies and demo-app all Synced
make supply-chain-status    # both policies present, Enforce, failurePolicy Fail
```

You need `cosign`, `docker`, `jq` and the AWS CLI. `make check-tools` reports
what is missing.

### Setup

```bash
export AWS_REGION=eu-west-2
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_REPO=secure-delivery-ci/app
export REGISTRY=${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
export IMAGE=${REGISTRY}/${ECR_REPO}
export IDENTITY="https://github.com/clintonsenaye/secure-delivery-platform/.github/workflows/build-sign-attest.yml@refs/heads/main"
export ISSUER="https://token.actions.githubusercontent.com"
export K="kubectl --context kind-secure-delivery"
```

Left pane, running throughout:

```bash
watch -n1 'kubectl --context kind-secure-delivery get pods -n demo -o wide; echo; \
  kubectl --context kind-secure-delivery get events -n demo --sort-by=.lastTimestamp | tail -8'
```

---

### Step 0. Establish that the gate is not simply blocking everything

**This has to come first.** A policy that rejects the rogue image proves nothing
if it also rejects the legitimate one. Show the good path working before you
attack it.

```bash
GOOD=$($K get deploy demo-app -n demo -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "$GOOD"
```

Point at the `@sha256:` in that string and say why it is not a tag. That is
[docs/architecture.md](architecture.md) section 24 in one line.

```bash
cosign verify \
  --certificate-identity="$IDENTITY" \
  --certificate-oidc-issuer="$ISSUER" \
  "$GOOD" | jq -r '.[0].optional.Subject, .[0].optional.Issuer'

cosign tree "$GOOD"        # the .sig and .att artefacts hanging off the digest
$K get pods -n demo        # two pods, Running
```

`make verify-running-image` does the same thing in one command, reading the image
from the live Deployment rather than from Git.

---

### Step 1. Build a rogue image on this laptop

```bash
docker build \
  --build-arg VERSION=0.9.9-rogue \
  --build-arg GIT_COMMIT=none \
  --build-arg BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t "${IMAGE}:rogue" app/src
```

This is a genuine, working build of the same application. Nothing about it is
malformed. That is deliberate: the control being demonstrated is provenance, not
content inspection.

---

### Step 2. Push it to ECR, outside the pipeline, with your own credentials

```bash
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

docker push "${IMAGE}:rogue"

ROGUE_DIGEST=$(aws ecr describe-images \
  --repository-name "$ECR_REPO" \
  --image-ids imageTag=rogue \
  --region "$AWS_REGION" \
  --query 'imageDetails[0].imageDigest' --output text)

export ROGUE="${IMAGE}@${ROGUE_DIGEST}"
echo "$ROGUE"
```

**The push succeeds, and that is the point.** ECR does not care who built the
image or how. Registry access is not the control. Say so on the recording: the
threat being modelled here is not a broken pipeline, it is a human who
legitimately holds registry credentials and bypasses the pipeline entirely,
which is by far the more common real world scenario.

---

### Step 3. Prove it is genuinely unsigned

```bash
cosign tree "$ROGUE"                     # no .sig, no .att
cosign verify \
  --certificate-identity="$IDENTITY" \
  --certificate-oidc-issuer="$ISSUER" \
  "$ROGUE"
```

Expected:

```text
Error: no matching signatures
```

---

### Step 4. Try to run it as a bare pod

**The overrides below are not padding.** The `demo` namespace enforces Pod
Security Admission at `restricted` from chapter 2, and a pod that fails PSA is
rejected by PSA rather than by Kyverno. That would demonstrate the wrong control
and an attentive viewer would notice. This pod satisfies PSA completely, so the
only thing left to reject it is the signature policy.

```bash
$K run rogue -n demo --restart=Never \
  --image="$ROGUE" \
  --overrides='{
    "spec": {
      "serviceAccountName": "demo-app",
      "automountServiceAccountToken": false,
      "securityContext": {
        "runAsNonRoot": true, "runAsUser": 65532, "runAsGroup": 65532,
        "seccompProfile": {"type": "RuntimeDefault"}
      },
      "containers": [{
        "name": "rogue",
        "image": "'"$ROGUE"'",
        "securityContext": {
          "allowPrivilegeEscalation": false,
          "readOnlyRootFilesystem": true,
          "capabilities": {"drop": ["ALL"]}
        }
      }]
    }
  }'
```

Expected, immediately, on stdout:

```text
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/demo/rogue was blocked due to the following policies

require-signed-images:
  verify-cosign-signature: 'failed to verify image
    ...secure-delivery-ci/app@sha256:...: .attestors[0].entries[0].keyless:
    no matching signatures'
```

The reason is on screen, in the terminal, at the moment of the attempt. That is
the frame worth capturing.

---

### Step 5. Try it the way a real deployment would arrive

```bash
cat > /tmp/rogue-deploy.yaml <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: rogue-app, namespace: demo}
spec:
  replicas: 1
  selector: {matchLabels: {app: rogue-app}}
  template:
    metadata: {labels: {app: rogue-app}}
    spec:
      serviceAccountName: demo-app
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: rogue
          image: ${ROGUE}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
YAML

$K apply -f /tmp/rogue-deploy.yaml
$K get deploy -n demo
```

Worth narrating, because it is a genuine operational trap. Kyverno's **autogen**
feature generates an equivalent rule for pod controllers, so the `Deployment`
itself is rejected at `kubectl apply` time. Without autogen the Deployment would
be *accepted*, a ReplicaSet created, and the rejection would surface only in
`kubectl describe replicaset` while the Deployment sat at zero available pods
looking exactly like a scheduling problem.

The difference between "rejected loudly" and "rejected quietly" is the difference
between a five second diagnosis and a bad afternoon.

---

### Step 6. Show the reason in three places

The terminal scrollback is not evidence. These are.

```bash
# The admission decision, as a cluster event
$K get events -n demo --sort-by=.lastTimestamp | tail -10

# Kyverno's own record, on the policy object
$K describe clusterpolicy require-signed-images | sed -n '/Events:/,$p'

# The engine log, with the full verification failure
$K logs -n kyverno -l app.kubernetes.io/component=admission-controller --tail=40 \
  | grep -i "rogue\|no matching signatures"
```

`make kyverno-status` prints the policies, their enforcement mode read from the
cluster rather than from the files, and the recent decisions, in one screen.

---

### Step 7. Sign it yourself, and watch it still fail

**This is the step that makes the demonstration worth recording.**

```bash
cosign sign --yes "$ROGUE"
```

A browser opens. Authenticate as yourself. Cosign obtains a real Fulcio
certificate for your own identity, signs the rogue image, and records the event
in the public Rekor log. This is a completely valid Sigstore signature.

```bash
# It really is signed, and it really does verify, against YOUR identity
cosign verify \
  --certificate-identity="your.email@example.com" \
  --certificate-oidc-issuer="https://accounts.google.com" \
  "$ROGUE" | jq -r '.[0].optional.Subject'
```

Now try to run it again:

```bash
$K run rogue2 -n demo --restart=Never --image="$ROGUE" \
  --overrides='{ ...exactly as in step 4, with name rogue2... }'
```

**Still rejected**, and the error still says `no matching signatures`.

The line to say out loud:

> *The policy does not ask whether this image is signed. It asks whether it was
> signed by that specific workflow, running on that specific branch, in that
> specific repository. I have a valid signature. It is the wrong one.*

This step also quietly exercises the `IMMUTABLE_WITH_EXCLUSION` change described
in [architecture.md](architecture.md) section 26. Without it, `cosign sign` fails
to push the `sha256-....sig` tag and the demonstration stops here for entirely
the wrong reason.

---

### Step 8. Show chapter 1's immutability doing its own separate job

```bash
GOOD_TAG=$(aws ecr describe-images --repository-name "$ECR_REPO" --region "$AWS_REGION" \
  --query 'reverse(sort_by(imageDetails,&imagePushedAt))[?imageTags]|[0].imageTags[0]' \
  --output text)
echo "$GOOD_TAG"

docker tag "${IMAGE}:rogue" "${IMAGE}:${GOOD_TAG}"
docker push "${IMAGE}:${GOOD_TAG}"
```

Expected:

```text
denied: The image tag '...' already exists in the '...' repository and cannot be
overwritten because the repository is configured to be immutable.
```

The registry refuses before admission control is ever consulted. Two independent
controls, at two different layers, and the recording shows both. This is also the
attack in [architecture.md](architecture.md) section 24 failing at step 2 rather
than at step 3.

---

### Step 9. Prove nothing was disturbed

```bash
$K get pods -n demo
make verify-running-image
```

The two legitimate pods have been Running throughout. **The gate rejected the new
thing rather than breaking the existing one**, which is the behaviour you want
from an admission control and is not what people expect the first time they see
it.

---

### Step 10. Clean up

```bash
$K delete pod rogue rogue2 -n demo --ignore-not-found
$K delete -f /tmp/rogue-deploy.yaml --ignore-not-found
rm -f /tmp/rogue-deploy.yaml

aws ecr batch-delete-image --repository-name "$ECR_REPO" --region "$AWS_REGION" \
  --image-ids imageTag=rogue imageDigest="$ROGUE_DIGEST" > /dev/null

docker rmi "${IMAGE}:rogue" "${IMAGE}:${GOOD_TAG}" 2>/dev/null || true
```

The signature you made in step 7 stays in the public Rekor log forever. It cannot
be deleted, by you or by anyone else. That is not a mistake in the cleanup
script, it is what an append only transparency log means, and it is worth one
closing sentence on the recording.

---

### The closing line

*Nothing runs on this cluster unless it can prove where it came from. Not "unless
it is signed", because I signed that image myself and it was still refused.
Unless it can prove it was built by this pipeline, from this repository, on this
branch, and that nobody has touched the bytes since.*

---

## Capturing evidence

Keep the naming convention from chapter 1: a two digit number, a hyphenated
description, `.png`.

```bash
# whole screen
gnome-screenshot -f evidence/07-argocd-app-synced.png

# or a selected region
gnome-screenshot -a -f evidence/07-argocd-app-synced.png
```

**Before committing any screenshot, check it the way chapter 1's evidence had to
be checked.** The images in this repository originally leaked a home IP address,
an AWS account ID, a console username and a terminal tab bar naming unrelated
production systems. `evidence/README.md` records what was removed and why.

For chapter 2 the exposure is much smaller, because everything runs on a local
kind cluster with no AWS account behind it. Still worth a look before each
commit:

- the terminal tab bar and window title
- the shell prompt hostname
- anything in a browser tab other than the one being demonstrated
- the ArgoCD repository URL, if the repository is ever made private again

**Chapter 3 reintroduces one exposure and it is worth being clear about it.**
Every image reference in demonstration 3 contains the AWS account ID, because an
ECR registry host is `<account-id>.dkr.ecr.<region>.amazonaws.com`. There is no
way around it: the digest reference is committed to
[platform/manifests/demo-app/deployment.yaml](../platform/manifests/demo-app/deployment.yaml)
in this public repository, so the account ID is already public and redacting it
from a screenshot would be theatre.

That is an accepted risk rather than an oversight. An account ID is not a secret,
it grants nothing on its own, and every role in the account is protected by a
trust policy that names this repository and this branch explicitly. It does help
an attacker enumerate role names, which is why it is recorded in
[architecture.md](architecture.md) section 28, limit 17.

What still must not appear in a chapter 3 screenshot:

- the output of `aws ecr get-login-password`, which is a live bearer token
- the contents of the `ecr-pull` secret, for the same reason
- any `~/.docker/config.json` with an `auth` field in it
- the browser window during `cosign sign` in step 7, which shows a personal
  identity provider account

Then add the new rows to the table in `evidence/README.md`.
