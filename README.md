# OVR deployment

Deploys [open-visual-regression](https://github.com/open-visual-regression/open-visual-regression)
to two cloud instances, managed by ArgoCD running on a separate local k3s
cluster. This repo is the GitOps source of truth for that deployment and
doubles as a worked example of deploying OVR outside Docker Compose.

Deliberately provider-agnostic: nothing here names a specific cloud. The
instances have moved providers before and may again — node names, the
registered cluster name, and the values file are all generic so a future move
only touches IPs and provider-specific console steps, not the manifests.

## Architecture

- **ArgoCD control plane**: your existing local k3s install. It is not
  installed on either remote node — that would burn several hundred MB of RAM
  on ArgoCD's own pods (server, repo-server, redis, app-controller, dex) for
  no benefit here.
- **Control-plane node** (registered with the local ArgoCD as `prod`, node
  name `web`): runs k3s's own control plane (etcd/apiserver/scheduler),
  Traefik (bundled with k3s), cert-manager, Valkey, and the OVR **web** pod.
- **Worker node** (node name `worker`, joined to the same cluster as a k3s
  agent): runs only the OVR **worker** pod. It's tainted so nothing else can
  schedule there — headless Chromium is the heaviest, spikiest consumer in
  this stack, and isolating it keeps a busy capture run from starving the API
  server, CoreDNS, or ingress.
- **Database**: Neon (managed Postgres), not in-cluster.
- **Object storage**: AWS S3 (a real bucket + IAM user), not an in-cluster
  S3-compatible service.
- **App images**: built by the app repo's CI, published to
  `ghcr.io/open-visual-regression/{web,worker}`. This repo builds nothing.
- **The chart**: lives in the app repo at `charts/ovr` and is published as an
  OCI artifact to `ghcr.io/open-visual-regression/charts`. This repo consumes
  a pinned version of it and supplies only `values-prod.yaml`. It used to
  vendor the chart under `helm/ovr`, which tied the chart's lifecycle to this
  one deployment instead of to the app it deploys.

`argocd/root.yaml` is an app-of-apps: apply it once, and it creates/syncs
everything else in `argocd/apps/` (cert-manager → cluster-issuer → Valkey →
the OVR chart, in that sync-wave order).

## Resource accounting

Each node has its own budget; they are not shared. Whatever instance size you
pick, account for k3s's own overhead explicitly via `system-reserved` (see
step 4/4b below) — otherwise the scheduler treats the box's full RAM as
allocatable and can pack a pod tightly enough to starve k3s itself. Currently
running on 2 vCPU / 4GB instances per node:

### Control-plane node

`system-reserved=memory=750Mi,cpu=200m` leaves **~2.9Gi / 1800m** allocatable.

| Component | Request | Limit |
|---|---|---|
| cert-manager (3 pods) | 72Mi | 288Mi |
| CoreDNS | 70Mi | 170Mi |
| Valkey | 64Mi | 128Mi |
| web | 160Mi | 320Mi |
| **total** | **~366Mi** | **~906Mi** |

Comfortable headroom against the ~2.9Gi allocatable. cert-manager also
schedules a short-lived ACME solver pod during certificate issuance/renewal;
the headroom here easily covers it.

### Worker node

`system-reserved=cpu=100m,memory=350Mi` leaves **~3.4Gi / 1900m** allocatable.

| Component | Request | Limit |
|---|---|---|
| worker (headless Chromium) | 400Mi | 2Gi |

Real headroom here now, which is why both `web` and `worker` run
`updateStrategy: RollingUpdate` (`values-prod.yaml`) — a brief
old+new pod overlap during a rollout fits comfortably on either node.
BullMQ's per-job locking also makes two worker pods briefly sharing the
capture queue mid-rollout safe, not a double-processing risk.

Both nodes should have a swapfile, so memory pressure degrades to slowness
rather than a hard OOM — but Chromium on swap is genuinely slow, so treat
sustained swapping as the signal to resize rather than something to tune
around. If the worker gets OOMKilled repeatedly, resize it.

`worker.concurrency` is how many capture groups run at once, each with its own
Chromium. On a 2-vCPU node the ceiling is CPU, not memory: one group averages
~715m during a build against a 1700m limit and 1900m allocatable, so 2 fit and
a third would saturate the node. Capture is partly I/O-bound (artifact upload
is ~20% of per-snapshot wall time), so a second group overlaps that dead time —
but throughput scales sub-linearly, closer to 1.5x than 2x. Confirm against
`kubectl get --raw /api/v1/nodes/worker/proxy/stats/summary` before raising it;
CPU PSI `full` climbing off zero means the node is out of room.

