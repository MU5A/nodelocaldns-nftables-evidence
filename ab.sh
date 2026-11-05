# usage: ab.sh <iptables-save-cmd-for-node: iptables-save|iptables-legacy-save> <flush-cmd>
W=nld-nft-worker; DNS=10.96.0.10; SAVE=$1; FLUSH=$2
nl_req(){ docker exec $W curl -s localhost:9253/metrics | awk '/^coredns_dns_requests_total/{s+=$2} END{print s+0}'; }
cd_req(){ t=0; for ip in $(kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[*].status.podIP}'); do v=$(docker exec $W curl -s $ip:9253/metrics 2>/dev/null | awk '/^coredns_dns_requests_total/{s+=$2} END{print s+0}'); [ -z "$v" ] && v=0; t=$((t+v)); done; echo $t; }
cd_req(){ t=0; for ip in $(kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[*].status.podIP}'); do v=$(docker exec $W curl -s $ip:9153/metrics | awk '/^coredns_dns_requests_total/{s+=$2} END{print s+0}'); t=$((t+v)); done; echo $t; }
run(){ b1=$(nl_req); b2=$(cd_req); for i in $(seq 1 10); do kubectl exec client -- nslookup -timeout=3 kubernetes.default.svc.cluster.local. $DNS >/dev/null 2>&1; done; echo "   node-local +$(( $(nl_req) - b1 ))   cluster CoreDNS +$(( $(cd_req) - b2 ))"; }
for i in $(seq 1 30); do n=$(docker exec $W sh -c "$SAVE -t raw 2>/dev/null | grep -c NodeLocal"); [ "$n" -ge 16 ] && break; sleep 5; done; echo "rules present in raw table ($SAVE): $n"
echo "WITH rules:"; run
docker exec $W sh -c "$FLUSH"
echo "WITHOUT rules (raw flushed, remaining: $(docker exec $W sh -c "$SAVE -t raw | grep -c NodeLocal")):"; run
for i in $(seq 1 24); do n=$(docker exec $W sh -c "$SAVE -t raw | grep -c NodeLocal"); [ "$n" -ge 16 ] && break; sleep 5; done; echo "rules restored: $n after ~$((i*5))s"
echo "WITH rules again:"; run
