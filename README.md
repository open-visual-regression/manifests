# OVR on Vultr

Deploys [open-visual-regression](https://github.com/open-visual-regression/open-visual-regression)
to two Vultr instances, managed by ArgoCD running on a separate local k3s
cluster. This repo is the GitOps source of truth for that deployment and
doubles as a worked example of deploying OVR outside Docker Compose.

## Architecture

- **ArgoCD control plane**: your existing local k3s install. It is not
  installed on either Vultr node — that would burn several hundred MB of RAM
  on ArgoCD's own pods (server, repo-server, redis, app-controller, dex) for
  no benefit here.
- **Vultr control-plane node** ("vultr" in the local ArgoCD, a 2GB instance):
  runs k3s's own control plane (etcd/apiserver/scheduler), Traefik (bundled
  with k3s), cert-manager, Valkey, and the OVR **web** pod.
- **Vultr worker node** ("vultr-worker", a 1GB instance joined to the same
  cluster as a k3s agent): runs only the OVR **worker** pod. It's tainted so
  nothing else can schedule there — headless Chromium is the heaviest,
  spikiest consumer in this stack, and isolating it keeps a busy capture run
  from starving the API server, CoreDNS, or ingress.
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

Each node has its own budget; they are no longer shared.

### Control-plane node (2GB)

k3s's own control-plane processes and the OS hold ~825Mi of the 1637Mi
available, leaving a **truthful ~787Mi** allocatable (the install in step 4
sets `system-reserved` so the scheduler doesn't overcommit this — see below).

| Component | Request | Limit |
|---|---|---|
| cert-manager (3 pods) | 72Mi | 288Mi |
| CoreDNS | 70Mi | 170Mi |
| Valkey | 64Mi | 128Mi |
| web | 160Mi | 320Mi |
| **total** | **~366Mi** | **~906Mi** |

That leaves comfortable headroom against the 787Mi allocatable — this node no
longer hosts the worker, so it's far less contested than a single-node setup
would be. cert-manager also schedules a short-lived ACME solver pod during
certificate issuance/renewal; the headroom here easily covers it.

### Worker node (1GB)

The 1GB plan reports ~950Mi total RAM, but k3s-agent itself uses ~300Mi RSS.
Without accounting for that, the scheduler would report the full amount as
allocatable and could pack the worker pod tightly enough to starve the agent
itself. The join in step 4b sets `system-reserved=memory=350Mi`, bringing
allocatable down to a truthful **~600Mi**.

| Component | Request | Limit |
|---|---|---|
| worker (headless Chromium) | 400Mi | 550Mi |

That's most of the node's budget by design — it's a single-purpose box.
Traefik's per-node `svclb` proxy pod also lands here (it tolerates all
taints, by k3s design, so every node can advertise the LoadBalancer IP); it's
a few MB and not worth budgeting around.

Both nodes have a swapfile, so memory pressure degrades to slowness rather
than a hard OOM — but Chromium on swap is genuinely slow, so treat sustained
swapping as the signal to resize rather than something to tune around. If the
worker gets OOMKilled repeatedly, resize `vultr-worker`. Raising
`worker.concurrency` will not help; the bottleneck is per-browser memory, not
queue throughput.

## One-time setup

### 1. Provision the Vultr nodes

Via the Vultr console or `vultr-cli`, create **two** instances in the same
region:

- Control-plane node: 1 vCPU / 2GB (the cheapest "Cloud Compute" plan).
- Worker node: 1 vCPU / 1GB (High Frequency or High Performance — a dollar or
  two more than the base Cloud Compute tier, worth it for the faster core a
  single-threaded Chromium workload actually benefits from).

Ubuntu 24.04+ LTS is a safe default OS choice for both. Note both public IPs.

### 2. Point DNS at the control-plane node

In Namecheap, add an A record for `openvisualregression.com` (and `www` if
you want it) pointing at the **control-plane node's** public IP — that's the
one running Traefik ingress. The worker node is never addressed directly, by
anything. Propagation is usually quick but can take up to a few hours.

### 3. Lock down both nodes with Vultr firewalls

Use **two separate firewall groups**, one per node — the worker's role is
narrow enough (no ingress, no public service) that it doesn't need the
control-plane node's public-facing rules, and giving it those rules anyway
would just be an unused, unnecessary hole to the internet.

**Control-plane node's group:**

| Port | Protocol | Source | Why |
|---|---|---|---|
| 22 | tcp | your IP | admin |
| 80 | tcp | anywhere | Let's Encrypt http-01 challenge + redirect |
| 443 | tcp | anywhere | the app |
| 6443 | tcp | your local egress IP | ArgoCD → this cluster |
| 6443 | tcp | worker node's IP | worker → apiserver |
| 8472 | udp | worker node's IP | flannel vxlan (pod networking) |
| 10250 | tcp | worker node's IP | kubelet |

**Worker node's group:**

| Port | Protocol | Source | Why |
|---|---|---|---|
| 22 | tcp | your IP | admin |
| 8472 | udp | control-plane node's IP | flannel vxlan (pod networking) |
| 10250 | tcp | control-plane node's IP | kubelet |

