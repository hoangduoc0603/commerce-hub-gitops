# Bootstrap Argo CD

Runbook dựng Argo CD trên một cụm chưa có Argo CD. Có **hai lệnh thay đổi cụm**, xen giữa là các lệnh chỉ chờ. Sau hai lệnh đó, mọi thay đổi đều đi qua Git: Argo CD tự quản lý chính nó (`apps/lab/argocd.yaml`), và root app `root-lab` quản lý mọi thứ trong `apps/lab/`.

Ticket: G0-03. Phiên bản: Argo CD v3.6.1. Diễn tập ngày 2026-11-14 trên cụm `homelab`.

## Điều kiện

- `kubectl config current-context` là `homelab`, và tài khoản có quyền cluster-admin.
- Cụm đạt ticket G0-02: kubeadm, Calico, MetalLB, local-path. Cài cụm theo `docs/homelab-hyperv.md` trong repo `platform`.
- Pod `argocd-repo-server` ra được `github.com` để đọc repo này (public). Manifest Argo CD đã vendor trong `bootstrap/argocd/upstream/`, nên lệnh 1 không tải gì từ GitHub.
- Node kéo được image `quay.io/argoproj/argocd:v3.6.1` và `public.ecr.aws/docker/library/redis:8.10.1-alpine`. Dex (`ghcr.io`) đã bị patch gỡ, nên không cần.
- Chạy mọi lệnh ở thư mục gốc repo này, trên commit đang có ở `origin/main`.

## Dựng

```bash
# Lệnh 1: cài Argo CD (namespace, CRD, RBAC, workload, argocd-cm)
kubectl apply --server-side -k bootstrap/argocd

# Chờ (không thay đổi gì): CRD phục vụ được, rồi cả 5 workload Argo CD Ready
kubectl wait --for=condition=Established --timeout=120s \
  crd/applications.argoproj.io crd/appprojects.argoproj.io crd/applicationsets.argoproj.io
kubectl -n argocd wait --for=condition=Available --timeout=300s deployment --all
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# Lệnh 2: tạo AppProject và root app. Từ đây Argo CD tự kéo phần còn lại từ Git.
kubectl apply -f apps/lab/projects.yaml -f apps/root-lab.yaml
```

