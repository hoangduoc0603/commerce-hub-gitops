#!/usr/bin/env bash
# Tạo (hoặc cập nhật) client keycloak-config-cli trong realm master cho Job keycloak-config-cli (G0-11).
# Runbook: docs/runbooks/keycloak-admin.md mục "Client keycloak-config-cli".
#
# Vì sao cần bước tay: Job đăng nhập bằng client này, nên client phải có trước lần chạy đầu. Realm master không quản lý
# bằng keycloak-config-cli (lý do trong runbook), nên client được tạo bằng kcadm, một lần mỗi khi dựng lại DB keycloak
# hoặc xoay secret.
#
# Client: confidential, chỉ bật service account (client credentials). Service account nhận MỌI role của client
# commerce-hub-realm trong realm master TRỪ impersonation, tức quản trị đúng realm commerce-hub, không đụng được master.
# Secret lấy từ Secret keycloak-config-cli trong cụm (SealedSecret trong gitops), đi qua stdin vào pod: không hiện ra màn
# hình, không nằm trong tham số lệnh.
#
# Cần: kubectl tới cụm, app keycloak đã sync (có Secret keycloak-config-cli), pod keycloak-0 Running, tài khoản admin của
# realm master (kcadm hỏi mật khẩu).
# Chạy: scripts/bootstrap-keycloak-config-cli.sh <admin realm master>
set -euo pipefail

ADMIN=${1:?Dùng: $0 <admin realm master>}
NS=keycloak
POD=keycloak-0
CFG=/tmp/kcadm-bootstrap.cfg

kubectl -n "$NS" get secret keycloak-config-cli >/dev/null

cleanup() { kubectl -n "$NS" exec "$POD" -- rm -f "$CFG" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "1/2 Đăng nhập kcadm bằng $ADMIN (realm master)"
# -t: kcadm hỏi mật khẩu trên TTY. Token lưu ở $CFG trong pod, xóa khi script kết thúc.
kubectl -n "$NS" exec -it "$POD" -- /opt/keycloak/bin/kcadm.sh config credentials \
  --config "$CFG" --server http://localhost:8080 --realm master --user "$ADMIN"

echo "2/2 Tạo hoặc cập nhật client keycloak-config-cli, scope kc-admin-api, role, kiểm đăng nhập"
# Script trong nháy đơn chạy trong pod; chỉ $CFG được chèn từ đây.
# shellcheck disable=SC2016
kubectl -n "$NS" get secret keycloak-config-cli -o jsonpath='{.data.KEYCLOAK_CLIENTSECRET}' | base64 -d \
| kubectl -n "$NS" exec -i "$POD" -- bash -c '
set -euo pipefail
K=/opt/keycloak/bin/kcadm.sh
C='"$CFG"'
IFS= read -r S || [ -n "$S" ]
[ -n "$S" ] || { echo "Secret rỗng" >&2; exit 1; }

# printf là builtin của bash: secret không xuất hiện trong danh sách tiến trình.
# fullScopeAllowed false: token chỉ mang role đã map ở bước 3 (Keycloak 26.8 cảnh báo "Full scope allowed" là deprecated).
JSON=$(printf "{\"clientId\":\"keycloak-config-cli\",\"name\":\"keycloak-config-cli (Job trong namespace keycloak, G0-11)\",\"enabled\":true,\"protocol\":\"openid-connect\",\"publicClient\":false,\"clientAuthenticatorType\":\"client-secret\",\"secret\":\"%s\",\"serviceAccountsEnabled\":true,\"standardFlowEnabled\":false,\"implicitFlowEnabled\":false,\"directAccessGrantsEnabled\":false,\"frontchannelLogout\":false,\"fullScopeAllowed\":false}" "$S")

# 1. Client
ID=$($K get clients -r master -q clientId=keycloak-config-cli --fields id --format csv --noquotes --config $C)
if [ -z "$ID" ]; then
  printf "%s" "$JSON" | $K create clients -r master -f - --config $C
  ID=$($K get clients -r master -q clientId=keycloak-config-cli --fields id --format csv --noquotes --config $C)
else
  printf "%s" "$JSON" | $K update "clients/$ID" -r master -f - --config $C
  echo "Đã cập nhật client $ID"
fi

# 2. Scope kc-admin-api: từ 26.8.2 admin API từ chối (401) token không có scope này (AdminRoot.java, MigrateTo26_8_2.java;
#    migration chỉ tự gắn cho admin-cli và security-admin-console).
SID=$($K get client-scopes -r master --fields id,name --format csv --noquotes --config $C | grep ",kc-admin-api$" | cut -d, -f1)
[ -n "$SID" ] || { echo "Không thấy client scope kc-admin-api trong realm master" >&2; exit 1; }
$K update "clients/$ID/default-client-scopes/$SID" -r master --config $C

# 3. Role: mọi role của client commerce-hub-realm trừ impersonation, gán cho service account VÀ map vào scope của client.
RC=$($K get clients -r master -q clientId=commerce-hub-realm --fields id --format csv --noquotes --config $C)
ARGS=()
for r in $($K get "clients/$RC/roles" -r master --fields name --format csv --noquotes --config $C); do
  [ "$r" = impersonation ] && continue
  ARGS+=(--rolename "$r")
  printf "[%s]" "$($K get "clients/$RC/roles/$r" -r master --config $C)" \
    | $K create "clients/$ID/scope-mappings/clients/$RC" -r master -f - --config $C
done
$K add-roles -r master --uusername service-account-keycloak-config-cli --cclientid commerce-hub-realm "${ARGS[@]}" --config $C
echo "Role của service account (client commerce-hub-realm):"
$K get-roles -r master --uusername service-account-keycloak-config-cli --cclientid commerce-hub-realm --fields name --format csv --noquotes --config $C | sort | paste -sd " " -

# 4. Kiểm bằng chính client: đọc được commerce-hub; master bị từ chối vì thiếu quyền (403), không phải vì token sai (401).
T=/tmp/kcadm-check.cfg
trap "rm -f $T" EXIT
# KC_CLI_CLIENT_SECRET (kcadm 26.8.2 đọc biến này) thay cho --secret, để secret không nằm trong tham số lệnh.
KC_CLI_CLIENT_SECRET="$S" $K config credentials --config $T --server http://localhost:8080 --realm master --client keycloak-config-cli >/dev/null
R=$($K get realms/commerce-hub --fields realm --format csv --noquotes --config $T)
echo "realms/commerce-hub: $R"
if OUT=$($K get realms/master --fields realm --config $T 2>&1); then
  echo "LỖI: client đọc được realm master" >&2; exit 1
elif [[ "$OUT" == *403* ]]; then
  echo "realms/master: 403 (đúng)"
else
  echo "LỖI không mong đợi khi đọc master: $OUT" >&2; exit 1
fi
'
echo "Xong. Chạy Job: argocd app sync keycloak (hoặc nút Sync trên Argo CD)."