Nothing else needs to be open on the worker — no 6443 (it only calls out, and
egress isn't firewalled), no 80/443 (it serves nothing).

Your "local egress IP" is the public IP your home/office NATs out through —
`curl -s ifconfig.me` from the ArgoCD machine. If it's dynamic, you'll have
to update the rule when it changes. More robust option: put both machines on
a [Tailscale](https://tailscale.com) tailnet, register the cluster by its
tailnet IP (step 5) and never open 6443 publicly at all — if you do, use the
tailnet IP wherever `<node-ip>` appears below and add it to `--tls-san` in
step 4.

**A Vultr cloud firewall group is enforced before traffic ever reaches either
host.** Ubuntu images also ship `ufw` enabled with only port 22 open, which
blocks the same traffic again at the host level — you need matching `ufw`
rules on both boxes too, or the cloud firewall rules above won't be enough on
their own. The symptom of missing either layer is a k3s agent stuck logging
`Failed to validate connection to cluster: ... context deadline exceeded`
forever, or `kubectl` hanging with `dial tcp <node-ip>:6443: i/o timeout`
while the API server is demonstrably healthy on the node itself.

```sh
# on the control-plane node
ufw allow from <your-egress-ip> to any port 6443 proto tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow from <worker-node-ip> to any port 6443 proto tcp
ufw allow from <worker-node-ip> to any port 8472 proto udp
ufw allow from <worker-node-ip> to any port 10250 proto tcp

# on the worker node
ufw allow from <control-plane-ip> to any port 8472 proto udp
ufw allow from <control-plane-ip> to any port 10250 proto tcp
```

`ufw`'s default `FORWARD DROP` policy does not break k3s pod networking — k3s
inserts its own ACCEPT rules ahead of it.

### 4. Install k3s on the control-plane node

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

### 4b. Join the worker node

Grab the node token from the control-plane node, then use it to install k3s
in **agent** mode on the worker node:

```sh
ssh root@<control-plane-ip> cat /var/lib/rancher/k3s/server/node-token
```

Before installing, write `/etc/rancher/k3s/config.yaml` on the worker node so
it registers with the right label, taint, and memory accounting from the
start:

```yaml
node-label:
  - "ovr.io/role=worker"
node-taint:
  - "ovr.io/dedicated=worker:NoSchedule"
kubelet-arg:
  - "system-reserved=cpu=100m,memory=350Mi"
```

Then join it:

```sh
curl -sfL https://get.k3s.io | \
  K3S_URL=https://<control-plane-ip>:6443 \
  K3S_TOKEN=<token from above> \
  K3S_NODE_NAME=vultr-worker \
  sh -
```

Confirm both nodes show up (from the control-plane node, or via the merged
kubeconfig in step 5):

```sh
kubectl get nodes -o wide
```

**Important caveat on the taint:** `--node-taint` (like `--register-with-taints`
in upstream kubelet) is only applied the *first* time a node registers — if
you add `node-taint` to `config.yaml` after a node has already joined once,
restarting `k3s-agent` will not retroactively apply it. `--node-label`
doesn't have this limitation; k3s reconciles it on every agent start. If
you're adding the taint to an already-registered node, apply it once by hand
instead:

```sh
kubectl taint nodes vultr-worker ovr.io/dedicated=worker:NoSchedule
```

Once applied this way it persists across agent restarts exactly like a
first-registration taint would — the caveat only matters for how you *get*
it applied, not for whether it holds afterward. Keeping the entry in
`config.yaml` regardless is still worth it: it's what makes a from-scratch
rejoin (e.g. after wiping the node) come back correctly tainted with no
manual step.

### 5. Register the cluster with your local ArgoCD

Pull the control-plane node's kubeconfig and merge it locally — you only
register the cluster once; the worker node is invisible to ArgoCD, it's just
another node inside the one cluster:

```sh
ssh root@<control-plane-ip> cat /etc/rancher/k3s/k3s.yaml > /tmp/vultr-k3s.yaml
# Edit /tmp/vultr-k3s.yaml: replace the server URL (127.0.0.1) with https://<control-plane-ip>:6443
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
web/worker pods from exhausting Neon's direct-connection limit.
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
Valkey deploys, then the OVR chart (migration Job, then web/worker). The
worker Deployment's `nodeSelector`/`tolerations` (set in
`helm/ovr/values-vultr.yaml`) send it to `vultr-worker`; web has no such
constraint and schedules on the control-plane node by elimination (it's the
only untainted one).

### 10. Verify

```sh
argocd app list
kubectl --context vultr -n ovr get pods -o wide
```

Confirm `ovr-app-web` lands on the control-plane node and `ovr-app-worker`
lands on `vultr-worker`. Once the migration Job completes and both are
Running, visit `https://openvisualregression.com`.

## Picking up new app releases

The chart tracks the `main` image tag with `pullPolicy: Always`
(`helm/ovr/values-vultr.yaml`), so a rollout restart — not just an ArgoCD
sync — is what actually fetches a new build:

```sh
kubectl --context vultr -n ovr rollout restart deployment/ovr-app-web deployment/ovr-app-worker
```

The chart deploys with `strategy.type: Recreate`, so this restart costs a
few seconds of downtime rather than running old and new pods side by side —
the right trade on nodes with little memory to spare. If you're running with
real headroom to spare, switch to `RollingUpdate` for zero downtime.

This restart is a manual step by design — no image-watching automation runs
on either Vultr node to keep their RAM budgets clear. If you want new merges
deployed automatically, look at Argo CD Image Updater (it would run
alongside ArgoCD on your local cluster, not on either Vultr node, so it
wouldn't compete for either node's RAM) rather than adding anything here.

## Repo layout

- `data/` — Valkey, plain manifests, no Helm.
- `helm/ovr/` — the OVR chart (web, worker, migration Job). See
  `helm/ovr/README.md` for chart-level details.
- `helm/ovr/values-vultr.yaml` — the values overlay for this deployment,
  including the worker's node pinning.
- `argocd/` — ArgoCD Application manifests (app-of-apps).
- `cluster-issuer.yaml` — cert-manager ClusterIssuer for Let's Encrypt via
  Traefik's http01 solver.
- `scripts/create-secrets.sh` — one-time Secret bootstrap, run by hand.
