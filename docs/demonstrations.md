# Demonstrations

Two recordings for chapter 2: **self-healing** and **rollback via git revert**.

Both run on the local kind cluster and cost nothing. Both assume:

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

Then add the new rows to the table in `evidence/README.md`.
