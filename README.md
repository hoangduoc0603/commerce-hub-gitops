# commerce-hub gitops

Nguồn sự thật cho Argo CD: hệ thống chạy gì, ở môi trường nào, cấu hình thế nào. Repo này không chứa code ứng dụng.

| Thư mục | Dùng cho |
|---|---|
| `bootstrap/` | Cài Argo CD lên cụm trống bằng hai lệnh; runbook ở [`bootstrap/README.md`](bootstrap/README.md) |
| `apps/` | Argo CD `Application` (app-of-apps) |
| `envs/<môi trường>/<service>/` | Values cho chart, image tag, overlay theo môi trường (ví dụ `envs/local/order/values.yaml`) |
| `infra/<thành phần>/` | Manifest hạ tầng vendor kèm patch Kustomize, dùng chung giữa môi trường (ví dụ CRD SealedSecret có `Prune=false,Delete=false`) |
| `scripts/` | Kiểm Secret dạng rõ (`check-no-plain-secrets.sh`), sao lưu khóa sealing (`backup-sealing-key.sh`) |

CI của từng service chỉ cập nhật image tag ở đây. Sửa replica hay cấu hình thì commit thẳng vào repo này, không cần build lại service.

## Secret

Secret chỉ vào repo dưới dạng `SealedSecret` (Sealed Secrets, scope `strict`). Repo này public: không bao giờ commit `kind: Secret` có `data`/`stringData`; trước khi push chạy `scripts/check-no-plain-secrets.sh`. Seal, sao lưu và khôi phục khóa sealing theo runbook [`docs/runbooks/sealing-key.md`](https://github.com/hoangduoc0603/commerce-hub-docs/blob/main/runbooks/sealing-key.md). Dựng lại cụm đã có SealedSecret thì nạp bản sao lưu khóa **trước** lệnh bootstrap 2 (xem [`bootstrap/README.md`](bootstrap/README.md)).
