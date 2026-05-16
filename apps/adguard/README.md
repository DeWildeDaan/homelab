# adguard

AdGuard Home running in-cluster, serving:
- DNS on `192.168.4.31:53` (UDP + TCP) — the LAN's primary resolver
- Web UI on `https://adguard.home.daandewilde.be` (via Traefik) once the
  initial setup wizard is complete

Built on the bjw-s `app-template` chart (the active successor to the archived
k8s-at-home charts).

## Vendor the upstream chart

```bash
cd apps/adguard
helm dependency update
git add Chart.lock charts/
```

## First boot — initial setup wizard

AdGuard ships unconfigured. The first time the pod starts, it serves a setup
wizard on **port 3000**. Hit it directly via the LoadBalancer IP:

```
http://192.168.4.31:3000
```

Wizard:
1. **Admin Web Interface** — listen on `All interfaces`, port `80`
2. **DNS Server** — listen on `All interfaces`, port `53`
3. **Create the admin user**
4. Finish.

After the wizard, the web UI is on port 80; the `adguard-web` ClusterIP
service is already pointed at port 80, so the Traefik route at
`adguard.home.daandewilde.be` starts working immediately.

## DNS configuration (do this in the AdGuard UI after setup)

### Wildcard rewrite — point all internal hostnames at Traefik

**Filters → DNS rewrites → Add rewrite:**

| Domain                       | Answer        |
| ---------------------------- | ------------- |
| `*.home.daandewilde.be`      | `192.168.4.30` |
| `home.daandewilde.be`        | `192.168.4.30` |

### Upstream DNS

**Settings → DNS settings → Upstream DNS servers:**

```
https://1.1.1.1/dns-query
https://8.8.8.8/dns-query
```

Bootstrap DNS: `1.1.1.1`, `8.8.8.8`. Enable parallel queries.

## Point the LAN at AdGuard

Ubiquiti console: **Settings → Networks → LAN → DHCP Service → DNS Server**
→ override → `192.168.4.31`. Renew leases (or wait).

Verify from any LAN device:
```bash
dig @192.168.4.31 adguard.home.daandewilde.be     # -> 192.168.4.30
dig @192.168.4.31 example.com                      # normal answer
```

## Verifying the deployment

```bash
kubectl -n adguard get pod,svc,pvc

# DNS service has the right IP
kubectl -n adguard get svc adguard-dns
# EXTERNAL-IP: 192.168.4.31

# Web UI through Traefik (after wizard + cert)
curl -sS -o /dev/null -w '%{http_code}\n' https://adguard.home.daandewilde.be
# 200
```

## Backup

The setup config lives in the `adguard-config` PVC under
`/opt/adguardhome/conf/AdGuardHome.yaml`. The Synology subdir is
`adguard-adguard-config/`. Snapshot the share regularly.