## One-time setup

### 1. Provision two instances

With your cloud provider of choice, create **two** instances in the same
region (and, if using private networking — see step 2 — the same network
zone): a control-plane node and a worker node. 2 vCPU / 4GB per node is a
comfortable baseline for this stack; go smaller and you'll want to revisit
the resource budget above. Ubuntu 24.04+ LTS is a safe default OS choice for
both. Note both public IPs.

### 2. Optional: private networking between the two nodes

If your provider supports a private network between instances in the same
project, use it for node-to-node k3s traffic (the apiserver, flannel vxlan,
kubelet) instead of exposing those ports publicly — it's one less set of
public firewall rules and one less thing to lock down.

Pick a private IP range that does **not** overlap k3s's own internal CIDRs:
pod networking defaults to `10.42.0.0/16` and services to `10.43.0.0/16`.
`10.0.0.0/24` (or any other `/16` inside `10.0.0.0/8` other than `.42`/`.43`)
is a safe, simple choice.

Attaching the network isn't enough on its own — k3s still advertises each
node's public IP to the others unless told otherwise. Pass the node's private
IP and private interface name explicitly at install time (`--node-ip`,
`--flannel-iface` in steps 4/4b below); find the interface name with `ip -4
addr show` on the box once the network is attached.

Whether your provider's cloud firewall product filters private-network
traffic at all varies — some exempt it entirely (in which case the
node-to-node ports below need no public rule whatsoever), others don't. Check
yours before assuming either way; if it doesn't exempt private traffic,
you'll need equivalent rules scoped to the private subnet instead of the
public IPs shown below.

### 3. Point DNS at the control-plane node

Add an A record for `openvisualregression.com` (and `www` if you want it)
pointing at the **control-plane node's** public IP — that's the one running
Traefik ingress. The worker node is never addressed directly, by anything.
Propagation is usually quick but can take up to a few hours.

If you're cutting over an already-live deployment rather than a fresh build,
lower the record's TTL well ahead of time and flip it **last**, only once
the new cluster is fully up and verified (curl the new node's public IP
directly with a `Host` header override to sanity-check before touching DNS).
cert-manager's HTTP-01 challenge can't get a valid cert for the new node
until DNS already resolves there, so a short gap between DNS propagating and
the new cert issuing is unavoidable with this setup.

### 4. Lock down both nodes with a cloud firewall

Use **two separate firewall policies**, one per node — the worker's role is
narrow enough (no ingress, no public service) that it doesn't need the
control-plane node's public-facing rules, and giving it those rules anyway
would just be an unused, unnecessary hole to the internet.

**Control-plane node:**

| Port | Protocol | Source | Why |
|---|---|---|---|
| 22 | tcp | your IP | admin |
| 80 | tcp | anywhere | Let's Encrypt http-01 challenge + redirect |
| 443 | tcp | anywhere | the app |
| 6443 | tcp | your local egress IP | ArgoCD → this cluster |
| 6443 | tcp | worker node's IP | worker → apiserver (skip if using private networking) |
| 8472 | udp | worker node's IP | flannel vxlan (skip if using private networking) |
| 10250 | tcp | worker node's IP | kubelet (skip if using private networking) |

**Worker node:**

| Port | Protocol | Source | Why |
|---|---|---|---|
| 22 | tcp | your IP | admin |
| 8472 | udp | control-plane node's IP | flannel vxlan (skip if using private networking) |
| 10250 | tcp | control-plane node's IP | kubelet (skip if using private networking) |

