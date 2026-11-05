#!/usr/bin/env bash
# Reproduces the measurements in README.md on a throwaway kind cluster (needs docker, kind, kubectl).
set -euo pipefail
cd "$(dirname "$0")"
CL=nld-nft; export KUBECONFIG=$PWD/.kubeconfig
kind create cluster --name $CL --config kind-nft.yaml --image kindest/node:v1.37.0 --kubeconfig "$KUBECONFIG" --wait 180s
kubectl wait --for=condition=Ready node --all --timeout=180s
W=$CL-worker
kubectl run client --image=registry.k8s.io/e2e-test-images/agnhost:2.53 \
  --overrides='{"spec":{"nodeName":"'$W'","tolerations":[{"operator":"Exists"}]}}' --command -- sleep 3600
kubectl wait --for=condition=Ready pod/client --timeout=120s
DNS=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')
sed -e 's/__PILLAR__DNS__DOMAIN__/cluster.local/g' -e 's/__PILLAR__LOCAL__DNS__/169.254.20.10/g' \
    -e "s/__PILLAR__DNS__SERVER__/$DNS/g" nodelocaldns.upstream.yaml | kubectl apply -f -
kubectl -n kube-system rollout status ds/node-local-dns --timeout=180s
# node-cache installs its iptables rules from the periodic sync, not at start: wait for them
for _ in $(seq 1 30); do [ "$(docker exec $W iptables-save -t raw | grep -c NodeLocal)" -ge 16 ] && break; sleep 5; done
nl_req(){ docker exec $W curl -s localhost:9253/metrics | awk '/^coredns_dns_requests_total/{s+=$2} END{print s+0}'; }
cd_req(){ t=0; for ip in $(kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[*].status.podIP}'); do
  v=$(docker exec $W curl -s $ip:9153/metrics | awk '/^coredns_dns_requests_total/{s+=$2} END{print s+0}'); t=$((t+v)); done; echo $t; }
run(){ b1=$(nl_req); b2=$(cd_req)
  for _ in $(seq 1 10); do kubectl exec client -- nslookup -timeout=3 kubernetes.default.svc.cluster.local. $DNS >/dev/null 2>&1; done
  echo "node-local +$(( $(nl_req) - b1 ))  cluster CoreDNS +$(( $(cd_req) - b2 ))"; }
echo "with NOTRACK rules:";    run
docker exec $W iptables -t raw -F
echo "without NOTRACK rules:"; run
echo "kind delete cluster --name $CL   # when done"
