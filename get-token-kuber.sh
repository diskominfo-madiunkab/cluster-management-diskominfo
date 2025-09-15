#!/usr/bin/env bash
set -euo pipefail
ENDPOINT="${1:-https://103.132.230.3:6443}"   # ganti kalau perlu
OUT="${2:-/root/kubeconfig-ext.yaml}"

# Deteksi distro & path CA
if [ -f /etc/kubernetes/admin.conf ]; then
  SRC=/etc/kubernetes/admin.conf
  CA=/etc/kubernetes/pki/ca.crt
elif [ -f /etc/rancher/rke2/rke2.yaml ]; then
  SRC=/etc/rancher/rke2/rke2.yaml
  CA=/var/lib/rancher/rke2/server/tls/server-ca.crt
elif [ -f /etc/rancher/k3s/k3s.yaml ]; then
  SRC=/etc/rancher/k3s/k3s.yaml
  CA=/var/lib/rancher/k3s/server/tls/server-ca.crt
else
  echo "Gagal deteksi kubeconfig. Isi manual path SRC & CA." >&2; exit 1
fi

cp "$SRC" "$OUT"

# Ambil context & cluster saat ini dari file yang baru
CTX=$(kubectl --kubeconfig="$OUT" config current-context)
CLUSTER=$(kubectl --kubeconfig="$OUT" config view -o jsonpath="{.contexts[?(@.name=='$CTX')].context.cluster}")

# Set endpoint eksternal + embed CA yang benar
kubectl --kubeconfig="$OUT" config set-cluster "$CLUSTER" \
  --server="$ENDPOINT" \
  --certificate-authority="$CA" \
  --embed-certs=true >/dev/null

# Verifikasi cepat dari CP
KUBECONFIG="$OUT" kubectl get --raw=/version >/dev/null && \
echo "✅ Wrote $OUT (endpoint: $ENDPOINT)."
