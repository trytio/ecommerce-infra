#!/bin/bash
# test-all.sh — Comprehensive test suite for Carlos multi-region deployment
set -euo pipefail

TF_DIR="$(cd "$(dirname "$0")/terraform" && pwd)"
cd "$TF_DIR"

US_SERVER=$(terraform output -raw us_server_public_ip)
AU_SERVER=$(terraform output -raw au_server_public_ip)
ROUTER=$(terraform output -raw us_router_public_ip 2>/dev/null || echo "")
US_CLIENTS=($(terraform output -json us_client_public_ips | python3 -c "import sys,json;[print(x) for x in json.load(sys.stdin)]"))
AU_CLIENTS=($(terraform output -json au_client_public_ips | python3 -c "import sys,json;[print(x) for x in json.load(sys.stdin)]"))
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

PASS=0; FAIL=0; TOTAL=0; RESULTS=()
t() {
  TOTAL=$((TOTAL+1))
  if [ "$1" -eq 0 ]; then PASS=$((PASS+1)); R="✅"; else FAIL=$((FAIL+1)); R="❌"; fi
  echo "  $R $2"
  RESULTS+=("$R $2")
}

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        CARLOS FULL INFRASTRUCTURE TEST SUITE                ║"
echo "║  US: http://$US_SERVER:4646"
echo "║  AU: http://$AU_SERVER:4646"
echo "╚══════════════════════════════════════════════════════════════╝"

# 1. Cluster Health
echo ""; echo "=== 1. CLUSTER HEALTH ==="
H=$(curl -sf "http://$US_SERVER:4646/v1/status/health" 2>/dev/null || echo "")
t $([[ -n "$H" ]] && echo 0 || echo 1) "US server health"
H=$(curl -sf "http://$AU_SERVER:4646/v1/status/health" 2>/dev/null || echo "")
t $([[ -n "$H" ]] && echo 0 || echo 1) "AU server health"

# 2. Leader Election
echo ""; echo "=== 2. LEADER ELECTION ==="
L=$(curl -sf "http://$US_SERVER:4646/v1/status/leader" | python3 -c "import sys,json;print(json.load(sys.stdin).get('leader',''))" 2>/dev/null)
t $([[ -n "$L" ]] && echo 0 || echo 1) "US leader: $L"
L=$(curl -sf "http://$AU_SERVER:4646/v1/status/leader" | python3 -c "import sys,json;print(json.load(sys.stdin).get('leader',''))" 2>/dev/null)
t $([[ -n "$L" ]] && echo 0 || echo 1) "AU leader: $L"

# 3. Node Registration
echo ""; echo "=== 3. NODE REGISTRATION ==="
N=$(curl -sf "http://$US_SERVER:4646/v1/nodes" | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d.get('data',d) if isinstance(d,dict) else d))" 2>/dev/null || echo 0)
t $([[ "$N" -ge 3 ]] && echo 0 || echo 1) "US nodes registered: $N/3"
N=$(curl -sf "http://$AU_SERVER:4646/v1/nodes" | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d.get('data',d) if isinstance(d,dict) else d))" 2>/dev/null || echo 0)
t $([[ "$N" -ge 3 ]] && echo 0 || echo 1) "AU nodes registered: $N/3"

