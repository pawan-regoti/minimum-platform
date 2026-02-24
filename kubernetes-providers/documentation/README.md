## local cluster management plane (Cluster API)

Create a **Cluster API (CAPI) management cluster** locally and install CAPI controllers into it.

This uses:
- **kind** for the management cluster
- **clusterctl** to bootstrap Cluster API
- the **Docker infrastructure provider (CAPD)** so the management plane can create “Docker-backed” workload clusters

### prerequisites
- Docker runtime (Docker Desktop or Colima)
- `kubectl`, `kind`, `clusterctl`

Install (macOS):
- `brew install kubectl kind clusterctl`

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
