# commerce-hub gitops

Nguồn sự thật cho Argo CD: hệ thống chạy gì, ở môi trường nào, cấu hình thế nào. Repo này không chứa code ứng dụng.

| Thư mục | Dùng cho |
|---|---|
| `apps/` | Argo CD `Application` (app-of-apps) |
| `envs/<môi trường>/<service>/` | Values cho chart, image tag, overlay theo môi trường (ví dụ `envs/local/order/values.yaml`) |

CI của từng service chỉ cập nhật image tag ở đây. Sửa replica hay cấu hình thì commit thẳng vào repo này, không cần build lại service.
