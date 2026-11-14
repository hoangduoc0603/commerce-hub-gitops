#!/usr/bin/env bash
# Sao lưu mọi khóa sealing của Sealed Secrets ra NGOÀI cụm và ngoài Git (G0-04).
# Runbook: docs/runbooks/sealing-key.md (repo docs). Chạy sau MỖI lần khóa gia hạn (30 ngày) và sau khi cài lại.
#
# File kết quả chứa private key: chỉ chủ máy đọc được (umask 077), không in nội dung ra màn hình.
# Chuyển nó vào password manager rồi xóa bản trên đĩa. Script không chứa khóa nên nằm được trong repo public.
#
# Khác lệnh trong README upstream (`kubectl get secret … -o yaml > main.key`): bỏ các field do API server
# sinh (resourceVersion, uid, creationTimestamp, managedFields). Giữ chúng thì `kubectl apply` lên cụm mới
# hoặc sau khi Secret bị xóa bị từ chối, vì không được đặt resourceVersion khi tạo object mới.
# Không lấy Secret `sealed-secrets-key` kiểu cũ: chỉ có nếu từng cài bản < 0.9 (cụm này cài 0.41.2).
#
# Dùng: scripts/backup-sealing-key.sh [thư-mục-đích]   (mặc định ~/.commerce-hub/sealing-keys)
# Cần: kubectl (context đúng cụm), yq v4, openssl, kubeseal.
set -euo pipefail
umask 077

NS=kube-system
LABEL=sealedsecrets.bitnami.com/sealed-secrets-key
DEST=${1:-"$HOME/.commerce-hub/sealing-keys"}

# Chặn ghi vào một working tree Git: bản sao lưu không bao giờ được nằm cạnh repo.
# Kiểm trên thư mục tổ tiên gần nhất đang tồn tại, TRƯỚC khi tạo gì.
probe=$DEST
while [[ ! -d "$probe" ]]; do probe=$(dirname "$probe"); done
if git -C "$probe" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Từ chối: $DEST nằm trong một repo Git." >&2
  exit 1
fi
mkdir -p "$DEST"
chmod 700 "$DEST"

ctx=$(kubectl config current-context)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$DEST/sealing-key-backup-$ctx-$stamp.yaml"

kubectl get secret -n "$NS" -l "$LABEL" -o yaml \
  | yq 'del(.metadata) | del(.items[].metadata.resourceVersion, .items[].metadata.uid,
        .items[].metadata.creationTimestamp, .items[].metadata.managedFields)' >"$out"

n=$(yq '.items | length' "$out")
if [[ "$n" -lt 1 ]]; then
  echo "Lỗi: không có khóa nào mang nhãn $LABEL trong $NS." >&2
  rm -f "$out"
  exit 1
fi

fp() { openssl x509 -noout -fingerprint -sha256 | cut -d= -f2; }

# Đối chiếu: fingerprint trong file phải trùng trên cụm, và cert đang dùng để seal phải có trong file.
backup_fps=$(for i in $(seq 0 $((n - 1))); do yq ".items[$i].data.\"tls.crt\"" "$out" | base64 -d | fp; done | sort)
cluster_fps=$(kubectl get secret -n "$NS" -l "$LABEL" -o jsonpath='{range .items[*]}{.data.tls\.crt}{"\n"}{end}' \
  | while read -r c; do echo "$c" | base64 -d | fp; done | sort)
active_fp=$(kubeseal --fetch-cert | fp)

if [[ "$backup_fps" != "$cluster_fps" ]]; then
  echo "Lỗi: fingerprint trong bản sao lưu khác trên cụm." >&2
  exit 1
fi
if ! grep -qx "$active_fp" <<<"$backup_fps"; then
  echo "Lỗi: cert đang dùng để seal ($active_fp) không có trong bản sao lưu." >&2
  exit 1
fi

echo "Đã sao lưu $n khóa vào $out"
echo "sha256 file: $(shasum -a 256 "$out" | cut -d' ' -f1)"
echo "Fingerprint (SHA-256) các cert trong bản sao lưu:"
echo "$backup_fps" | sed 's/^/  /'
echo "Cert đang dùng để seal: $active_fp"
echo "Bước tiếp: đưa file vào password manager theo runbook, rồi xóa bản trên đĩa."
