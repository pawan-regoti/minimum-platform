## local cluster management plane (Cluster API)

Create a **Cluster API (CAPI) management cluster** locally and install CAPI controllers into it.

This uses:
- **kind** for the management cluster
- **clusterctl** to bootstrap Cluster API
- the **Docker infrastructure provider (CAPD)** so the management plane can create “Docker-backed” workload clusters

### prerequisites
- Docker runtime (Docker Desktop, Rancher Desktop or Colima)
- `kubectl`, `kind`, `clusterctl`

Install (macOS):
- `brew install kubectl kind clusterctl`

Install (Linux - Ubuntu/Debian):
- `sudo apt-get update && sudo apt-get install -y curl ca-certificates`
- `curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm -f kubectl`
- `curl -Lo ./kind "https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64" && chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind`
- `curl -L "https://github.com/kubernetes-sigs/cluster-api/releases/latest/download/clusterctl-linux-amd64" -o clusterctl && chmod +x clusterctl && sudo mv clusterctl /usr/local/bin/clusterctl`

If you are on Linux ARM64, replace `amd64` with `arm64` in the URLs above.

### create the management plane
- `chmod +x scripts/create-management-plane-capi.sh scripts/delete-management-plane-capi.sh`
- `./scripts/create-management-plane-capi.sh`

The script also merges the management cluster context into `~/.kube/config`.

The script creates:
- management cluster: value of `clusterManagementPlaneName` in `config.local.json` (if present) else `config.json` (default: `capi-mgmt-1`)
- context: `kind-<clusterManagementPlaneName>` (example: `kind-capi-mgmt-1`)

To change the management cluster name locally, create or edit `config.local.json`:
- `{ "clusterManagementPlaneName": "my-mgmt" }`

### local workload clusters (stand-in for EKS / AKS / GKE)

If you don’t have cloud provider accounts yet, you can still create workload clusters locally (Docker-backed) from the CAPI management plane.

These clusters:
- use **CAPD** (Docker infrastructure provider)
- are named using the same patterns in [kubernetes-providers/config.json](../config.json) (`managedClusters.*.clusterNamePattern`), e.g. `eks-us-east-1-1`, `aks-eastus-1`, `gke-us-east4-1`

Create them:
- `chmod +x scripts/create-local-clusters.sh scripts/delete-local-clusters.sh`
- `./scripts/create-local-clusters.sh`

The script waits for each workload cluster to become Available/Ready (depending on the Cluster API version) and merges their kubeconfigs into `~/.kube/config`.

By default it creates **control-plane-only** clusters (0 workers) to avoid Docker Desktop resource limits (notably file descriptor/inotify exhaustion) during worker joins.
To enable workers:
- `LOCAL_WORKER_MACHINE_COUNT=1 ./scripts/create-local-clusters.sh`

Tuning:
- Set `LOCAL_CLUSTERS_WAIT_EACH_CLUSTER=false` to submit all clusters without waiting (faster, but more likely to hit Docker Desktop resource / file descriptor limits).
- Set `LOCAL_CLUSTER_READY_TIMEOUT_SECONDS=1800` (or similar) to increase the per-cluster readiness wait.

Troubleshooting:
- If you see `DockerMachine ContainerProvisioned=False` with a message like `Container <name> does not exist anymore`, the underlying kind node container was deleted.
	- One common cause is Docker Desktop OOM-killing the node (exit code 137).
	- Check with: `docker events --since 2h --filter container=<container-name> | tail -n 50`
	- Mitigations: increase Docker Desktop memory/CPU, reduce the number of regions (fewer clusters), and keep `LOCAL_WORKER_MACHINE_COUNT=0`.

- If a kind node container repeatedly exits with code `255` and logs include `Failed to create control group inotify object: Too many open files`, Docker Desktop’s Linux VM is likely hitting inotify/file descriptor limits.
	- Mitigations: reduce the number of workload clusters (fewer regions), restart Docker Desktop, and keep `LOCAL_WORKER_MACHINE_COUNT=0`.
	- (Advanced) Temporarily raise inotify limits inside the Docker Desktop VM:
		- `docker run --rm --privileged alpine:3.19 sh -c 'sysctl -w fs.inotify.max_user_instances=8192; sysctl -w fs.inotify.max_user_watches=1048576'`
	- Note: Docker Desktop may reset these limits on restart.