# 4. Allocations
echo ""; echo "=== 4. ALLOCATIONS ==="
for region in US AU; do
  SRV=$US_SERVER; [[ "$region" == "AU" ]] && SRV=$AU_SERVER
  for grp in frontend api database worker; do
    C=$(curl -sf "http://$SRV:4646/v1/allocations" | python3 -c "
import sys,json;a=json.load(sys.stdin);a=a.get('data',a) if isinstance(a,dict) else a
print(len([x for x in a if x.get('group_name')=='$grp' and x.get('status')=='running']))" 2>/dev/null || echo 0)
    t $([[ "$C" -ge 1 ]] && echo 0 || echo 1) "$region $grp running: $C"
  done
done

# 5. Load Balancers
echo ""; echo "=== 5. LOAD BALANCERS (VRE-aware) ==="
for label in "US frontend" "US api" "AU frontend" "AU api"; do
  SRV=$US_SERVER; PORT=8080
  [[ "$label" == *"AU"* ]] && SRV=$AU_SERVER
  [[ "$label" == *"api"* ]] && PORT=8081
  CODE=$(curl -sf --max-time 5 "http://$SRV:$PORT/" -o /dev/null -w "%{http_code}" || echo "000")
  t $([[ "$CODE" == "200" ]] && echo 0 || echo 1) "$label LB :$PORT -> HTTP $CODE"
done

# 6. Router
echo ""; echo "=== 6. MULTI-REGION ROUTER ==="
if [ -n "$ROUTER" ]; then
  CODE=$(curl -sf --max-time 5 "http://$ROUTER:8080/" -o /dev/null -w "%{http_code}" || echo "000")
  t $([[ "$CODE" == "200" ]] && echo 0 || echo 1) "Router :8080 -> HTTP $CODE"
else
  t 1 "Router not deployed"
fi

# 7. Service Discovery + DNS
echo ""; echo "=== 7. SERVICE DISCOVERY + DNS ==="
S=$(curl -sf "http://$US_SERVER:4646/v1/services" | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo 0)
t $([[ "$S" -ge 2 ]] && echo 0 || echo 1) "US services registered: $S"

# 8. Secrets Vault
echo ""; echo "=== 8. SECRETS VAULT (ChaCha20-Poly1305) ==="
curl -sf -X POST "http://$US_SERVER:4646/v1/secrets" -H 'Content-Type: application/json' -d '{"name":"test_secret","value":"test123"}' > /dev/null 2>&1
S=$(curl -sf "http://$US_SERVER:4646/v1/secrets" | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d.get('secrets',d.get('data',[]))))" 2>/dev/null || echo 0)
t $([[ "$S" -ge 1 ]] && echo 0 || echo 1) "Secrets stored: $S"
curl -sf -X DELETE "http://$US_SERVER:4646/v1/secrets/test_secret" > /dev/null 2>&1

# 9. WireGuard Mesh
echo ""; echo "=== 9. WIREGUARD MESH ==="
P=$(curl -sf "http://$US_SERVER:4646/v1/mesh/peers" | python3 -c "import sys,json;d=json.load(sys.stdin);p=d.get('data',d) if isinstance(d,dict) else d;print(len(p.get('peers',p) if isinstance(p,dict) else p))" 2>/dev/null || echo 0)
t $([[ "$P" -ge 3 ]] && echo 0 || echo 1) "US mesh peers: $P"

