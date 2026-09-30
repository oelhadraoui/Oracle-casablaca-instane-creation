#!/bin/bash
# Retry-launch an Always Free Ampere A1 instance until capacity is available.
# Works in OCI Cloud Shell, on any Linux box with OCI CLI, or in GitHub Actions.

# ---- settings (edit if needed) ----
OCPUS=${OCPUS:-2}
MEM=${MEM:-12}                      # GB
NAME="server-tayservi-2"
SUBNET_NAME="subnet-20260801-1414"
SLEEP=${SLEEP:-90}                  # seconds between attempts
MAX_MINUTES=${MAX_MINUTES:-0}       # 0 = run forever; >0 = stop after N minutes
# -----------------------------------

# SSH public key
cat > ~/tayservi_key.pub <<'KEY'
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC2J4WXrY4KmPtQ5NJf/VYVQY6rexzASN1GcDIbZ/qHj4hc/FYH+TkfmQiZ/8dpMAZsv2mAc1V8ncpTBN8s1bnWlTmRD9txmcxcRwd9+MS75vttEP+wLZIeJ0PGDJcfPtEhlZfoQOPp12NLLgTXpu39SxDV7+kMub2+M94ihcyvBpx6Q7qzF80LS5mesbllcumLAsGPahfcT/wRdTe1Yp6+y6rRYRw1FZfV4Fpj5HFKZHsVrSf22Xh3lm53ZHAuXgDNiFPUPo3c4bqSwivs2PkjSOjXDRHeL2kpDDDrTI5fM/8X+hBoe/7+jeD0uOf5KHIcYnw70LTvo5UMFeagmYf5 ssh-key-2026-03-28
KEY

# Auto-discover IDs
C=${OCI_TENANCY:-$(oci iam availability-domain list --query 'data[0]."compartment-id"' --raw-output)}
AD=$(oci iam availability-domain list --compartment-id "$C" --query 'data[0].name' --raw-output)
SUBNET_ID=$(oci network subnet list --compartment-id "$C" --display-name "$SUBNET_NAME" --query 'data[0].id' --raw-output)
IMAGE_ID=$(oci compute image list --compartment-id "$C" \
  --operating-system "Canonical Ubuntu" --operating-system-version "22.04" \
  --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC \
  --query 'data[0].id' --raw-output)

for v in C AD SUBNET_ID IMAGE_ID; do
  if [ -z "${!v}" ] || [ "${!v}" = "null" ]; then echo "ERROR: could not find $v"; exit 1; fi
  echo "found $v"
done

# Don't create a duplicate if a previous run already succeeded
EXIST=$(oci compute instance list --compartment-id "$C" --display-name "$NAME" \
  --query "length(data[?\"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'])" \
  --raw-output 2>/dev/null)
if [ -n "$EXIST" ] && [ "$EXIST" != "0" ]; then
  echo "Instance '$NAME' already exists - nothing to do."
  exit 0
fi

START=$(date +%s)
n=0
while true; do
  n=$((n+1))
  echo "[$(date '+%H:%M:%S')] attempt $n ..."
  OUT=$(oci compute instance launch \
      --availability-domain "$AD" \
      --compartment-id "$C" \
      --shape VM.Standard.A1.Flex \
      --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM}" \
      --subnet-id "$SUBNET_ID" \
      --image-id "$IMAGE_ID" \
      --assign-public-ip true \
      --ssh-authorized-keys-file ~/tayservi_key.pub \
      --display-name "$NAME" \
      --query 'data.id' --raw-output 2>&1)

  if [ $? -eq 0 ]; then
    ID="$OUT"
    echo "SUCCESS! Instance created."
    oci compute instance get --instance-id "$ID" --wait-for-state RUNNING >/dev/null
    if [ -z "$GITHUB_ACTIONS" ]; then
      IP=$(oci compute instance list-vnics --instance-id "$ID" --query 'data[0]."public-ip"' --raw-output)
      echo "Public IP: $IP"
      echo "Connect:   ssh -i <your-private-key> ubuntu@$IP"
    else
      echo "Check the OCI console for the public IP."
    fi
    exit 0
  fi

  if echo "$OUT" | grep -qiE "capacity|TooManyRequests|InternalError"; then
    if [ "$MAX_MINUTES" -gt 0 ] && [ $(( ($(date +%s) - START) / 60 )) -ge "$MAX_MINUTES" ]; then
      echo "Time limit reached, will try again next run."
      exit 0
    fi
    echo "  no capacity yet, retrying in ${SLEEP}s"
    sleep "$SLEEP"
  else
    echo "Stopped on a different error:"
    echo "$OUT"
    exit 1
  fi
done