Delete them:
- `./scripts/delete-local-clusters.sh`

You can see the merged contexts with:
- `kubectl config get-contexts`

If you prefer a standalone kubeconfig file per workload cluster:
- `kind get kubeconfig --name <clusterManagementPlaneName> > /tmp/mgmt.kubeconfig`
- `clusterctl get kubeconfig <workload-cluster-name> --kubeconfig /tmp/mgmt.kubeconfig > <workload-cluster-name>.kubeconfig`

Note: the local flow uses a vendored CAPD workload template at `manifests/capd/cluster-template.yaml` to avoid any `clusterctl generate` downloads.

### optional: create a workload cluster manually

If you prefer creating a single workload cluster manually (instead of via the script), use the vendored template:

Example:
- `kind get kubeconfig --name <clusterManagementPlaneName> > /tmp/mgmt.kubeconfig`
- `clusterctl generate cluster wc-1 --from manifests/capd/cluster-template.yaml --kubeconfig /tmp/mgmt.kubeconfig --kubernetes-version v1.29.0 --control-plane-machine-count 1 --worker-machine-count 1 | kubectl --kubeconfig /tmp/mgmt.kubeconfig apply -f -`
- `clusterctl get kubeconfig wc-1 --kubeconfig /tmp/mgmt.kubeconfig > wc-1.kubeconfig`

### delete
- `./scripts/delete-management-plane-capi.sh`

---

## managed clusters (EKS / AKS / GKE)

Create managed Kubernetes clusters in cloud providers from the local CAPI management plane.

If you don’t have cloud accounts, use the **local workload clusters** flow above instead.

### notes
- These scripts submit Cluster API objects to the management cluster (`kind-<clusterManagementPlaneName>`).
- Reconciliation happens asynchronously. Cluster creation can take a while.

### 1) configure flavors + credentials

Set the managed flavors in [kubernetes-providers/config.json](../config.json) or (recommended) override them in `config.local.json`.

You can list available flavors after installing providers:
- `clusterctl generate cluster --list-flavors`

Credentials (your preference): you can store secrets in `config.local.json` under a `secrets` object.

`./scripts/init-managed-providers.sh` runs a preflight check and will fail fast if required variables are missing.

Example structure (do not commit):

```json
{
	"clusterManagementPlaneName": "capi-mgmt-1",
	"managedClusters": {
		"aws": { "flavor": "<your-eks-managed-flavor>" },
		"azure": { "flavor": "<your-aks-managed-flavor>" },
		"gcp": { "flavor": "<your-gke-managed-flavor>" }
	},
	"secrets": {
		"AWS_B64ENCODED_CREDENTIALS": "<base64(~/.aws/credentials)>" ,
		"AZURE_SUBSCRIPTION_ID": "...",
		"AZURE_TENANT_ID": "...",
		"AZURE_CLIENT_ID": "...",
		"AZURE_CLIENT_SECRET": "...",
		"GCP_B64ENCODED_CREDENTIALS": "...",
		"GCP_PROJECT": "..."
	}
}
```

Tip: there is a local template at [kubernetes-providers/config.local.json](../config.local.json) (gitignored) you can fill in.

### 2) create management plane
- `./scripts/create-management-plane-capi.sh`

This also merges the management context into `~/.kube/config`.

### 3) install cloud providers into the management plane
- `./scripts/init-managed-providers.sh`

### 4) create the managed clusters
- `./scripts/create-managed-clusters.sh`

The script waits for each cluster to become Ready and merges their kubeconfigs into `~/.kube/config`.

Watch progress:
- `kubectl --context kind-<clusterManagementPlaneName> get clusters -A`

### 5) delete the managed clusters
- `./scripts/delete-managed-clusters.sh`

---

## private connectivity (full mesh)

To connect AWS/Azure/GCP networks together (US and EU regional groups) using a full-mesh VPN:

- See [kubernetes-providers/networking/README.md](../networking/README.md)
- Apply with: `./scripts/connect-networks-fullmesh.sh`
