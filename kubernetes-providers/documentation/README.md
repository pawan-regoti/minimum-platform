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

The script creates:
- management cluster: value of `clusterManagementPlaneName` in `config.local.json` (if present) else `config.json` (default: `capi-mgmt-1`)
- context: `kind-<clusterManagementPlaneName>` (example: `kind-capi-mgmt-1`)

To change the management cluster name locally, create or edit `config.local.json`:
- `{ "clusterManagementPlaneName": "my-mgmt" }`

### optional: create a workload cluster from the management plane

Example (use your management context):
- `clusterctl generate cluster wc-1 --kubernetes-version v1.29.0 --control-plane-machine-count 1 --worker-machine-count 1 | kubectl --context kind-<clusterManagementPlaneName> apply -f -`
- `clusterctl --context kind-<clusterManagementPlaneName> get kubeconfig wc-1 > wc-1.kubeconfig`

### delete
- `./scripts/delete-management-plane-capi.sh`
