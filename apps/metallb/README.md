# metallb

MetalLB in L2 mode. Hands out IPs from `192.168.4.30-192.168.4.50` to any
`Service.type=LoadBalancer` in the cluster. `192.168.4.30` is reserved for
Traefik (see `apps/traefik-config/`); `192.168.4.31` for AdGuard DNS.

## Prerequisite — disable k3s ServiceLB (one-time, on every node)

k3s ships klipper-lb (its built-in LoadBalancer). It will fight MetalLB over
`Service.type=LoadBalancer` and the IP allocation will be unstable. Disable it
on every node before MetalLB syncs:

```bash
# Run on k3s-c1, k3s-c2, k3s-c3:
sudo sh -c 'cat >> /etc/rancher/k3s/config.yaml <<EOF
disable:
  - servicelb
EOF'
sudo systemctl restart k3s
```

Verify klipper is gone:
```bash
kubectl -n kube-system get pod -l app=svclb-traefik   # should be empty
```

## Prerequisite — DHCP exclusion

Reserve `192.168.4.30-192.168.4.50` in the Ubiquiti DHCP server so the router
won't lease those IPs. (Settings → Networks → LAN → DHCP Range.)

## Vendor the upstream chart

```bash
cd apps/metallb
helm dependency update
git add Chart.lock charts/
```

## Verifying

```bash
kubectl -n metallb get pod                 # controller + 3 speakers Running
kubectl -n metallb get ipaddresspool       # homelab pool present
kubectl -n metallb get l2advertisement     # homelab present
```

Smoke test:
```bash
kubectl create deploy nginx --image=nginx
kubectl expose deploy nginx --type=LoadBalancer --port=80
kubectl get svc nginx                      # EXTERNAL-IP in 192.168.4.30-50
curl -sS http://<that-ip>/                 # nginx default page
kubectl delete svc nginx && kubectl delete deploy nginx
```