Nothing else needs to be open on the worker — no 6443 (it only calls out, and
egress isn't firewalled), no 80/443 (it serves nothing).

Your "local egress IP" is the public IP your home/office NATs out through —
`curl -s ifconfig.me` from the ArgoCD machine. If it's dynamic, you'll have
to update the rule when it changes. More robust option: put both machines on
a [Tailscale](https://tailscale.com) tailnet, register the cluster by its
tailnet IP (step 6) and never open 6443 publicly at all — if you do, use the
tailnet IP wherever `<node-ip>` appears below and add it to `--tls-san` in
step 4.

**A cloud firewall is enforced before traffic ever reaches either host.**
Ubuntu images also ship `ufw` enabled with only port 22 open, which blocks
the same traffic again at the host level — you need matching `ufw` rules on
both boxes too (scoped to private IPs instead if you're relying on private
networking and your provider's firewall doesn't filter it), or the cloud
firewall rules above won't be enough on their own. The symptom of missing
either layer is a k3s agent stuck logging `Failed to validate connection to
cluster: ... context deadline exceeded` forever, or `kubectl` hanging with
`dial tcp <node-ip>:6443: i/o timeout` while the API server is demonstrably
healthy on the node itself.

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

### 5. Install k3s on the control-plane node

```sh
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--tls-san <node-ip> \
  --node-name=web \
  --kubelet-arg=system-reserved=memory=750Mi,cpu=200m \
  --kubelet-arg=eviction-hard=memory.available<100Mi" sh -
```

If using private networking (step 2), also add `--node-ip=<private-ip>
--flannel-iface=<private-iface>`.

- `--tls-san` adds the address you reach the API by to the server cert's SAN
  list. Required if that address is anything other than the node's primary
  interface IP — a Tailscale IP, a VPC IP, a DNS name.
- `system-reserved` accounts for the memory k3s and the OS consume outside
  the pod budget. Without it the scheduler overcommits into the OOM killer
  (see the resource accounting above).
- `eviction-hard` lets the kubelet evict a pod gracefully before the kernel
  picks a victim.

This installs k3s with Traefik and the local-path storage provisioner
enabled by default — both are used here. Confirm it's up:

```sh
sudo k3s kubectl get nodes
```

### 5b. Join the worker node

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
  K3S_NODE_NAME=worker \
  sh -
```

If using private networking, use the control-plane's **private** IP for
`K3S_URL` and add `INSTALL_K3S_EXEC="--node-ip=<worker-private-ip>
--flannel-iface=<private-iface>"`.

Confirm both nodes show up (from the control-plane node, or via the merged
kubeconfig in step 6):

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
kubectl taint nodes worker ovr.io/dedicated=worker:NoSchedule
```

Once applied this way it persists across agent restarts exactly like a
first-registration taint would — the caveat only matters for how you *get*
it applied, not for whether it holds afterward. Keeping the entry in
`config.yaml` regardless is still worth it: it's what makes a from-scratch
rejoin (e.g. after wiping the node) come back correctly tainted with no
manual step.

### 6. Register the cluster with your local ArgoCD

Pull the control-plane node's kubeconfig and merge it locally — you only
register the cluster once; the worker node is invisible to ArgoCD, it's just
another node inside the one cluster:

```sh
ssh root@<control-plane-ip> cat /etc/rancher/k3s/k3s.yaml > /tmp/prod-k3s.yaml
# Edit /tmp/prod-k3s.yaml: replace the server URL (127.0.0.1) with https://<control-plane-ip>:6443
KUBECONFIG=~/.kube/config:/tmp/prod-k3s.yaml kubectl config view --flatten > /tmp/merged.yaml
mv /tmp/merged.yaml ~/.kube/config
kubectl config rename-context default prod
```

Then register it with ArgoCD **with exactly this name** — the Application
manifests in `argocd/apps/` reference the cluster as `prod`:

```sh
argocd cluster add prod --name prod
```

If you're moving an already-registered cluster to a new provider rather than
registering for the first time, remove the old registration first so there
aren't two clusters sharing the name `prod`:

```sh
argocd cluster list                      # find the old server URL
argocd cluster rm https://<old-ip>:6443
```

### 7. Create the Neon database

Create a Neon project and database (e.g. `open_visual_regression`). Copy the
**pooled** connection string (the host ends in `-pooler`) — it keeps the
web/worker pods from exhausting Neon's direct-connection limit.
`sslmode=require` is already part of the string Neon gives you.

Migrations are the exception: Drizzle's migrator uses prepared statements,
which pgbouncer's transaction pooling breaks. If the migrate Job fails with a
prepared-statement error, re-run step 9 with the **direct** (non-pooler)
connection string instead.

### 8. Create the S3 bucket + IAM user

In AWS: create a bucket (e.g. `ovr`, region `us-east-1` — match whatever you
pick in `values-prod.yaml`'s `storage.bucket`/`storage.region`),
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

### 9. Bootstrap the app secret

Nothing sensitive is committed to this repo. Create the `ovr-secrets` Secret
directly on the prod cluster:

```sh
kubectl config use-context prod
DATABASE_URL=<from step 7> \
AWS_ACCESS_KEY_ID=<from step 8> \
AWS_SECRET_ACCESS_KEY=<from step 8> \
  ./scripts/create-secrets.sh
```

If you're migrating an already-live deployment, reuse the **same**
`BETTER_AUTH_SECRET` and `OVR_GIT_TOKEN_ENCRYPTION_KEY` from the old cluster's
secret instead of letting the script generate fresh ones — rotating the
latter is one-way and invalidates every stored git-integration token, and
rotating either logs out every session. Pull them from the old cluster first
and patch them back in after running the script:

```sh
kubectl --context <old-context> -n ovr get secret ovr-secrets -o jsonpath='{.data.BETTER_AUTH_SECRET}' | base64 -d
kubectl --context <old-context> -n ovr get secret ovr-secrets -o jsonpath='{.data.OVR_GIT_TOKEN_ENCRYPTION_KEY}' | base64 -d

kubectl --context prod -n ovr patch secret ovr-secrets --type merge -p \
  "{\"data\":{\"BETTER_AUTH_SECRET\":\"$(echo -n '<old value>' | base64)\",\"OVR_GIT_TOKEN_ENCRYPTION_KEY\":\"$(echo -n '<old value>' | base64)\"}}"
```

### 10. Apply the root Application

```sh
kubectl config use-context <your-local-argocd-context>
kubectl apply -f argocd/root.yaml
```

ArgoCD takes it from here: cert-manager installs, the ClusterIssuer comes up,
Valkey deploys, then the OVR chart (migration Job, then web/worker). The
worker Deployment's `nodeSelector`/`tolerations` (set in
`values-prod.yaml`) send it to the tainted worker node; web has no
such constraint and schedules on the control-plane node by elimination (it's
the only untainted one).

If you're repointing an existing app-of-apps at a newly migrated cluster
rather than installing fresh, you don't need to re-apply this — swapping the
`prod` cluster registration in step 6 is enough; ArgoCD picks up the change
and reconciles everything onto the new cluster automatically.

### 11. Verify

```sh
argocd app list
kubectl --context prod -n ovr get pods -o wide
```

Confirm `ovr-app-web` lands on the control-plane node and `ovr-app-worker`
lands on the worker node. Once the migration Job completes and both are
Running, visit `https://openvisualregression.com`.

## Picking up new app releases

The deployment installs a released chart, pinned by version in
`argocd/apps/ovr.yaml`. The chart's `appVersion` is the app version it was
published for, and the image tag defaults to that, so the chart version alone
decides what runs — there is no moving tag to drift underneath the cluster,
and no rollout restart needed to pick a build up.

To deploy a new release, bump `targetRevision`:

```yaml
# argocd/apps/ovr.yaml
targetRevision: 0.3.0
```

ArgoCD syncs, the migration Job runs as a pre-upgrade hook, then both
deployments roll. Both run `updateStrategy: RollingUpdate` here, so that's
zero-downtime on nodes with headroom to spare. On tighter nodes, switch one or
both back to `Recreate`.

### The image-updater question

`argocd/apps/image-updater.yaml` still tracks
`ghcr.io/open-visual-regression/{web,worker}:main` and writes a digest into
`web.image.override`/`worker.image.override`. That made sense when the chart
itself tracked `main`. Against a pinned chart the two now disagree: the chart
says run 0.3.0, image-updater says run whatever `main` built ten minutes ago,
and the override wins.

Worth picking one deliberately:

- **Deploy releases.** Delete `argocd/apps/image-updater.yaml` and bump
  `targetRevision` when you want a new version. Reproducible, and what a
  versioned chart is for.
- **Deploy every merge.** Keep image-updater, and accept that the running
  images are ahead of the chart's `appVersion`. Check that it still writes
  back correctly first — Argo CD Image Updater's support for multi-source
  Applications is limited, and this Application is now multi-source.

Neither file is changed here; the choice is still open.

## Repo layout

- `data/` — Valkey, plain manifests, no Helm.
- `values-prod.yaml` — the values overlay for this deployment, including the
  worker's node pinning. The chart it applies to lives in the app repo under
  `charts/ovr`; see that directory's README for chart-level detail.
- `argocd/` — ArgoCD Application manifests (app-of-apps).
- `cluster-issuer.yaml` — cert-manager ClusterIssuer for Let's Encrypt via
  Traefik's http01 solver.
- `scripts/create-secrets.sh` — one-time Secret bootstrap, run by hand.
