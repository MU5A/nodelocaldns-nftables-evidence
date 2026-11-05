# nodelocaldns-nftables-evidence

Measurements for [kubernetes/dns#772](https://github.com/kubernetes/dns/issues/772): does NodeLocal DNSCache in its default mode
(`-setupiptables=true`, node-cache binds the kube-dns ClusterIP on a dummy interface and installs iptables rules) work when
kube-proxy runs in `nftables` mode? Everything runs on a throwaway kind cluster; `run.sh` reproduces the core A/B test.

## Environment (what was actually run, 2026-11-05)
- kind v0.33.0, node image `kindest/node:v1.37.0` (arm64, Docker on macOS), 1 control plane + 1 worker, default CNI (kindnet)
- kube-proxy `mode: nftables` (log: "Using nftables Proxier"); host `iptables` is v1.8.11 (nf_tables)
- NodeLocal DNSCache from the upstream addon manifest (`kubernetes/kubernetes` `cluster/addons/dns/nodelocaldns/nodelocaldns.yaml`),
  image `registry.k8s.io/dns/k8s-dns-node-cache:1.27.1`, default flags (so `-setupiptables=true`)
- CoreDNS: the kind default, 2 replicas. Client: an agnhost pod on the worker. IPv4 only.

## Results
1. **Interception works.** Ten `nslookup` runs from the client pod against the kube-dns ClusterIP (10.96.0.10) were counted by the
   node-cache metrics (`coredns_dns_requests_total`, port 9253): node-local +20, cluster CoreDNS +2 (cache misses).
2. **The NOTRACK rules are what makes it work in this mode.** After flushing the raw table on the worker
   (`iptables -t raw -F`), the same ten runs went node-local +0, cluster CoreDNS +20: kube-proxy's nftables DNAT took the packets to CoreDNS.
   node-cache re-added the 16 raw-table rules by itself about 55 s later and node-local took over again (+20 / +2).
3. **No conntrack entry for the client flows.** `/proc/net/nf_conntrack` on the worker had no entries for `dport=53` to 10.96.0.10;
   the only DNS entries were node-cache's own upstream connections to the `kube-dns-upstream` ClusterIP, which kube-proxy DNATs normally.
4. **Served from cache with CoreDNS down.** After warming the cache and scaling CoreDNS to 0 (pods gone, endpoints empty), the cached
   A record for `kubernetes.default.svc.cluster.local.` was still answered; a never-seen name returned SERVFAIL. (The AAAA lookup that
   `nslookup` also sends returned SERVFAIL because its 5 s denial entry had expired.)
5. **Rules timing.** node-cache sets up the interface at start and the iptables rules from its periodic sync, so on a fresh pod the
   rules were absent right after rollout and present about a minute later (matches `Init()` in `cmd/node-cache/app/cache_app.go`).
6. **Teardown.** Deleting the node-local-dns pod removed all NodeLocal rules (raw 16 to 0, filter 8 to 0). Deleting the DaemonSet also
   removed the dummy interface. Afterwards queries to 10.96.0.10 resolved again through kube-proxy to CoreDNS.
7. **iptables backend.** Inside the node-cache container `iptables` reported `v1.8.9 (nf_tables)`. The image's `iptables-wrapper`
   (copied here as `iptables-wrapper.from-image-1.27.1`) picks `nft` when kubelet's `KUBE-IPTABLES-HINT` or `KUBE-KUBELET-CANARY` chain exists
   in the nft mangle table, else `legacy` if they exist in legacy, else whichever backend has more rules (nft on a tie).

8. **Image 1.26.8 (the version named in the issue)** gave the same A/B result on the nft backend: with rules node-local +20 / CoreDNS +2, raw table flushed +0 / +20, rules back after about 50 s.
9. **iptables-legacy host with an nftables kube-proxy.** `legacy-host.sh` switches the worker's `iptables` alternatives to legacy, removes the
   nft copies of kubelet's canary chains and restarts kubelet so they are recreated in the legacy tables. The wrapper then chose legacy
   (container: `iptables v1.8.9 (legacy)`), node-cache wrote its 16 raw-table rules to the legacy table (none in the nft table), and the A/B
   result was the same for both 1.26.8 and 1.27.1: with rules +20 / +2, raw table flushed +0 / +20, rules restored after about 65 s. No conntrack entries
   for DNS to 10.96.0.10. Deleting the DaemonSet removed the legacy rules (raw and filter 0) and the dummy interface, and queries went back to CoreDNS.
   Note this is one kind node switched to legacy, with kindnet and kube-proxy still writing nft rules next to it; it is not a distro that ships legacy.

## Not tested
The teardown ordering from #690, IPv6/dual-stack, other CNIs, multi-node DNS from other nodes, kube-proxy restarts during a run.
One environment. The 1.27.1 nft-backend with-rules measurement was taken three times (+100/+4 over 20 queries, then +20/+2 twice over 10), the without-rules measurement once; the other combinations once each.
