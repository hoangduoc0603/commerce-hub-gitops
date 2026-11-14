#!/usr/bin/env bash
# Kiểm repo gitops không chứa Secret dạng rõ (G0-04, docs/standards/gitops-argocd.md mục "Secret").
#
# Vì sao không chỉ `git grep -l '^kind: Secret$'`:
# - Bắt nhầm: install.yaml vendor của Argo CD có khung `argocd-secret` RỖNG (không data), argocd-server
#   tự điền lúc chạy; không có giá trị nào bị lộ.
# - Bắt sót: `kind: "Secret"`, `kind: Secret` thụt lề trong `kind: List`, hay dòng có comment cuối dòng.
# Script này đọc YAML thật: mọi document `kind: Secret` có `data` hoặc `stringData` khác rỗng là lỗi,
# kể cả item trong `kind: List`. SealedSecret (`kind: SealedSecret`) không bị bắt.
#
# Chạy: scripts/check-no-plain-secrets.sh   (exit 0 = sạch, 1 = có Secret mang giá trị)
# Cần: git, yq v4 (mikefarah).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

found=0
while IFS= read -r -d '' f; do
  # File không đọc được là lỗi, không phải "sạch": im lặng bỏ qua thì một file hỏng sẽ lọt kiểm.
  if ! hits=$(yq ea -N '
    ((select(.kind == "List") | .items[]) // .) |
    select(.kind == "Secret" and (((.data // {}) | length) > 0 or ((.stringData // {}) | length) > 0)) |
    (.metadata.namespace // "-") + "/" + (.metadata.name // "?")
  ' "$f" 2>&1); then
    echo "Không đọc được YAML: $f: $hits"
    found=1
    continue
  fi
  if [[ -n "$hits" ]]; then
    while IFS= read -r h; do echo "Secret dạng rõ: $f: $h"; done <<<"$hits"
    found=1
  fi
done < <(git ls-files -z -- '*.yaml' '*.yml')

if [[ $found -eq 0 ]]; then
  echo "OK: không có Secret mang data/stringData trong $(git ls-files -- '*.yaml' '*.yml' | wc -l | tr -d ' ') file YAML được Git theo dõi."
fi
exit $found
