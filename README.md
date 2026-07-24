# OVR on Vultr

Deploys [open-visual-regression](https://github.com/open-visual-regression/open-visual-regression)
to a single 1 vCPU / 2GB Vultr instance, managed by ArgoCD running on a
separate local k3s cluster. This repo is the GitOps source of truth for that
deployment and doubles as a worked example of deploying OVR outside Docker
Compose.

## Architecture

- **ArgoCD control plane**: your existing local k3s install. It is not
  installed on the Vultr node — that would burn ~500MB-1GB of the node's 2GB
  on ArgoCD's own pods (server, repo-server, redis, app-controller, dex) for
  no benefit here.
- **Vultr node** ("vultr" cluster, registered with the local ArgoCD): runs
  Traefik (bundled with k3s), cert-manager, Valkey, and the OVR web/worker
  pods.
- **Database**: Neon (managed Postgres), not in-cluster.
- **Object storage**: AWS S3 (a real bucket + IAM user), not an in-cluster
  S3-compatible service.
- **App images**: built by the app repo's CI on merge to `main`, published to
  `ghcr.io/open-visual-regression/{web,worker}:main`. This repo only
  references that tag — it doesn't build anything.

`argocd/root.yaml` is an app-of-apps: apply it once, and it creates/syncs
everything else in `argocd/apps/` (cert-manager → cluster-issuer → Valkey →
the OVR chart, in that sync-wave order).

## ⚠️ Resource budget is tight

On an idle 2GB node, k3s and the OS hold ~825Mi of the 1637Mi available,
leaving **~810Mi** for the application stack. The k3s server process alone
accounts for ~666Mi — running your own control plane is the cost of a
self-managed single node.

Kubernetes does not know this by default. Out of the box k3s sets no
`--system-reserved`, so the scheduler reports the full 1637Mi as allocatable
and will cheerfully admit pods the node cannot actually feed — the kernel
OOM killer then picks the victim. The install in step 4 reserves 750Mi,
which brings reported allocatable down to a truthful ~787Mi.

Within that, the requests and limits in `values-vultr.yaml` are load-bearing,
not decoration:

| Component | Request | Limit |
|---|---|---|
| cert-manager (3 pods) | 72Mi | 288Mi |
| Valkey | 64Mi | 128Mi |
| web | 128Mi | 224Mi |
| worker (headless Chromium) | 320Mi | 512Mi |
| **total** | **584Mi** | **1152Mi** |

After k3s's own system pods (CoreDNS, Traefik, metrics-server, local-path)
take ~140Mi, that leaves ~647Mi of schedulable memory against 584Mi of
requests — it fits, with little room to add anything else. Limits
deliberately overcommit, since all four peaking at once is not a real
scenario. The node has a 5.3GB swapfile, so pressure degrades to slowness
rather than a hard OOM — but Chromium on swap is genuinely slow, so treat
sustained swapping as the signal to resize rather than something to tune
around.

If the worker gets OOMKilled repeatedly, resize the Vultr instance. Raising
`worker.concurrency` on this node will not help.

## One-time setup

### 1. Provision the Vultr node

Via the Vultr console or `vultr-cli`, create a 1 vCPU / 2GB instance (the
cheapest "Cloud Compute" plan). Ubuntu 24.04 LTS is a safe default OS choice.
Note its public IP.

### 2. Point DNS at it

In Namecheap, add an A record for `openvisualregression.com` (and `www` if
you want it) pointing at the node's public IP. Propagation is usually quick
but can take up to a few hours.

### 3. Lock down the node with a Vultr firewall

Attach a Vultr Firewall Group to the instance before exposing anything. The
k3s API (6443) must be reachable by your **local** cluster (that's where
ArgoCD runs and connects from), but it should not be open to the whole
internet — an exposed k3s API is a real attack surface.

| Port | Source | Why |
|---|---|---|
| 22 (SSH) | your IP | admin |
| 80 (HTTP) | anywhere | Let's Encrypt http-01 challenge + redirect |
| 443 (HTTPS) | anywhere | the app |
| 6443 (k8s API) | your local egress IP | ArgoCD → this cluster |

Your "local egress IP" is the public IP your home/office NATs out through —
`curl -s ifconfig.me` from the ArgoCD machine. If it's dynamic, you'll have
to update the rule when it changes. More robust option: put both machines on
a [Tailscale](https://tailscale.com) tailnet, register the cluster by its
tailnet IP (step 5) and never open 6443 publicly at all — if you do, use the
tailnet IP wherever `<node-ip>` appears below and add it to `--tls-san` in
step 4.

Ubuntu images also ship with `ufw` enabled and only port 22 open, which
blocks the same traffic at the host level. A cloud firewall rule alone is
not enough — the symptom is `kubectl` hanging with `dial tcp <node-ip>:6443:
i/o timeout` while the API server is demonstrably healthy on the node
itself. Open the same ports there:

```sh
ufw allow from <your-egress-ip> to any port 6443 proto tcp
ufw allow 80/tcp
ufw allow 443/tcp
```

`ufw`'s default `FORWARD DROP` policy does not break k3s pod networking —
k3s inserts its own ACCEPT rules ahead of it.

### 4. Install k3s on the node

```sh
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--tls-san <node-ip> \
  --kubelet-arg=system-reserved=memory=750Mi,cpu=200m \
  --kubelet-arg=eviction-hard=memory.available<100Mi" sh -
```

- `--tls-san` adds the address you reach the API by to the server cert's SAN
  list. Required if that address is anything other than the node's primary
  interface IP — a Tailscale IP, a VPC IP, a DNS name.
- `system-reserved` accounts for the memory k3s and the OS consume outside
  the pod budget. Without it the scheduler overcommits a 2GB node into the
  OOM killer (see the resource budget above).
- `eviction-hard` lets the kubelet evict a pod gracefully before the kernel
  picks a victim.

This installs k3s with Traefik and the local-path storage provisioner
enabled by default — both are used here. Confirm it's up:

```sh
sudo k3s kubectl get nodes
```

### 5. Register the node with your local ArgoCD

Pull the node's kubeconfig and merge it locally:

```sh
ssh root@<node-ip> cat /etc/rancher/k3s/k3s.yaml > /tmp/vultr-k3s.yaml
# Edit /tmp/vultr-k3s.yaml: replace the server URL (127.0.0.1) with https://<node-ip>:6443
KUBECONFIG=~/.kube/config:/tmp/vultr-k3s.yaml kubectl config view --flatten > /tmp/merged.yaml
mv /tmp/merged.yaml ~/.kube/config
kubectl config rename-context default vultr
```

Then register it with ArgoCD **with exactly this name** — the Application
manifests in `argocd/apps/` reference the cluster as `vultr`:

```sh
argocd cluster add vultr --name vultr
```

### 6. Create the Neon database

Create a Neon project and database (e.g. `open_visual_regression`). Copy the
**pooled** connection string (the host ends in `-pooler`) — it keeps the
node's web + worker pods from exhausting Neon's direct-connection limit.
`sslmode=require` is already part of the string Neon gives you.

Migrations are the exception: Drizzle's migrator uses prepared statements,
which pgbouncer's transaction pooling breaks. If the migrate Job fails with a
prepared-statement error, re-run step 8 with the **direct** (non-pooler)
connection string instead.

### 7. Create the S3 bucket + IAM user

In AWS: create a bucket (e.g. `ovr`, region `us-east-1` — match whatever you
pick in `helm/ovr/values-vultr.yaml`'s `storage.bucket`/`storage.region`),
and an IAM user with a policy scoped to just that bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::ovr/*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::ovr"
    }
  ]
}
```

Create an access key for that user — you'll need it in the next step.

### 8. Bootstrap the app secret

Nothing sensitive is committed to this repo. Create the `ovr-secrets` Secret
directly on the Vultr cluster:

```sh
kubectl config use-context vultr
DATABASE_URL=<from step 6> \
AWS_ACCESS_KEY_ID=<from step 7> \
AWS_SECRET_ACCESS_KEY=<from step 7> \
  ./scripts/create-secrets.sh
```

### 9. Apply the root Application

```sh
kubectl config use-context <your-local-argocd-context>
kubectl apply -f argocd/root.yaml
```

ArgoCD takes it from here: cert-manager installs, the ClusterIssuer comes up,
Valkey deploys, then the OVR chart (migration Job, then web/worker).

### 10. Verify

```sh
argocd app list
kubectl --context vultr -n ovr get pods
```

Once the migration Job completes and web/worker are Running, visit
`https://openvisualregression.com`.

## Picking up new app releases

The chart tracks the `main` image tag with `pullPolicy: Always`
(`helm/ovr/values-vultr.yaml`), so a rollout restart — not just an ArgoCD
sync — is what actually fetches a new build:

```sh
kubectl --context vultr -n ovr rollout restart deployment/ovr-app-web deployment/ovr-app-worker
```

This is a manual step by design — no image-watching automation runs on the
node to keep the RAM budget clear. If you want new merges deployed
automatically, look at Argo CD Image Updater (it would run alongside ArgoCD
on your local cluster, not on the Vultr node, so it wouldn't compete for the
node's RAM) rather than adding anything here.

## Repo layout

- `data/` — Valkey, plain manifests, no Helm.
- `helm/ovr/` — the OVR chart (web, worker, migration Job). See
  `helm/ovr/README.md` for chart-level details.
- `helm/ovr/values-vultr.yaml` — the values overlay for this deployment.
- `argocd/` — ArgoCD Application manifests (app-of-apps).
- `cluster-issuer.yaml` — cert-manager ClusterIssuer for Let's Encrypt via
  Traefik's http01 solver.
- `scripts/create-secrets.sh` — one-time Secret bootstrap, run by hand.
