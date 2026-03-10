#!/bin/bash
# Bootstrap script — downloads Carlos binary from S3 on first boot
set -euo pipefail

BINARY=/opt/carlos/bin/carlos

if [ -f "$BINARY" ] && [ -x "$BINARY" ]; then
  exit 0
fi

echo "Downloading Carlos binary from s3://${s3_bucket}/${s3_key}..."

# Try aws cli first (available on FCOS via podman)
if command -v aws &>/dev/null; then
  aws s3 cp "s3://${s3_bucket}/${s3_key}" "$BINARY"
else
  # Use instance metadata + curl as fallback
  TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
  REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
  CREDS=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/)
  ROLE_CREDS=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/iam/security-credentials/$CREDS")

  ACCESS_KEY=$(echo "$ROLE_CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['AccessKeyId'])")
  SECRET_KEY=$(echo "$ROLE_CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['SecretAccessKey'])")
  SESSION_TOKEN=$(echo "$ROLE_CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['Token'])")

  DATE=$(date -u +%Y%m%dT%H%M%SZ)
  DATE_SHORT=$(date -u +%Y%m%d)
  HOST="${s3_bucket}.s3.$REGION.amazonaws.com"
  URI="/${s3_key}"

  # Simple S3 GET with SigV4 — use python for signing
  python3 -c "
import hashlib, hmac, datetime, urllib.request, sys, os

key = b'$SECRET_KEY'
date = '$DATE_SHORT'
region = '$REGION'
service = 's3'

def sign(key, msg):
    return hmac.new(key, msg.encode('utf-8'), hashlib.sha256).digest()

k_date = sign(('AWS4' + '$SECRET_KEY').encode('utf-8'), date)
k_region = sign(k_date, region)
k_service = sign(k_region, service)
k_signing = sign(k_service, 'aws4_request')

method = 'GET'
uri = '$URI'
host = '$HOST'
amz_date = '$DATE'
payload_hash = hashlib.sha256(b'').hexdigest()

canonical = f'{method}\n{uri}\n\nhost:{host}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\nx-amz-security-token:$SESSION_TOKEN\n\nhost;x-amz-content-sha256;x-amz-date;x-amz-security-token\n{payload_hash}'
scope = f'{date}/{region}/{service}/aws4_request'
string_to_sign = f'AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}'
signature = hmac.new(k_signing, string_to_sign.encode('utf-8'), hashlib.sha256).hexdigest()
auth = f'AWS4-HMAC-SHA256 Credential=$ACCESS_KEY/{scope}, SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token, Signature={signature}'

req = urllib.request.Request(f'https://{host}{uri}')
req.add_header('Host', host)
req.add_header('x-amz-date', amz_date)
req.add_header('x-amz-content-sha256', payload_hash)
req.add_header('x-amz-security-token', '$SESSION_TOKEN')
req.add_header('Authorization', auth)

with urllib.request.urlopen(req) as resp:
    with open('$BINARY', 'wb') as f:
        f.write(resp.read())
print('Downloaded')
"
fi

chmod +x "$BINARY"
echo "Carlos binary ready"
