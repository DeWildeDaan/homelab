# Homelab Architecture Design Document

**Version:** 0.1  
**Status:** Draft  
**Author:** Daan De Wilde
**Last Updated:** 2026-05-13

---

## Table of Contents

1. [Overview](#overview)
2. [Goals & Principles](#goals--principles)
3. [Physical Infrastructure](#physical-infrastructure)
4. [Virtualization — Proxmox](#virtualization--proxmox)
5. [Kubernetes — k3s](#kubernetes--k3s)
6. [Infrastructure as Code — OpenTofu](#infrastructure-as-code--opentofu)
7. [GitOps — ArgoCD](#gitops--argocd)
8. [Secrets Management](#secrets-management)
9. [Storage — Synology NAS](#storage--synology-nas)
10. [Networking](#networking)
11. [TLS & DNS](#tls--dns)
12. [Repository Structure](#repository-structure)
13. [Architectural Decisions (ADRs)](#architectural-decisions-adrs)
14. [Open Issues & Future Considerations](#open-issues--future-considerations)

---

## Overview

This document describes the architecture of a personal homelab built on three mini PCs running Proxmox, hosting a vanilla Kubernetes cluster (k3s). The design prioritises Infrastructure as Code (IaC), GitOps, simplicity, and security — in particular the safe handling of secrets in a public GitHub repository.

---

## Goals & Principles

| Goal              | Description                                                                                                     |
| ----------------- | --------------------------------------------------------------------------------------------------------------- |
| IaC-first         | All infrastructure is defined in code. Manual steps are minimised and documented when unavoidable.              |
| GitOps            | Cluster state is driven from Git. ArgoCD is the single source of truth for workloads.                           |
| Public repo safe  | No secrets are committed in plaintext. Encryption is applied before commit.                                     |
| Simple to operate | Solo operator. Tooling choices favour readability and low maintenance over sophistication.                      |
| Network isolation | Applications are isolated at both the ingress level (VLAN) and within the cluster (namespace network policies). |
| Future-proof      | Internal-only today, but architecture allows selective public exposure later without a redesign.                |

---

## Physical Infrastructure

Three identical mini PCs, each assigned a static IP on the management VLAN.

| Node      | Hostname      | Role                                 |
| --------- | ------------- | ------------------------------------ |
| Mini PC 1 | `homelab-01`  | Kubernetes control plane + workloads |
| Mini PC 2 | `homelab-02`  | Kubernetes control plane + workloads |
| Mini PC 3 | `homelab-03`  | Kubernetes control plane + workloads |

> **Note — single-role nodes:** Running control plane and workloads on the same nodes is a valid and common homelab pattern. The trade-off is that a resource-heavy workload can starve the control plane. Mitigate this with Kubernetes resource requests/limits and, if needed, taints/tolerations to reserve headroom for system-critical pods.

> **Future:** Dedicated worker nodes can be added as additional Proxmox VMs without changing the control plane topology.

---

## Virtualization — Proxmox

Proxmox VE is installed manually on each mini PC. This is an explicit exception to the IaC principle — Proxmox is the foundation layer and bootstrapping it via automation adds complexity without significant benefit for a three-node homelab.

**What is manual:**

- Proxmox VE installation and initial network configuration
- Cluster formation (`pvecm`)
- Storage configuration (local-lvm for VM disks)

**What is automated (via OpenTofu):**

- Debian 12 VM creation on top of Proxmox (one VM per Proxmox host)
- cloud-init user-data that installs and clusters k3s on first boot
- Post-cluster bootstrap of Calico, MetalLB, sealed-secrets, and ArgoCD

---

## Kubernetes — k3s

k3s is the chosen Kubernetes distribution. It's a CNCF-conformant, single-binary distribution from Rancher — vanilla Kubernetes, just packaged in a way that makes the install/upgrade story trivial. The bundled batteries (Traefik, ServiceLB, Flannel, in-cluster network policy) are all disabled so the stack matches the rest of this design (ingress-nginx, MetalLB, Calico).

### Cluster Topology

- 3 server nodes with embedded etcd (etcd quorum requires odd number — 3 is the minimum for HA)
- All nodes are servers (no taints) — workloads run on every node
- Single cluster, multiple namespaces for workload isolation
- A floating VIP managed by **kube-vip** (static pod, ARP/L2 mode) fronts the API server on port 6443. The kubeconfig points at the VIP, not any individual node.

### Bootstrap Flow

cloud-init does all the work on first boot of each VM:

1. System prep (swap off, `br_netfilter`, sysctls)
2. Drop the kube-vip static pod manifest into `/var/lib/rancher/k3s/server/manifests/` (node 1 only — k3s applies it on first start)
3. Write `/etc/rancher/k3s/config.yaml` with `disable: [traefik, servicelb]`, `flannel-backend: none`, `disable-network-policy: true`, and the right TLS SANs
4. Run the upstream k3s installer
   - **Node 1:** `cluster-init: true` — creates the etcd cluster
   - **Nodes 2 & 3:** wait for `https://<VIP>:6443/healthz` to return OK, then join via `--server https://<VIP>:6443`

The shared k3s join token is generated by OpenTofu (`random_password`) and embedded into each VM's user-data; it lives only in the encrypted state file.

### Day-2 access

Unlike Talos, the nodes are normal Debian 12 boxes with SSH. `kubectl` is available on each node as `k3s kubectl`. Upgrades follow the standard k3s procedure (re-run the installer with a new `INSTALL_K3S_VERSION`).

---

## Infrastructure as Code — OpenTofu

OpenTofu (OSS Terraform fork) manages all VM-level infrastructure.

### Scope

| Resource                                         | Managed by OpenTofu       |
| ------------------------------------------------ | ------------------------- |
| Proxmox VMs (Debian cloud images)                | Yes                       |
| cloud-init user-data + k3s install               | Yes                       |
| Calico, MetalLB, sealed-secrets install          | Yes                       |
| ArgoCD bootstrap (initial install + App of Apps) | Yes                       |
| All subsequent workloads                         | No — handed off to ArgoCD |

### State Management

OpenTofu state is encrypted using OpenTofu's native state encryption (AES-GCM) and **committed to the repository**. This eliminates the need for a remote state backend while keeping the public repo safe — the state file is present in Git but its contents are opaque without the passphrase.

- State encryption is enabled via OpenTofu's built-in encryption feature (AES-GCM with a passphrase)
- The state file (`terraform.tfstate`) is committed to the repo
- The encryption passphrase is stored in a local password manager and passed as an environment variable — never committed
- Git acts as the state backend and provides full history of state changes

> **Note:** You get backup, versioning, and portability for free via Git, with no remote backend to maintain. The one thing to be disciplined about: always `tofu apply` from a clean pull of the repo so you're never working against stale state.

### Secrets & Variables

Sensitive inputs (Proxmox API token, k3s join token, Cloudflare API token) are passed as variables and never committed. The k3s join token is generated by `random_password` inside `tofu/proxmox` and only ever leaves the encrypted state via per-node cloud-init user-data.

Recommended workflow:

```
# .env file (gitignored)
export TF_VAR_.....="..."
export TF_VAR_.....="..."

source .env && tofu apply
```

A `.env.example` file with placeholder values is committed to document required variables.

### Provider

`bpg/proxmox` Terraform provider is used to manage Proxmox VMs via the Proxmox API.

---

## GitOps — ArgoCD

ArgoCD is the GitOps engine. It is bootstrapped by OpenTofu and takes over from that point.

### Bootstrap Flow

A single OpenTofu root at `tofu/` orchestrates two child modules in two stages:

```
Stage 1:  tofu apply -target=module.proxmox -target=terraform_data.kubeconfig
  module.proxmox
    └── Creates Proxmox VMs from a Debian cloud image
    └── Renders & uploads per-node cloud-init user-data (snippets)
    └── cloud-init installs k3s; kube-vip brings up the API VIP
  terraform_data.kubeconfig
    └── Waits for SSH + 3 Ready nodes
    └── scps the kubeconfig from node 1, rewrites server URL to the VIP
    └── Writes it to tofu/.generated/<cluster_name>.kubeconfig

Stage 2:  tofu apply
  module.bootstrap
    └── Installs Calico (CNI), MetalLB, sealed-secrets
    └── Installs ArgoCD via Helm
    └── Applies the root App of Apps manifest
          └── ArgoCD takes over from here
```

The two-stage `-target` apply is required because the Helm/Kubernetes providers in stage 2 need a working kubeconfig at plan time, and the kubeconfig is only produced after stage 1 has run. Subsequent applies are a single `tofu apply`.

### App of Apps Pattern

A single root Application (`root-app`) points to `gitops/apps/` in the repository. Each subdirectory there is an ArgoCD Application pointing to its own Helm chart or manifest directory.

```
gitops/
  apps/
    root-app.yaml         # The App of Apps
    sealed-secrets.yaml
    nfs-provisioner.yaml
    ingress-nginx.yaml
    cert-manager.yaml
    monitoring.yaml
    ...
  manifests/
    <app-specific manifests>
```

### Sync Policy

- Auto-sync enabled for all applications
- Self-heal enabled — drift from Git is corrected automatically
- Pruning enabled — resources removed from Git are removed from the cluster

---

## Secrets Management

### Sealed Secrets (Bitnami)

I chose sealed secrets because it fits the GitOps model cleanly: secrets are encrypted client-side using the cluster's public key and committed as `SealedSecret` custom resources. The in-cluster controller decrypts them into standard Kubernetes `Secret` objects.

**Why Sealed Secrets over SOPS:**

- Native Kubernetes CRD — works naturally with ArgoCD
- No external key management service required
- Encryption key lives in the cluster (backed up separately)
- Simple `kubeseal` CLI workflow

**Workflow:**

```bash
# Encrypt a secret locally before committing
kubectl create secret generic my-secret \
  --from-literal=password=hunter2 \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > my-sealed-secret.yaml

# Commit my-sealed-secret.yaml — safe to push to public repo
```

**Key backup:** The Sealed Secrets controller key pair must be backed up. Export it and store encrypted on the Synology NAS or password manager.

```bash
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-master-key.yaml
# Encrypt and store this file offline — do NOT commit it
```

> **Note:** If you later want multi-cluster or more complex secret workflows, SOPS + age or soemthing like a self hosted Hashicorp Vault is worth revisiting. For now, Sealed Secrets is simpler.

---

## Storage — Synology NAS

### Driver: NFS Subdir External Provisioner

The `nfs-subdir-external-provisioner` Helm chart creates a Kubernetes StorageClass that dynamically provisions PersistentVolumes as subdirectories on an NFS share hosted by the Synology NAS.

**Setup:**

- Synology NAS exposes an NFS share (e.g. `/volume1/k8s`)
- NFS access is restricted to the Kubernetes node IPs at the NAS firewall level
- The provisioner runs as a Deployment in the cluster
- A `StorageClass` named `nfs-nas` is created and set as the default

**Sealed Secret** is used to store any NFS credentials if auth is enabled.

> **Architect's note — no in-cluster distributed storage:** k3s nodes use the local VM disk for the OS and ephemeral pod data only (no Rook/Ceph, no Longhorn). This keeps the cluster simple and stateless. All persistent data lives on the NAS. The trade-off is NAS availability = storage availability. Acceptable for a homelab; mitigate by ensuring the NAS is on a UPS.

---

## Networking

### Physical Network — Ubiquiti / VLANs

| VLAN   | Name       | Purpose                          |
| ------ | ---------- | -------------------------------- |
| VLAN 1 | Management | Network gear                     |
| VLAN 2 | Trusted    | Primary home devices             |
| VLAN 3 | IoT        | IoT devices, restricted outbound |
| VLAN 4 | Homelab    | Proxmox hosts, Talos nodes, NAS  |

Access control between VLANs is enforced at the Ubiquiti gateway (firewall rules).

### Ingress — VLAN-based Access Control

Multiple `ingress-nginx` IngressClass instances (or a single instance with multiple LoadBalancer IPs) are used to expose applications on different VLANs.

**MetalLB + multiple IngressClasses:**

```
MetalLB (Layer 2 mode)
  └── IP pool: 192.168.30.x  → IngressClass: nginx-homelab  (VLAN 30)
  └── IP pool: 192.168.10.x  → IngressClass: nginx-trusted   (VLAN 10)
```

An application's ingress manifest declares which IngressClass to use, effectively restricting access to that VLAN.

```yaml
# Example: app only reachable from VLAN 30
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    ingressClassName: nginx-homelab
spec: ...
```

> **Note:** MetalLB in L2 mode has a single-node failover limitation (ARP is node-local). For a homelab this is acceptable. BGP mode (more complex, requires router support) provides true HA — Ubiquiti equipment does support BGP if you want to pursue this later.

### Internal Network Policy — Namespace Isolation

Calico is the CNI (k3s' bundled Flannel + network-policy controller are disabled). Calico provides:

- Native NetworkPolicy support
- Cluster-wide default-deny policy per namespace
- Path to BGP peering with the Ubiquiti gateway later if MetalLB L2 becomes a bottleneck

**Default posture:** All namespaces get a default-deny ingress NetworkPolicy. Applications explicitly allow only the traffic they need.

```yaml
# Default deny all ingress per namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes:
    - Ingress
```

This is applied to every application namespace via ArgoCD.

---

## TLS & DNS

### cert-manager + Cloudflare DNS-01 Challenge

All TLS certificates are issued by Let's Encrypt using the DNS-01 challenge. This works for internal-only services (no inbound HTTP required).

**Flow:**

1. cert-manager requests a certificate for `*.homelab.yourdomain.com`
2. cert-manager creates a TXT record in Cloudflare via API
3. Let's Encrypt validates the record and issues the certificate
4. Certificate is stored as a Kubernetes Secret and referenced by Ingress resources

**Cloudflare API token** is stored as a SealedSecret in the cluster.

### DNS — Split-Horizon

Internal DNS resolution is handled by a local DNS server (e.g. AdGuard Home or a CoreDNS override) so that `app.homelab.yourdomain.com` resolves to the internal MetalLB IP, not an external address.

Options:

- **AdGuard Home** (recommended — doubles as ad blocker, easy to manage)
- **Pi-hole** with custom DNS entries
- CoreDNS rewrite rules in-cluster

Cloudflare DNS holds the public zone. Internal records are **not** published to Cloudflare (keeping services internal by default). If an app is later made public, a Cloudflare record is added pointing to a reverse proxy or the external IP.

---

## Repository Structure

```
homelab/                          # Public GitHub repository
├── README.md
├── .env.example                  # Documents required env vars (no values)
├── .gitignore                    # Ignores .env, *.tfvars, etc.
│
├── tofu/                         # OpenTofu root — single entry point for all IaC
│   ├── versions.tf               # provider pins + state encryption block
│   ├── providers.tf              # proxmox, kubernetes, helm, kubectl
│   ├── variables.tf              # all top-level vars (forwarded to children)
│   ├── main.tf                   # module "proxmox" + module "bootstrap"
│   ├── kubeconfig.tf             # terraform_data: SSH-fetch kubeconfig from node 1
│   ├── outputs.tf
│   ├── proxmox/                  # child module — VMs + cloud-init that installs k3s
│   │   ├── versions.tf
│   │   ├── variables.tf
│   │   ├── locals.tf
│   │   ├── images.tf
│   │   ├── cloud-init.tf
│   │   ├── vms.tf
│   │   ├── outputs.tf
│   │   └── templates/
│   │       ├── user-data-server-init.yaml.tftpl
│   │       ├── user-data-server-join.yaml.tftpl
│   │       └── kube-vip.yaml.tftpl
│   └── bootstrap/                # child module — Calico + MetalLB + sealed-secrets + ArgoCD
│       ├── versions.tf
│       ├── variables.tf
│       ├── calico.tf
│       ├── metallb.tf
│       ├── sealed-secrets.tf
│       ├── argocd.tf
│       ├── root-app.tf
│       └── outputs.tf
│
└── gitops/                       # ArgoCD managed
    ├── apps/                     # App of Apps definitions
    │   ├── root-app.yaml
    │   ├── ingress-nginx.yaml
    │   ├── cert-manager.yaml
    │   ├── nfs-provisioner.yaml
    │   └── monitoring.yaml
    └── manifests/                # Per-app Helm values & extra manifests
        ├── ingress-nginx/
        ├── cert-manager/
        │   ├── values.yaml
        │   ├── extras/
        │   │   └── clusterissuer-letsencrypt.yaml
        │   └── cloudflare-api-token-sealed-secret.yaml.example
        └── nfs-provisioner/
```

---

## Architectural Decisions (ADRs)

### ADR-001: k3s on Debian 12 for Kubernetes nodes

**Decision:** Use k3s on stock Debian 12 VMs for all Kubernetes nodes. Talos was the original choice but was rejected.  
**Rationale:** Vanilla, well-understood Kubernetes; single-binary install/upgrade; SSH access for ad-hoc debugging; cloud-init is a much simpler bootstrap surface than `talosctl` for a homelab. The bundled k3s extras (Traefik, ServiceLB, Flannel) are explicitly disabled so the rest of the stack matches the design (ingress-nginx, MetalLB, Calico).  
**Trade-off:** Mutable OS — manual patching is now part of the operations story. Larger attack surface than Talos. No declarative machine configs; node configuration drift is possible if someone SSHes in and changes things outside cloud-init.

### ADR-002: Control plane nodes also run workloads

**Decision:** `allowSchedulingOnControlPlanes: true`.  
**Rationale:** 3-node homelab — dedicating nodes to control plane only would leave zero capacity for workloads.  
**Trade-off:** Resource contention possible. Mitigate with resource limits.

### ADR-003: Encrypted state committed to Git

**Decision:** OpenTofu state is encrypted with AES-GCM and committed to the public repository.  
**Rationale:** Git acts as the state backend — providing backup, history, and portability with no remote backend to operate. The encryption passphrase is never committed, so the public repo remains safe.  
**Trade-off:** Discipline required to always work from a current pull. Concurrent applies (not relevant for a solo operator) would cause state conflicts.

### ADR-004: Sealed Secrets over SOPS

**Decision:** Bitnami Sealed Secrets for secret encryption.  
**Rationale:** Native Kubernetes CRD, integrates cleanly with ArgoCD, no external KMS dependency.  
**Trade-off:** Controller key must be backed up manually. Tied to a single cluster.

### ADR-005: NFS-only storage via Synology NAS

**Decision:** No in-cluster distributed storage (no Longhorn, no Rook/Ceph).  
**Rationale:** Simplicity. Distributed storage adds significant operational complexity.  
**Trade-off:** NAS is a single point of failure for persistent storage.

### ADR-006: Calico as CNI

**Decision:** Use Calico (via the tigera-operator Helm chart) as the Kubernetes CNI. k3s' bundled Flannel and the in-cluster network-policy controller are disabled at install time.  
**Rationale:** Standard, well-understood CNI with mature NetworkPolicy support. VXLAN by default — no router configuration required. Has a clear path to BGP peering with the Ubiquiti gateway later if MetalLB L2 mode becomes a bottleneck.  
**Trade-off:** No L7 policy out of the box (would need Calico Enterprise or switching to Cilium later). Slightly heavier than Flannel but the policy support is non-negotiable.

### ADR-007: MetalLB for LoadBalancer services

**Decision:** MetalLB in Layer 2 mode.  
**Rationale:** Required to assign real IPs from VLAN pools to ingress controllers. L2 mode is simple to configure.  
**Trade-off:** L2 mode has single-node ARP limitation. Acceptable for homelab.

### ADR-008: DNS-01 challenge for TLS

**Decision:** cert-manager with Cloudflare DNS-01.  
**Rationale:** Allows Let's Encrypt certificates for internal-only services without exposing HTTP to the internet.  
**Trade-off:** Requires Cloudflare API token in cluster (mitigated by Sealed Secrets).

### ADR-009: kube-vip for API server HA

**Decision:** Run kube-vip as a static pod on each control-plane node (ARP/L2 mode) to provide a single floating VIP for the k3s API server.  
**Rationale:** With 3 server nodes and embedded etcd, the kubeconfig needs a stable address that survives losing any one node. kube-vip is a single tiny static pod, requires no external load balancer or DNS round-robin, and is the documented HA pattern for k3s without a hardware LB.  
**Trade-off:** ARP/L2 means the VIP is owned by one node at a time — failover is fast but not instant, and the VIP must live in the same L2 segment as the nodes. BGP mode would be true active/active but adds router-side configuration not worth it at this scale.
