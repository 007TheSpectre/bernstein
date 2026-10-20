# Bernstein — Poll application on Kubernetes

Deployment project for the Poll application: everything needed to go from
the source code to a running application on a Kubernetes cluster, with CI.

## Architecture

```
poll --(RPUSH votes)--> redis --(BLPOP votes)--> worker --(UPSERT)--> postgres
                                                        ^                      |
                                                        |                      |
                                               result <-(SELECT, live)--------
```

- **poll** (Python/Flask) — the voting page. Each vote is pushed as JSON onto
  the redis list `votes`.
- **redis** — the queue between poll and worker.
- **worker** (Java) — pops votes from the queue and upserts them into
  PostgreSQL. Several replicas can run in parallel: `BLPOP` makes the queue
  the load balancer.
- **postgres** — the persistent storage for the votes. `schema.sql` is
  applied by a Job at every deploy.
- **result** (Node.js) — reads the tallies from PostgreSQL and pushes them
  to the browser over a websocket (Socket.IO).

Everything runs in the `poll` namespace.

## The platform

The application is deployed on a local platform (see `infra/`):

- a **multi-node** Kubernetes cluster (kind: 1 control-plane + 2 workers,
  `infra/kind-config.yaml`)
- a **private Docker registry** with authentication (port 5000)
- a **TCP forwarder** (port 16443) exposing the cluster API to the CI runner
- the **ingress-nginx** controller (NodePort 30080)

`infra/setup-local.sh` provisions all of it (idempotent). The same steps
apply to any real Kubernetes platform; only the registry address and the
way the cluster is created change.

## Deploy

```sh
export REGISTRY_USER=polluser
export REGISTRY_PASSWORD=...    # login for the private registry
export POSTGRES_PASSWORD=...    # password for the database
export REDIS_PASSWORD=...       # password for redis
./deploy.sh
```

`deploy.sh` builds the three images, pushes them to the registry, creates
the Secrets, applies the manifests in `k8s/`, runs the schema Job and waits
for the rollouts.

The passwords are never stored in the repository: they come from the
environment (or from Gitea Actions secrets in CI) and are turned into the
`postgres-credentials` and `redis-credentials` Secrets at deploy time.
`POSTGRES_USER` and `POSTGRES_DB` default to `poll`.

## Try it

After a deploy, the two web apps are exposed through the ingress
(NodePort 30080, hostname-based routing):

```sh
curl --resolve poll.bernstein.local:30080:<node-ip> http://poll.bernstein.local:30080/
curl --resolve result.bernstein.local:30080:<node-ip> http://result.bernstein.local:30080/
```

`deploy.sh` prints the exact commands with the current node IP.
In a browser, add both hostnames to `/etc/hosts` (or use a DNS name)
pointing at a node IP, then open `http://poll.bernstein.local:30080`.

## CI

Pushes to `main` trigger `.gitea/workflows/deploy.yml` on the self-hosted
runner (stark-tower): it checks out the code and runs the same `deploy.sh`.

The job runs in the `ubuntu-latest` runner image (the runner's docker
strategy), which has everything the deploy needs: git, node, docker, and
network access to the registry. kubectl is installed from the official
releases, and it talks to the cluster through the port-16443 forwarder —
the job's docker network cannot route to the kind node IPs directly.

The credentials are stored as Gitea Actions secrets: `REGISTRY_USER`,
`REGISTRY_PASSWORD`, `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, and
`KUBECONFIG_B64`. The last one is a base64'd kubeconfig for the local kind
cluster (client certificates, `insecure-skip-tls-verify`, and the
`__BRIDGE_IP__` placeholder that the workflow replaces with the docker
bridge gateway at run time). If the cluster is recreated, regenerate it
with:

```sh
kubectl config view --context kind-bernstein --flatten \
  | sed 's|https://127.0.0.1:[0-9]\+|https://__BRIDGE_IP__:16443|;
         s|    server: https://__BRIDGE_IP__:16443|    insecure-skip-tls-verify: true\n    server: https://__BRIDGE_IP__:16443|;
         /certificate-authority-data/d' \
  | base64 -w0
```

## Updates without downtime

Every application runs as a Deployment with `maxUnavailable: 0`: a rolling
update never removes the last ready replica, so the app keeps serving
traffic while the new pods start. To update an application, change the code
(or the image tag) and run `deploy.sh` again — or push to `main` and let
CI do it.

## What's next

- versioned image tags (git sha) instead of `latest`
- autoscaling (HPA) for poll and result
- redis persistence — votes still in the queue are lost when redis restarts
- monitoring (metrics / prometheus)
