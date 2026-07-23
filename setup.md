# K3s + ArgoCD Homelab Setup Guide

## Context
3-node k3s cluster on Proxmox with Ubuntu 26.04 LTS VMs, running ArgoCD with an ApplicationSet pointing to a GitHub repo.

- **k3s-c1**: `192.168.4.21` (control-plane + etcd)
- **k3s-c2**: `192.168.4.22` (control-plane + etcd)
- **k3s-c3**: `192.168.4.23` (control-plane + etcd)

---

## Lessons Learned (What Went Wrong First Time)

Two separate silent-drop bugs hit cross-node traffic. Both look identical from a kubectl perspective (pods Running, Services Unknown, DNS timeouts, ArgoCD apps stuck) but the causes are unrelated.

1. **kube-router vs k3s built-in network policy controller.** Both manage iptables rules with different packet marks (`0x10000` vs `0x20000`). Cross-node TCP gets silently dropped. Fix: **`disable-network-policy: true` in `/etc/rancher/k3s/config.yaml` BEFORE k3s starts** (Step 4).

2. **Flannel VXLAN TX checksum offload bug.** The kernel hands checksum computation to the NIC, but VXLAN-encapsulated inner UDP/TCP checksums end up zero/wrong and the receiving node drops them. ICMP doesn't use that path, so **ping works cross-node but DNS / HTTP / anything-TCP-or-UDP fails cross-node**. Diagnose by checking `sudo ethtool -k flannel.1 | grep tx-checksum-ip-generic` — if `on`, you have the bug. Fix: disable the offload on every node and make it persistent via systemd (Step 7).

---

## Step 1 — Proxmox VM Setup

Create 3 VMs with:
- **CPU**: 4 cores
- **RAM**: 4096MB minimum (8192MB recommended)
- **Disk**: 32GB+
- **Network**: `virtio, bridge=vmbr0, firewall=0` ← disable Proxmox firewall on NIC

---

## Step 2 — Static IP (on each node)

```bash
# Find your interface name
ip link show

# Edit netplan config
sudo nano /etc/netplan/50-cloud-init.yaml
```

**k3s-c1:**
```yaml
network:
  version: 2
  ethernets:
    ens18:
      dhcp4: no
      addresses:
        - 192.168.4.21/24
      routes:
        - to: default
          via: 192.168.4.1
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8
```

**k3s-c2:** same but `192.168.4.22/24`
**k3s-c3:** same but `192.168.4.23/24`

```bash
sudo netplan apply
```

---

## Step 3 — Prerequisites (on ALL nodes)

```bash
# Disable swap
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Enable required kernel modules
sudo modprobe br_netfilter
echo "br_netfilter" | sudo tee /etc/modules-load.d/br_netfilter.conf

# Required sysctl settings
cat <<EOF | sudo tee /etc/sysctl.d/k3s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system
```

---

## Step 4 — K3s Config (on ALL nodes, BEFORE installing k3s)

> ⚠️ This is critical — must be done before k3s starts to prevent the kube-router/network-policy conflict.

```bash
sudo mkdir -p /etc/rancher/k3s
cat <<EOF | sudo tee /etc/rancher/k3s/config.yaml
disable-network-policy: true
EOF
```

---

## Step 5 — Install K3s on c1 (bootstrap)

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --node-ip=192.168.4.21 \
  --advertise-address=192.168.4.21 \
  --tls-san=192.168.4.21
```

Wait for node to be ready:
```bash
sudo kubectl get nodes
```

Get the join token:
```bash
sudo cat /var/lib/rancher/k3s/server/token
```

---

## Step 6 — Join c2 and c3

**On k3s-c2:**
```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://192.168.4.21:6443 \
  --token <TOKEN_FROM_C1> \
  --node-ip=192.168.4.22 \
  --advertise-address=192.168.4.22
```

**On k3s-c3:**
```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://192.168.4.21:6443 \
  --token <TOKEN_FROM_C1> \
  --node-ip=192.168.4.23 \
  --advertise-address=192.168.4.23
```

Verify all nodes joined:
```bash
sudo kubectl get nodes -o wide
```

---

## Step 7 — Disable Flannel TX checksum offload (on ALL nodes)

> ⚠️ Skip this and you'll spend hours debugging "ApplicationSet generated 0 apps", DNS timeouts, and ArgoCD apps stuck on `Unknown`. See Lesson #2 above.

`flannel.1` only exists once k3s is running, so this step comes after the cluster is up. Run on every node:

```bash
# Immediate fix — applies to the running flannel.1 interface
sudo ethtool -K flannel.1 tx-checksum-ip-generic off

