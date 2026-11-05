#!/usr/bin/env bash
# Turns the kind worker into an iptables-legacy host while kube-proxy keeps running in nftables mode,
# so that the image's iptables-wrapper selects the legacy backend. Run after run.sh created the cluster.
set -euo pipefail
W=nld-nft-worker
docker exec $W update-alternatives --set iptables /usr/sbin/iptables-legacy
docker exec $W update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
# the wrapper prefers nft when kubelet's canary chains exist in the nft mangle table: remove them,
# then let kubelet recreate them, this time in the legacy tables
docker exec $W sh -c 'iptables-nft -t mangle -F KUBE-IPTABLES-HINT; iptables-nft -t mangle -X KUBE-IPTABLES-HINT; iptables-nft -t mangle -F KUBE-KUBELET-CANARY; iptables-nft -t mangle -X KUBE-KUBELET-CANARY; ip6tables-nft -t mangle -X KUBE-IPTABLES-HINT 2>/dev/null; ip6tables-nft -t mangle -X KUBE-KUBELET-CANARY 2>/dev/null; true'
docker exec $W systemctl restart kubelet
sleep 15
docker exec $W sh -c 'iptables-legacy-save | grep -E "^:(KUBE-IPTABLES-HINT|KUBE-KUBELET-CANARY)"'
# then: kubectl -n kube-system delete pod -l k8s-app=node-local-dns, and run: bash ab.sh iptables-legacy-save "iptables-legacy -t raw -F"