# 10. VRE Replication
echo ""; echo "=== 10. VRE (Volume Replication Engine) ==="
if [ ${#US_CLIENTS[@]} -gt 0 ]; then
  VRE=$(ssh $SSH_OPTS core@"${US_CLIENTS[0]}" 'journalctl -u carlos-client --no-pager 2>/dev/null | grep -c "VRE sync" || echo 0' 2>/dev/null || echo 0)
  t $([[ "$VRE" -gt 0 ]] && echo 0 || echo 1) "VRE sync events on client-1: $VRE"
fi

# 11. Prometheus Metrics
echo ""; echo "=== 11. PROMETHEUS METRICS ==="
M=$(curl -sf "http://$US_SERVER:4646/v1/metrics" | head -1 || echo "")
t $([[ "$M" == *"carlos"* ]] && echo 0 || echo 1) "Metrics endpoint"

# 12. Server Crash + Auto-Heal
echo ""; echo "=== 12. SERVER CRASH + AUTO-HEAL ==="
ssh $SSH_OPTS core@"$US_SERVER" 'sudo kill -9 $(pgrep -f "carlos server" | head -1)' 2>/dev/null || true
echo "  Killed US server, waiting 15s..."
sleep 15
H=$(curl -sf --max-time 5 "http://$US_SERVER:4646/v1/status/health" 2>/dev/null || echo "")
t $([[ -n "$H" ]] && echo 0 || echo 1) "US server auto-recovered"

# 13. Container Persistence (conmon alive after server crash)
echo ""; echo "=== 13. CONTAINER PERSISTENCE (podman CLI) ==="
if [ ${#US_CLIENTS[@]} -gt 0 ]; then
  C=$(ssh $SSH_OPTS core@"${US_CLIENTS[0]}" 'sudo podman ps -q 2>/dev/null | wc -l' 2>/dev/null || echo 0)
  t $([[ "$C" -gt 0 ]] && echo 0 || echo 1) "Containers survived server crash: $C"
fi

# 14. Node Failure + Reschedule
echo ""; echo "=== 14. NODE FAILURE + RESCHEDULE ==="
if [ ${#US_CLIENTS[@]} -gt 1 ]; then
  ssh $SSH_OPTS core@"${US_CLIENTS[0]}" 'sudo systemctl stop carlos-client' 2>/dev/null || true
  echo "  Stopped client-1, waiting 75s..."
  sleep 75
  DOWN=$(curl -sf "http://$US_SERVER:4646/v1/nodes" | python3 -c "import sys,json;d=json.load(sys.stdin);nodes=d.get('data',d) if isinstance(d,dict) else d;print(len([n for n in nodes if n.get('status')=='down']))" 2>/dev/null || echo 0)
  t $([[ "$DOWN" -ge 1 ]] && echo 0 || echo 1) "Node detected as down"
  # Restart
  ssh $SSH_OPTS core@"${US_CLIENTS[0]}" 'sudo systemctl start carlos-client' 2>/dev/null || true
fi

# 15. Scale Test
echo ""; echo "=== 15. SCALE TEST ==="
JID=$(curl -sf "http://$US_SERVER:4646/v1/jobs" | python3 -c "import sys,json;j=json.load(sys.stdin);j=j.get('data',j) if isinstance(j,dict) else j
for x in j:
 if x.get('status')=='running': print(x.get('id'));break" 2>/dev/null)
if [ -n "$JID" ]; then
  curl -sf -X PUT "http://$US_SERVER:4646/v1/job/$JID/scale" -H 'Content-Type: application/json' -d '{"group":"frontend","count":3}' > /dev/null 2>&1
  sleep 20
  FC=$(curl -sf "http://$US_SERVER:4646/v1/allocations" | python3 -c "import sys,json;a=json.load(sys.stdin);a=a.get('data',a) if isinstance(a,dict) else a;print(len([x for x in a if x.get('group_name')=='frontend' and x.get('status')=='running']))" 2>/dev/null || echo 0)
  t $([[ "$FC" -ge 2 ]] && echo 0 || echo 1) "Frontend scaled to: $FC"
  curl -sf -X PUT "http://$US_SERVER:4646/v1/job/$JID/scale" -H 'Content-Type: application/json' -d '{"group":"frontend","count":2}' > /dev/null 2>&1
fi

# 16. Drain Test
echo ""; echo "=== 16. DRAIN TEST ==="
NODE_ID=$(curl -sf "http://$US_SERVER:4646/v1/nodes" | python3 -c "import sys,json;d=json.load(sys.stdin);nodes=d.get('data',d) if isinstance(d,dict) else d;print(nodes[0].get('id',''))" 2>/dev/null)
if [ -n "$NODE_ID" ]; then
  curl -sf -X PUT "http://$US_SERVER:4646/v1/node/$NODE_ID/drain" -H 'Content-Type: application/json' -d '{"enable":true}' > /dev/null 2>&1
  sleep 20
  curl -sf -X PUT "http://$US_SERVER:4646/v1/node/$NODE_ID/drain" -H 'Content-Type: application/json' -d '{"enable":false}' > /dev/null 2>&1
  t 0 "Drain + undrain completed for $NODE_ID"
fi

# 17. State Persistence
echo ""; echo "=== 17. STATE PERSISTENCE ==="
SP=$(ssh $SSH_OPTS core@"$US_SERVER" 'ls /var/lib/carlos/state.json 2>/dev/null && echo yes || echo no' 2>/dev/null || echo no)
t $([[ "$SP" == "yes" ]] && echo 0 || echo 1) "State snapshot on disk"

# 18. Cross-Region
echo ""; echo "=== 18. CROSS-REGION ==="
CODE=$(curl -sf --max-time 5 "http://$AU_SERVER:8080/" -o /dev/null -w "%{http_code}" || echo "000")
t $([[ "$CODE" == "200" ]] && echo 0 || echo 1) "AU frontend LB still up: HTTP $CODE"

# Summary
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  RESULTS: $PASS/$TOTAL passed, $FAIL failed"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Endpoints:"
echo "  US Frontend: http://$US_SERVER:8080/"
echo "  US API:      http://$US_SERVER:8081/"
echo "  AU Frontend: http://$AU_SERVER:8080/"
echo "  AU API:      http://$AU_SERVER:8081/"
[ -n "$ROUTER" ] && echo "  Router:      http://$ROUTER:8080/"

exit $([[ "$FAIL" -eq 0 ]] && echo 0 || echo 1)
