#!/usr/bin/env bash
# Kiểm repo gitops không chứa Secret dạng rõ (G0-04, docs/standards/gitops-argocd.md mục "Secret").
#
# Vì sao không chỉ `git grep -l '^kind: Secret$'`:
# - Bắt nhầm: install.yaml vendor của Argo CD có khung `argocd-secret` RỖNG (không data), argocd-server
#   tự điền lúc chạy; không có giá trị nào bị lộ.
# - Bắt sót: `kind: "Secret"`, `kind: Secret` thụt lề trong `kind: List`, hay dòng có comment cuối dòng.
#
# Script đọc YAML thật và báo lỗi khi gặp:
# - document `kind: Secret` có `data` hoặc `stringData` khác rỗng, kể cả item trong `kind: List`;
# - kustomization có `secretGenerator` (literals, envs, files đều đưa giá trị rõ vào repo).
# SealedSecret (`kind: SealedSecret`) không bị bắt.
#
# Phạm vi quét: file YAML trong cây làm việc mà Git theo dõi HOẶC chưa theo dõi nhưng không bị .gitignore,
# tức mọi thứ `git add .` sẽ đưa vào. Quét cả file chưa add để chạy trước commit vẫn có nghĩa.
#
# KHÔNG bắt được (giới hạn đã biết): mật khẩu viết thẳng trong values Helm hay `valuesObject` của Application
# (không có cấu trúc chung để nhận ra). Quy ước: chart chỉ nhận tên Secret có sẵn (`existingSecret`), không nhận
# giá trị (docs/standards/helm-chart.md). Lưới cuối là push protection của GitHub, chỉ bắt định dạng token đã biết.
#
# Chạy: scripts/check-no-plain-secrets.sh   (exit 0 = sạch, 1 = có vi phạm hoặc file không đọc được)
# Cần: git, yq v4 (mikefarah).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

found=0
count=0
while IFS= read -r -d '' f; do
  # File đã xóa trong cây làm việc nhưng còn trong index: không có gì để lộ, bỏ qua.
  [[ -f "$f" ]] || continue
  count=$((count + 1))
  # File không đọc được là lỗi, không phải "sạch": im lặng bỏ qua thì một file hỏng sẽ lọt kiểm.
  # `yq e` xét từng document. Chỉ xét document là map (bỏ document rỗng, scalar, mảng). `kind: Kustomization`
  # là tùy chọn trong kustomization.yaml, nên bắt secretGenerator theo khóa chứ không theo kind.
  # Chuỗi kết quả phải ghép với một ĐƯỜNG DẪN (.metadata…, .secretGenerator…), không với `[ … ]`: yq v4.54
  # vẫn sinh mảng rỗng sau select rỗng, nên `"x" + ([…] | join)` in ra cho mọi file (thấy khi viết script).
  if ! hits=$(yq e -N '
    select(tag == "!!map") |
    ((select(.kind == "List") | .items[] | select(tag == "!!map")) // .) |
    (
      (
        select(.kind == "Secret" and (((.data // {}) | length) > 0 or ((.stringData // {}) | length) > 0)) |
        "Secret dạng rõ " + (.metadata.namespace // "-") + "/" + (.metadata.name // "?")
      ),
      (
        select(has("secretGenerator")) |
        "secretGenerator " + (.secretGenerator | map(.name // "?") | join(","))
      )
    )
  ' "$f" 2>&1); then
    echo "Không đọc được YAML: $f: $hits"
    found=1
    continue
  fi
  if [[ -n "$hits" ]]; then
    while IFS= read -r h; do echo "$h: $f"; done <<<"$hits"
    found=1
  fi
done < <(git ls-files -z --cached --others --exclude-standard -- '*.yaml' '*.yml')

if [[ $found -eq 0 ]]; then
  echo "OK: không có Secret mang data/stringData hay secretGenerator trong $count file YAML."
fi
exit $found