# Verify it stuck (expect: tx-checksum-ip-generic: off)
sudo ethtool -k flannel.1 | grep tx-checksum-ip-generic
```

Make it survive reboots and k3s restarts with a systemd unit:

```bash
sudo tee /etc/systemd/system/flannel-tx-csum-off.service > /dev/null <<'EOF'
[Unit]
Description=Disable TX checksum offload on flannel.1 (k3s VXLAN bug workaround)
After=k3s.service
Wants=k3s.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Wait up to 60s for flannel.1 to appear, then disable the offload.
ExecStart=/bin/sh -c 'for i in $(seq 1 30); do ip link show flannel.1 >/dev/null 2>&1 && /usr/sbin/ethtool -K flannel.1 tx-checksum-ip-generic off && exit 0; sleep 2; done; exit 1'

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now flannel-tx-csum-off.service
sudo systemctl status flannel-tx-csum-off.service --no-pager
```

Smoke test from your laptop — DNS via the Service IP from a pod pinned to a node that does NOT host CoreDNS:

```bash
# Find a node CoreDNS is NOT on
COREDNS_NODE=$(kubectl -n kube-system get pod -l k8s-app=kube-dns -o jsonpath='{.items[0].spec.nodeName}')
OTHER_NODE=$(kubectl get node -o name | grep -v "$COREDNS_NODE" | head -1 | cut -d/ -f2)

kubectl run dns-check --rm -i --restart=Never --image=tutum/dnsutils \
  --overrides='{"spec":{"nodeName":"'"$OTHER_NODE"'"}}' \
  -- dig +short @10.43.0.10 kubernetes.default.svc.cluster.local
# Expect: 10.43.0.1
```

---

## Step 8 — Copy Kubeconfig to Laptop

```bash
# Fix permissions on c1 first
ssh 192.168.4.21 "sudo chmod 644 /etc/rancher/k3s/k3s.yaml"

# Copy to laptop
scp k3s-c1@192.168.4.21:/etc/rancher/k3s/k3s.yaml ~/.kube/config

# Fix server IP
sed -i 's/127.0.0.1/192.168.4.21/g' ~/.kube/config

# Test
kubectl get nodes
```

---

## Step 9 — Install ArgoCD

```bash
kubectl create namespace argocd

# Use server-side apply to avoid the 262144 byte annotation limit
kubectl apply -n argocd \
  --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for all pods to be ready
kubectl wait --for=condition=available --timeout=120s deployment --all -n argocd
kubectl get pods -n argocd
```

---

## Step 10 — Get ArgoCD Admin Password

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## Step 11 — Expose ArgoCD via Traefik

Patch ArgoCD to run in insecure mode (let Traefik handle TLS):
```bash
kubectl patch configmap argocd-cmd-params-cm -n argocd \
  --type merge \
  -p '{"data":{"server.insecure":"true"}}'

kubectl rollout restart deploy/argocd-server -n argocd
```

Create the IngressRoute (using nip.io for local DNS):
```bash
kubectl apply -f - <<EOF
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  entryPoints:
    - web
  routes:
    - match: Host(\`argocd.192.168.4.21.nip.io\`)
      kind: Rule
      services:
        - name: argocd-server
          port: 80
EOF
```

Access ArgoCD at: `http://argocd.192.168.4.21.nip.io`
- Username: `admin`
- Password: from Step 10

---

## Step 12 — Create ApplicationSet

```bash
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: homelab
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/DeWildeDaan/homelab
        revision: HEAD
        directories:
          - path: apps/*
  template:
    metadata:
      name: '{{path.basename}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/DeWildeDaan/homelab
        targetRevision: HEAD
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{path.basename}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          # Server-side apply — required for operators that ship very large CRDs
          # (e.g. CloudNativePG's `clusters.postgresql.cnpg.io` is >256 KB).
          # Client-side apply stores a last-applied-configuration annotation that
          # exceeds Kubernetes' 262144-byte metadata limit and the CRD fails to
          # apply. SSA doesn't write that annotation. Safe for all other apps too.
          - ServerSideApply=true
EOF
```

This will automatically create an ArgoCD Application for every subdirectory inside `apps/` in your repo.

---

## Troubleshooting

### CoreDNS failing with `subnet.env not found`
Flannel hasn't initialized yet. Wait for all nodes to join, then:
```bash
kubectl delete pod -n kube-system -l k8s-app=kube-dns
```

### ApplicationSet generating 0 applications
Your repo must have an `apps/` folder at the root with subdirectories for each app. Each subdirectory becomes its own ArgoCD Application.

### Cross-node TCP timeouts (the original problem)
Caused by kube-router and k3s built-in network policy controller conflicting. Prevented by setting `disable-network-policy: true` in `/etc/rancher/k3s/config.yaml` before starting k3s.

### Cross-node UDP/TCP timeouts but ICMP works (the second problem)

Symptoms: `ping <pod-ip>` works between nodes, but `dig @10.43.0.10 ...` from a pod times out unless the pod is on the same node as CoreDNS. ArgoCD apps stuck `Unknown`, application-controller logs show `lookup argocd-repo-server on 10.43.0.10:53: i/o timeout`.

Diagnose:
```bash
sudo ethtool -k flannel.1 | grep tx-checksum-ip-generic
# tx-checksum-ip-generic: on  ← that's the bug
```

Fix: see Step 7. One-liner per node + persistent systemd unit.

### Stuck k3s `config.yaml` after editing
`disable-network-policy: true` and other settings only apply at install time. If you add the flag to a running cluster, kube-router stays deployed — you have to manually delete its DaemonSet or reinstall k3s. Same caveat for `disable: [servicelb]` — adding it later doesn't remove klipper-lb pods that are already running.