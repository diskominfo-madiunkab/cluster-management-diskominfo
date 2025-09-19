# Cluster Management - Rancher CI/CD

Pipeline ini men-deploy Rancher ke cluster Kubernetes menggunakan GitHub Actions. Alur jaringan mengikuti pola **Cloudflare DNS → Nginx Proxy Manager (NPM) → NodePort Service → Pod Rancher** sehingga SSL dikelola di NPM dan seluruh domain publik cukup menggunakan wildcard `*.madiunkab.go.id` di Cloudflare.

## Ringkasan Fitur
- Workflow GitHub Actions profesional dengan validasi secret, pengecekan NodePort, dan pembersihan otomatis.
- Deployment menggunakan Helm chart resmi Rancher dengan opsi replikasi dan NodePort yang dapat diatur saat `workflow_dispatch`.
- Health-check otomatis memastikan Rancher siap digunakan dan mencetak IP node serta NodePort untuk konfigurasi NPM.

## Arsitektur
1. **Cloudflare**: mengarahkan wildcard domain ke IP publik server Nginx Proxy Manager.
2. **Nginx Proxy Manager**: melakukan terminasi SSL dan meneruskan trafik HTTPS ke alamat `http://<Node-IP>:<NodePort>`.
3. **Kubernetes NodePort Service** (`rancher-nodeport`): mengekspos Deployment Rancher di dalam namespace `cattle-system`.
4. **Deployment Rancher**: dijalankan oleh Helm chart `rancher-latest/rancher` dengan `ingress.enabled=false` dan TLS eksternal.

## Prasyarat
### Infrastruktur Kubernetes
- Kubernetes cluster versi 1.23 atau lebih baru dengan akses API dari internet (GitHub Actions runner harus bisa menjangkau endpoint `https://<cluster-api>`).
- StorageClass default telah tersedia sehingga Rancher dapat membuat PersistentVolumeClaim.
- Akses `kubectl` lokal untuk membuat service account khusus GitHub Actions.