**Vì sao phải có hai lệnh chờ:**
- **Chờ CRD `Established`.** kubectl dò kiểu (discovery) một lần ở đầu mỗi lệnh. Nếu CRD chưa được phục vụ, lệnh 2 báo `no matches for kind "AppProject"`. Cũng vì lý do này mà AppProject không nằm trong `bootstrap/argocd` cùng CRD của nó.
- **Chờ workload Ready.** Nếu root app được tạo lúc repo-server chưa sẵn sàng, lần so sánh đầu tiên thất bại và root nằm ở `Unknown`. Controller chỉ thử lại khi hết `timeout.reconciliation`, mặc định 120 s cộng jitter tới 60 s ([auto sync](https://argo-cd.readthedocs.io/en/release-3.6/user-guide/auto_sync/)). Diễn tập lần đầu không có lệnh chờ này mất 179 s; lần thứ hai có lệnh chờ chỉ mất 50 s.

**Thời gian đo được** (2026-11-14, cụm `homelab`, image đã có sẵn trên node):

| Mốc | Giây kể từ lệnh 1 |
|---|---|
| Lệnh 1 xong (47 object) | 3 |
| CRD `Established` | 4 |
| 5 workload Ready, chạy lệnh 2 | 36 |
| App `argocd` `Synced/Healthy` | 49 |
| `root-lab` `Synced/Healthy`, `services-lab` `ResourcesUpToDate` | 50 |

Trên một node mới phải kéo image lần đầu, thời gian dài hơn. Ở lần cài đầu tiên của ticket này, image chưa có trên node, và phải 56 s sau lệnh 1 cả 5 pod mới Ready.

## Kiểm

```bash
kubectl -n argocd get pods                              # 5 pod Running, 0 restart
kubectl -n argocd get applications,applicationsets      # argocd, root-lab: Synced/Healthy
kubectl diff --server-side --force-conflicts -k bootstrap/argocd   # không in gì = cụm khớp Git
kubectl -n argocd get appproject default -o jsonpath='{.spec}'     # sourceRepos, destinations, clusterResourceWhitelist đều []
```

### Những thứ trông như lỗi nhưng không phải

- **Event `secret "argocd-redis" not found` trên pod repo-server, ngay sau lệnh 1.** Init container của Redis sinh Secret này sau khi repo-server đã khởi động. Pod tự lành, không restart.
- **Cảnh báo `missing the kubectl.kubernetes.io/last-applied-configuration annotation` cho `appprojects/default` ở lệnh 2.** Argo CD tạo project `default` trước, kubectl ghi đè lên nó. Đó chính là bước khóa project này.
- **Cảnh báo `prefer a domain-qualified finalizer name`.** Tên finalizer do Argo CD đặt, không đổi được.

## Đăng nhập lần đầu

Người vận hành tự làm trong terminal của mình. Đừng dán mật khẩu vào chat hay vào log.

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443   # để chạy ở một tab riêng
argocd admin initial-password -n argocd                     # in mật khẩu admin ban đầu
argocd login localhost:8080 --username admin                # nhận chứng chỉ tự ký khi được hỏi
```

- Mỗi lần cài lại, mật khẩu ban đầu **đổi**, và token CLI cũ hết hiệu lực.
- Ticket G0-12 sẽ thay tài khoản `admin` bằng SSO.

## Vận hành

### Nâng Argo CD

1. Đọc trang [upgrade](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/overview/) của **từng** minor nằm giữa bản cũ và bản mới.
2. Thay bản vendor bằng `install.yaml` của tag mới, rồi xem diff:

   ```bash
   curl -fsSL -o bootstrap/argocd/upstream/install.yaml \
     https://raw.githubusercontent.com/argoproj/argo-cd/vX.Y.Z/manifests/install.yaml
   shasum -a 256 bootstrap/argocd/upstream/install.yaml
   kubectl diff --server-side --force-conflicts -k bootstrap/argocd
   ```

3. Cập nhật phiên bản và sha256 trong comment của `kustomization.yaml`, cùng phiên bản trong file này, rồi commit.

App `argocd` tự áp thay đổi đó. Không chạy lệnh tay áp lên cụm. Diff của `upstream/install.yaml` trong commit chính là danh sách những gì bản mới thay đổi.

### Sửa tài nguyên Argo CD

Memory limit nằm trong `resources-patch.yaml`. Khi đổi limit, đổi luôn `GOMEMLIMIT` (khoảng 90% limit) ngay bên cạnh.

### Khi cần Argo CD thấy commit ngay

Dùng `argocd app get <app> --hard-refresh`, hoặc annotate `argocd.argoproj.io/refresh=hard`. Refresh thường dùng bản cache ánh xạ nhánh sang SHA, nên có thể chậm tới vài phút. Ticket G0-24 sẽ thêm webhook Git để bỏ độ trễ này.

### Cứu hộ: một commit làm hỏng chính Argo CD

Ví dụ: patch sai làm controller crash, nên Argo CD không còn tự sửa được. Cách xử lý:
1. Revert commit đó trên `main`.
2. Từ bản Git tốt, áp lại bằng tay:

   ```bash
   kubectl apply --server-side --force-conflicts -k bootstrap/argocd
   ```

Sau bootstrap, các field thuộc field manager `argocd-controller`. Nếu thiếu `--force-conflicts`, kubectl sẽ báo conflict và không áp gì.

Sửa `apps/root-lab.yaml` cũng theo cách này: root không tự quản lý chính nó, nên admin phải chạy lại lệnh 2.

## Gỡ Argo CD

Làm **đúng thứ tự** dưới đây. Object có finalizer chỉ được giải phóng khi controller của nó còn sống. Nếu xóa Argo CD trước, các `Application` và `AppProject` có finalizer, cùng namespace `argocd` và CRD, sẽ kẹt mãi ở `Terminating`.

Thứ tự này chỉ an toàn khi không còn `Application` con nào có finalizer, tức mọi app con đã được gỡ qua Git. Nếu còn, xóa root (bước 1) trước, rồi xóa từng app con và chờ chúng dọn xong resource của mình.

```bash
kubectl -n argocd delete application root-lab                 # 1. root không có finalizer: app con thành mồ côi, không cascade
kubectl -n argocd delete application argocd                   # 2. không có finalizer: Argo CD không tự xóa chính nó
kubectl -n argocd delete applicationset --all                 # 3. ApplicationSet
kubectl -n argocd delete appproject --all --timeout=60s       # 4. controller còn sống nên gỡ được finalizer của platform, commerce
kubectl delete -k bootstrap/argocd                            # 5. namespace, CRD, ClusterRole, ClusterRoleBinding
```

Kiểm sau khi gỡ: không còn namespace `argocd`, không còn CRD `*.argoproj.io`, không còn ClusterRole hay ClusterRoleBinding `argocd-*`, và không namespace nào ở `Terminating`. Khi diễn tập, bước 1–4 mất dưới 1 s, bước 5 mất khoảng 15–35 s.
