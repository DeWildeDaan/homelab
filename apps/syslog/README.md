# syslog

syslog-ng receiving the UniFi (UDR7) SIEM stream on `192.168.4.37:514/udp`.
Logs land on NFS as one file per day (`YYYY-MM-DD.log`) and are downloadable at
`https://syslog.home.daandewilde.be` (Pocket ID admins only).

## UDR7 setup

Settings → Control Plane → Integrations → Activity Logging → **SIEM Server**:
server `192.168.4.37`, port `514`, tick the Internet/WAN (and System) categories.

## Extract ISP evidence

```bash
# download the daily files from the web UI (or read the NFS share on the NAS), then:
grep -iE "wan|internet|latency|disconnect|link|down" *.log > isp-evidence.log
```

Retention: a `prune` sidecar deletes daily files older than 183 days (~6 months).
