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
5. [Kubernetes — Talos OS](#kubernetes--talos-os)
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

This document describes the architecture of a personal homelab built on three mini PCs running Proxmox, hosting a Talos-based Kubernetes cluster. The design prioritises Infrastructure as Code (IaC), GitOps, simplicity, and security — in particular the safe handling of secrets in a public GitHub repository.

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
| Mini PC 1 | `talos-cp-01` | Kubernetes control plane + workloads |
| Mini PC 2 | `talos-cp-02` | Kubernetes control plane + workloads |
| Mini PC 3 | `talos-cp-03` | Kubernetes control plane + workloads |

> **Architect's note — single-role nodes:** Running control plane and workloads on the same nodes is a valid and common homelab pattern. The trade-off is that a resource-heavy workload can starve the control plane. Mitigate this with Kubernetes resource requests/limits and, if needed, taints/tolerations to reserve headroom for system-critical pods.

> **Future:** Dedicated worker nodes can be added as additional Proxmox VMs without changing the control plane topology.

---

## Virtualization — Proxmox

Proxmox VE is installed manually on each mini PC. This is an explicit exception to the IaC principle — Proxmox is the foundation layer and bootstrapping it via automation adds complexity without significant benefit for a three-node homelab.

**What is manual:**

- Proxmox VE installation and initial network configuration
- Cluster formation (`pvecm`)
- Storage configuration (local-lvm for VM disks)

**What is automated (via OpenTofu):**

- Talos OS VM creation and configuration on top of Proxmox

---

## Kubernetes — Talos OS

Talos Linux is the chosen OS for all Kubernetes nodes. It is immutable, API-driven, and has no SSH — all management is done via `talosctl` and declarative machine configs.

### Cluster Topology

- 3 control plane nodes (etcd quorum requires odd number — 3 is the minimum for HA)
- `allowSchedulingOnControlPlanes: true` — workloads run on control plane nodes
- Single cluster, multiple namespaces for workload isolation

### Talos Machine Configs

Generated via `talosctl gen config` and stored in the repository. Secrets (e.g. the cluster CA, bootstrap token) are handled via the secrets management approach described below.

---

## Infrastructure as Code — OpenTofu

OpenTofu (OSS Terraform fork) manages all VM-level infrastructure.

### Scope

| Resource                                         | Managed by OpenTofu       |
| ------------------------------------------------ | ------------------------- |
| Proxmox VMs (Talos nodes)                        | Yes                       |
| Talos machine configuration apply                | Yes                       |
| ArgoCD bootstrap (initial install + App of Apps) | Yes                       |
| All subsequent workloads                         | No — handed off to ArgoCD |

### State Management

OpenTofu state is encrypted using OpenTofu's native state encryption (AES-GCM) and **committed to the repository**. This eliminates the need for a remote state backend while keeping the public repo safe — the state file is present in Git but its contents are opaque without the passphrase.

- State encryption is enabled via OpenTofu's built-in encryption feature (AES-GCM with a passphrase)
- The state file (`terraform.tfstate`) is committed to the repo
- The encryption passphrase is stored in a local password manager and passed as an environment variable — never committed
- Git acts as the state backend and provides full history of state changes

> **Architect's note:** This is an elegant approach for a public solo homelab repo — you get backup, versioning, and portability for free via Git, with no remote backend to maintain. The one thing to be disciplined about: always `tofu apply` from a clean pull of the repo so you're never working against stale state.

### Secrets & Variables

Sensitive inputs (Proxmox API token, Talos secrets, Cloudflare API token) are passed as variables and never committed.

Recommended workflow:

```
# .env file (gitignored)
export TF_VAR_proxmox_api_token="..."
export TF_VAR_cloudflare_api_token="..."

source .env && tofu apply
```

A `.env.example` file with placeholder values is committed to document required variables.

### Provider

`bpg/proxmox` Terraform provider is used to manage Proxmox VMs via the Proxmox API.

---

## GitOps — ArgoCD

ArgoCD is the GitOps engine. It is bootstrapped by OpenTofu and takes over from that point.

### Bootstrap Flow

```
OpenTofu
  └── Creates Proxmox VMs
  └── Applies Talos machine configs
  └── Bootstraps Kubernetes cluster
  └── Installs ArgoCD (via Helm or manifests)
  └── Applies root App of Apps manifest
        └── ArgoCD takes over from here
```

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

### Recommendation: Sealed Secrets (Bitnami)

Sealed Secrets is the recommended approach. It fits the GitOps model cleanly: secrets are encrypted client-side using the cluster's public key and committed as `SealedSecret` custom resources. The in-cluster controller decrypts them into standard Kubernetes `Secret` objects.

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

> **Architect's note:** If you later want multi-cluster or more complex secret workflows, SOPS + age is worth revisiting. For a single-cluster homelab, Sealed Secrets is simpler.

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

> **Architect's note — no Talos disk storage:** Talos nodes use ephemeral local storage only (no Rook/Ceph, no Longhorn). This keeps the cluster simple and stateless. All persistent data lives on the NAS. The trade-off is NAS availability = storage availability. Acceptable for a homelab; mitigate by ensuring the NAS is on a UPS.

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

**Recommended approach — MetalLB + multiple IngressClasses:**

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

> **Architect's note:** MetalLB in L2 mode has a single-node failover limitation (ARP is node-local). For a homelab this is acceptable. BGP mode (more complex, requires router support) provides true HA — Ubiquiti equipment does support BGP if you want to pursue this later.

### Internal Network Policy — Namespace Isolation

Cilium is recommended as the CNI for Talos. It provides:

- Native NetworkPolicy support
- Cluster-wide default-deny policy per namespace
- Rich L7 policy if needed later

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
├── .gitignore                    # Ignores .env, *.tfstate, *.tfstate.backup
│
├── tofu/                         # OpenTofu (IaC)
│   ├── proxmox/                  # VM definitions
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── talos-nodes.tf
│   ├── talos/                    # Talos machine config generation & apply
│   │   ├── main.tf
│   │   └── machine-configs/
│   └── bootstrap/                # ArgoCD install + root App of Apps
│       └── main.tf
│
├── gitops/                       # ArgoCD managed
│   ├── apps/                     # App of Apps definitions
│   │   ├── root-app.yaml
│   │   ├── sealed-secrets.yaml
│   │   ├── cert-manager.yaml
│   │   ├── ingress-nginx.yaml
│   │   ├── metallb.yaml
│   │   ├── nfs-provisioner.yaml
│   │   └── monitoring.yaml
│   └── manifests/                # Per-app manifests & Helm values
│       ├── cert-manager/
│       ├── ingress-nginx/
│       ├── metallb/
│       └── <app>/
│           ├── deployment.yaml
│           ├── ingress.yaml
│           └── sealed-secret.yaml   # Safe to commit
│
└── docs/
    └── architecture.md           # This document
```

---

## Architectural Decisions (ADRs)

### ADR-001: Talos OS over Ubuntu/Debian for Kubernetes nodes

**Decision:** Use Talos Linux for all Kubernetes nodes.  
**Rationale:** Immutable, minimal attack surface, API-driven (no SSH), purpose-built for Kubernetes. Aligns with IaC goals.  
**Trade-off:** Steeper initial learning curve; no shell access for ad-hoc debugging.

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

### ADR-006: Cilium as CNI

**Decision:** Use Cilium as the Kubernetes CNI.  
**Rationale:** Talos-native support, eBPF-based performance, strong NetworkPolicy support, future L7 policy capability.  
**Trade-off:** More complex than flannel/calico for basic use cases.

### ADR-007: MetalLB for LoadBalancer services

**Decision:** MetalLB in Layer 2 mode.  
**Rationale:** Required to assign real IPs from VLAN pools to ingress controllers. L2 mode is simple to configure.  
**Trade-off:** L2 mode has single-node ARP limitation. Acceptable for homelab.

### ADR-008: DNS-01 challenge for TLS

**Decision:** cert-manager with Cloudflare DNS-01.  
**Rationale:** Allows Let's Encrypt certificates for internal-only services without exposing HTTP to the internet.  
**Trade-off:** Requires Cloudflare API token in cluster (mitigated by Sealed Secrets).
