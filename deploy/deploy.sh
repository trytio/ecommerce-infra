#!/bin/bash
# deploy.sh — Full deployment from zero
# Usage: ./deploy.sh [apply|destroy|test]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=15"

cd "$TF_DIR"

case "${1:-apply}" in
  apply)
    echo "═══════════════════════════════════════════"
    echo "  Carlos Multi-Region Deployment"
    echo "═══════════════════════════════════════════"

    # 1. Build Carlos binary
    echo ""
    echo "=== Building Carlos binary ==="
    cd ~/zenflow-repos/carlos
    cargo build --release --target x86_64-unknown-linux-gnu 2>&1 | tail -3

    # 2. Upload to S3
    echo ""
    echo "=== Uploading binary to S3 ==="
    aws s3 cp target/x86_64-unknown-linux-gnu/release/carlos s3://carlos-os-artifacts/carlos-x86_64 --region us-east-1

    # 3. Terraform
    cd "$TF_DIR"
    echo ""
    echo "=== Terraform init ==="
    terraform init

    echo ""
    echo "=== Terraform apply ==="
    terraform apply -auto-approve

    # 4. Wait for instances
    echo ""
    echo "=== Waiting for instances to boot (90s) ==="
    sleep 90

    # 5. Get outputs
    US_SERVER=$(terraform output -raw us_server_public_ip)
    AU_SERVER=$(terraform output -raw au_server_public_ip)

    echo ""
    echo "=== Waiting for Carlos servers ==="
    for i in $(seq 1 30); do
      if curl -sf --max-time 3 "http://$US_SERVER:4646/v1/status/health" > /dev/null 2>&1; then
        echo "US server ready!"
        break
      fi
      echo -n "."
      sleep 10
    done

    for i in $(seq 1 30); do
      if curl -sf --max-time 3 "http://$AU_SERVER:4646/v1/status/health" > /dev/null 2>&1; then
        echo "AU server ready!"
        break
      fi
      echo -n "."
      sleep 10
    done

    # 6. Wait for nodes
    echo ""
    echo "=== Waiting for client nodes to register ==="
    sleep 30

    echo ""
    echo "=== Cluster status ==="
    echo "US nodes:"
    curl -sf "http://$US_SERVER:4646/v1/nodes" | python3 -c "
import sys,json;d=json.load(sys.stdin);nodes=d.get('data',d) if isinstance(d,dict) else d
for n in nodes: print(f\"  {n.get('id','')[:8]} status={n.get('status')}\")"
    echo "AU nodes:"
    curl -sf "http://$AU_SERVER:4646/v1/nodes" | python3 -c "
import sys,json;d=json.load(sys.stdin);nodes=d.get('data',d) if isinstance(d,dict) else d
for n in nodes: print(f\"  {n.get('id','')[:8]} status={n.get('status')}\")"

    echo ""
    echo "═══════════════════════════════════════════"
    echo "  Deployment complete!"
    terraform output endpoints
    echo "═══════════════════════════════════════════"
    ;;

  destroy)
    echo "=== Destroying all infrastructure ==="
    terraform destroy -auto-approve
    echo "Done."
    ;;

  test)
    exec "$SCRIPT_DIR/test-all.sh"
    ;;

  *)
    echo "Usage: $0 [apply|destroy|test]"
    exit 1
    ;;
esac