### DNS & SSL
- Zona DNS Cloudflare dengan record wildcard `*.madiunkab.go.id` mengarah ke IP publik NPM.
- Nginx Proxy Manager terpasang pada server yang dapat menjangkau node Kubernetes melalui jaringan privat/VPN.
- Di NPM buat proxy host baru: hostname Rancher (misal `rancher.madiunkab.go.id`), SSL certificate (Let's Encrypt/Cloudflare), dan forward target ke `http://<Node-IP>:<NodePort>`.

### GitHub Secrets
Simpan dua secret berikut pada repository GitHub:
- `KUBECONFIG_B64`: isi dengan kubeconfig yang sudah di-*base64* (tanpa newline). File ini digunakan GitHub Actions untuk terhubung ke cluster.
- `RANCHER_HOSTNAME`: domain publik Rancher yang sudah diarahkan di NPM, contoh `rancher.madiunkab.go.id`.

#### Membuat Service Account dan kubeconfig untuk GitHub Actions
Jalankan perintah berikut dari mesin yang memiliki akses `kubectl` ke cluster. Ganti nilai variabel sesuai kebutuhan.

```bash
export KUBE_CONTEXT="your-context-name"
export SA_NAMESPACE="kube-system"
export SA_NAME="github-rancher-deployer"

# Gunakan context yang tepat
kubectl config use-context "$KUBE_CONTEXT"

# Buat service account dan beri hak cluster-admin
kubectl create serviceaccount "$SA_NAME" -n "$SA_NAMESPACE"
kubectl create clusterrolebinding "${SA_NAME}-cluster-admin" \
  --clusterrole=cluster-admin \
  --serviceaccount="${SA_NAMESPACE}:${SA_NAME}"

# Ambil informasi cluster dan sertifikat dari kubeconfig lokal
CLUSTER_NAME=$(kubectl config view -o jsonpath='{.current-context}')
CLUSTER_SERVER=$(kubectl config view -o jsonpath='{.clusters[?(@.name=="'$CLUSTER_NAME'")].cluster.server}')
CLUSTER_CA=$(kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="'$CLUSTER_NAME'")].cluster.certificate-authority-data}')

# Generate token sementara untuk service account (Kubernetes >=1.24)
SA_TOKEN=$(kubectl create token "$SA_NAME" -n "$SA_NAMESPACE")

cat <<'KCFG' > kubeconfig-github
apiVersion: v1
kind: Config
clusters:
- name: rancher-cluster
  cluster:
    server: $CLUSTER_SERVER
    certificate-authority-data: $CLUSTER_CA
contexts:
- name: rancher-deployer
  context:
    cluster: rancher-cluster
    user: rancher-deployer
current-context: rancher-deployer
users:
- name: rancher-deployer
  user:
    token: $SA_TOKEN
KCFG

# Konversi ke base64 tanpa newline lalu simpan ke secrets GitHub
base64 -w0 kubeconfig-github > kubeconfig-github.b64
```

> Untuk macOS gunakan `base64 -b0`. Salin isi `kubeconfig-github.b64` ke secret `KUBECONFIG_B64`, lalu hapus file sensitif tersebut dari disk lokal (`rm kubeconfig-github kubeconfig-github.b64`). Token service account memiliki masa berlaku default 1 jam; gunakan `kubectl create token --duration=8760h` bila cluster mendukung token jangka panjang.

## Cara Kerja Workflow `rancher.yaml`
1. **Checkout kode** – mengambil repo agar chart values dan manifest terbaru tersedia.
2. **Validasi secret** – memastikan `KUBECONFIG_B64` & `RANCHER_HOSTNAME` ada sebelum proses berjalan.
3. **Instal kubectl & helm** – menggunakan versi stabil (kubectl 1.29.6 dan helm 3.15.2).
4. **Restore kubeconfig** – menulis file `~/.kube/config` dari secret base64 dan mengecek koneksi cluster.
5. **Siapkan namespace & repo Helm** – membuat namespace `cattle-system` jika belum ada dan memperbarui repo chart Rancher.
6. **Bersihkan release gagal** – menghapus instalasi Rancher yang statusnya gagal agar upgrade tidak konflik.
7. **Validasi NodePort** – mengecek apakah port yang diminta sudah digunakan service lain.
8. **Apply Service NodePort** – membuat service `rancher-nodeport` dengan selector `app: rancher`.
9. **Helm upgrade/install** – memasang Rancher tanpa ingress bawaan karena SSL di-handle oleh NPM.
10. **Rollout & health-check** – menunggu deployment sukses lalu melakukan `curl /healthz` via port-forward.
11. **Output Node IP** – mencetak daftar IP node dan NodePort untuk konfigurasi di NPM.
12. **Cleanup otomatis** – jika workflow gagal, Helm release dan resource terkait dibersihkan agar cluster kembali bersih.

## Menjalankan Deployment
1. Buka tab **Actions** di GitHub repository ini.
2. Pilih workflow **"Deploy Rancher (NodePort via NPM) - One Click"**.
3. Klik **Run workflow** dan isi parameter opsional:
   - `nodePort` (default `32080`), sesuaikan dengan rule port yang sudah dibuka di firewall/NPM.
   - `replicas` jumlah pod Rancher, default `2` untuk high availability.
4. Tekan **Run workflow** dan tunggu seluruh langkah selesai hijau. Durasi instalasi awal ±10–15 menit.
5. Setelah sukses, arahkan NPM ke salah satu IP node & NodePort yang tercetak di log workflow.
6. Akses `https://<hostname-rancher>` melalui browser untuk melakukan setup admin password.

## Troubleshooting
- **NodePort bentrok**: ganti parameter `nodePort` saat menjalankan workflow atau hapus service lain yang memakai port tersebut.
- **Token kedaluwarsa**: buat ulang token service account dan perbarui secret `KUBECONFIG_B64`.
- **Rancher tidak sehat**: cek log dengan `kubectl -n cattle-system logs deploy/rancher -c rancher`. Pastikan resource cluster (CPU/RAM) cukup.
- **NPM 502/504**: verifikasi firewall memperbolehkan akses ke NodePort dan service `rancher-nodeport` menunjukkan endpoint siap (`kubectl -n cattle-system get endpoints rancher-nodeport`).

## Referensi Tambahan
- [Dokumentasi resmi Rancher](https://docs.ranchermanager.rancher.io/)
- [GitHub Actions self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/about-self-hosted-runners) – gunakan jika cluster hanya dapat diakses dari jaringan internal.
