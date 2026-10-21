# Deployment decisions

Why we built the deployment the way we did, and answers to the
questions that usually come up.

## Why a local cluster (kind) instead of the cloud

The subject recommends a Kubernetes-as-a-Service platform, but the
grading is about the *deployment process*, not about where it runs.
We chose a local multi-node cluster (kind) for three reasons:

- **cost**: a cloud cluster costs money every day it exists; a local
  one costs nothing and can be recreated from scratch in minutes,
  which is exactly what the "fresh cluster" evaluation needs;
- **reproducibility**: `infra/setup-local.sh` creates the same cluster
  on any machine with Docker, so the evaluator gets the exact same
  platform we developed on;
- **full control**: no quotas, no shared runners, no credit limits.

kind runs real Kubernetes binaries (same kubelet, API server and
CNI behaviour as a real cluster), so what we learn on it transfers.
The only things that would change on a cloud platform are how the
cluster is created (a CLI call instead of `kind create cluster`) and
the registry address — `deploy.sh` takes the registry as an
environment variable precisely for that.

## The private registry

`registry:2` with htpasswd authentication on port 5000, mirroring how
a real private registry (ACR/ECR/GAR) would be used:

- the images are never public — only the cluster (with its pull
  secret) can fetch them;
- the kind nodes reach the host's registry through a containerd
  mirror (`hosts.toml` pointing `localhost:5000` at the docker bridge
  gateway — inside a node, `localhost` is the node itself, not the
  host). Two gotchas we hit: the node's containerd config needs
  `config_path = /etc/containerd/certs.d` or the mirror file is
  ignored, and without an `imagePullSecrets` entry the pull fails
  with "no basic auth credentials".

## Ingress: host-based, not path-based

The result app uses Socket.IO, which must live at `/socket.io` at the
*root of its own hostname*. Splitting two apps on the same host by
path would force the websocket into a subpath and break it. So we use
two hostnames (`poll.bernstein.local`, `result.bernstein.local`) on
the same ingress — the same split you would do with two DNS records
in front of a cloud load balancer.

## The queue, and why the worker is not CPU-scaled

Redis is a queue between poll and the workers, not a cache. This
decouples the write side (votes) from the read side (database): a slow
database does not make the voting page slow, it only grows the queue.
`BLPOP` is blocking, so any number of worker replicas can share the
queue — the queue *is* the load balancer, no extra routing needed.

Because workers spend their time *waiting* on the queue, their CPU
stays near zero even under heavy voting load. A CPU-based
HorizontalPodAutoscaler would therefore never scale them up. We put
HPAs on `poll` and `result` (the two frontends where CPU tracks
traffic), and scale the workers by hand (`kubectl scale`); queue-depth
autoscaling (KEDA) is the natural next step.

## Persistence

- **PostgreSQL** is a StatefulSet with a PVC: the votes must survive
  restarts, and a StatefulSet gives it a stable identity.
- **Redis** also has a PVC (AOF): the queue is data too. Without
  persistence, a redis restart would drop every vote that was still
  waiting to be consumed. With AOF, the pending votes are replayed on
  startup and the workers pick them back up.
- The **schema** is applied by a one-shot Job on every deploy. The SQL
  is idempotent (`CREATE TABLE IF NOT EXISTS`), so re-running it is
  safe. At this project's scale a migration tool would be
  over-engineering.

## Zero-downtime updates

Every Deployment uses `RollingUpdate` with `maxSurge: 1,
maxUnavailable: 0`: a new pod must be ready before an old one is
terminated, so there is always at least the original number of ready
replicas serving. Readiness gates the traffic (the service only points
at ready pods), liveness restarts what is broken. Combined with
git-sha image tags, a bad release is rolled back with `git revert` +
push and the pipeline ships the previous image again.

## Resources

Every container has requests (scheduling) and limits (protection):

| container  | request cpu/mem | limit cpu/mem |
|------------|-----------------|---------------|
| poll       | 50m / 128Mi     | 250m / 256Mi  |
| worker     | 100m / 256Mi    | 500m / 512Mi  |
| result     | 50m / 128Mi     | 250m / 256Mi  |
| redis      | 64m / 128Mi     | 250m / 256Mi  |
| postgres   | 100m / 256Mi    | 500m / 512Mi  |

The Java worker gets the most because a JVM needs real memory; the
limits keep one misbehaving container from starving the others on the
small nodes. (The subject's example question — "how would we limit
the processing power of Redis?" — is exactly `limits.cpu` on the
redis container, here set to 250m.)

## The CI pipeline

- Gitea Actions on our self-hosted runner. The job runs in the
  `ubuntu-latest` runner *image* (the runner's docker strategy)
  because the checkout action needs Node.js, which the runner's host
  container does not have.
- The docker CLI in the job talks to the host daemon through the
  mounted socket, so the build/push happen on the host: the registry
  is addressed as `localhost:5000` (docker treats localhost as an
  insecure registry), while the kind nodes use their mirror.
- kubectl is installed from the official release in the job itself.
  It talks to the cluster through a small socat forwarder
  (port 16443) because the job's docker network cannot route to the
  kind node IPs; the kubeconfig is a secret with the host IP
  substituted at run time.
- One push to `main` = build + push + redeploy of the whole
  application. The same `deploy.sh` is used locally and by CI, so
  there is one deployment path, not two.

## Questions we expect to be asked

**What happens if we `kubectl drain` a worker node?**
The pods on it are evicted and rescheduled on the remaining nodes
(the control-plane is not schedulable). With two workers, everything
fits on one. The services keep resolving, so the apps keep working —
there is a brief window while the pods restart, but `maxUnavailable:
0` means the *other* replicas keep serving. The exception is
PostgreSQL: its PVC is `ReadWriteOnce` on kind (backed by a hostPath
per node). If the pod lands on a different node than the one that
holds the data, the volume is not there anymore. On a real cluster
you would use a proper storage class (cloud disk / NFS) so the volume
follows the pod; here we accept the tradeoff and note it.

**What happens if the redis pod dies?**
It is restarted; the AOF log replays the votes that were still queued,
and the workers consume them normally. While it is down, the poll app
reports not-ready (its readiness probe pings redis) so the service
stops sending it traffic, and a vote submitted in that window gets a
retry-able error instead of being silently lost.

**What happens if a worker dies?**
Nothing user-visible: the other worker(s) keep consuming the queue,
and nothing is lost because the queue is the source of truth until a
vote is written to PostgreSQL.

**How would we limit the processing power of Redis?**
`resources.limits.cpu` (here 250m) — the CFS quota throttles the
container; `requests` (64m) only influences scheduling. Memory works
the same way, except hitting the memory limit leads to an OOM kill
and a restart.

**How would we scale the application?**
The frontends scale automatically (HPA, 2–5 replicas). Workers scale
with `kubectl scale deploy/worker -n poll --replicas=N` — any number
works because BLPOP distributes the queue. Redis and PostgreSQL are
deliberately single-replica at this scale: a single-writer queue and a
single-writer database avoid the complexity of sharding/replication
that the application does not need.

**How do we roll back a bad deployment?**
`git revert` the commit and push; CI rebuilds and redeploys the
previous image (tags are git shas, so the old image is still in the
registry).

**Why NodePort for the ingress and not a LoadBalancer?**
There is no cloud load balancer on a local cluster; NodePort is what
kind gives us, and the same Ingress resource would be served by a real
load balancer (or cloud LB annotation) without changing the app.
