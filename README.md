# azuredevops-k8sagent-with-dind

Kubernetes üzerinde çalışan, Azure DevOps'a otomatik kayıt olan self-hosted agent. **Docker-in-Docker (DinD)** kullanır; pipeline'larda `docker build / login / push` ve `Trivy@2` (`method: docker`) olduğu gibi çalışır, template değişikliği gerekmez.

- Pod'da iki container vardır: **agent** (Docker CLI + araçlar) ve **dind** (Docker daemon, `privileged`)
- **kubectl** ve **helm** içerir, pod içinden ServiceAccount ile cluster'a deploy edebilir
- Ayrıca `az cli`, `powershell`, `git`, `jq` hazır gelir

## Agent image içeriği

Base: `mcr.microsoft.com/dotnet/sdk:<DOTNET_SDK_VERSION>-jammy` (Ubuntu 22.04)

| Araç | Sürüm | Build-arg | Not |
|---|---|---|---|
| .NET SDK | 8.0 | `DOTNET_SDK_VERSION` | Başka sürümler için pipeline'da `UseDotNet@2` |
| Node.js + npm + corepack | 20 | `NODE_VERSION` | Next.js / Node projeleri |
| JDK | 17 | - | `JAVA_HOME=/usr/lib/jvm/default-java`, SonarQube scanner için de gerekli |
| Maven | 3.9 | `MAVEN_VERSION` | `MAVEN_HOME=/usr/share/maven` |
| Docker CLI + buildx + compose | latest | `DOCKER_TAG` | Pinlemek için `27-cli` gibi. Daemon sidecar'da |
| kubectl | latest stable | `KUBECTL_VERSION` | Pinlemek için `v1.x.y` |
| helm | latest | `HELM_VERSION` | Pinlemek için `v3.x.y` |
| Azure Pipelines agent | latest | `RUNNER_VERSION` | Çalışma anında indirilir |
| `az cli`, `powershell`, `git`, `jq`, `curl`, `unzip` | - | - | |
| `build-essential`, `python3` | - | - | `node-gyp` gerektiren npm paketleri için |

`dotnet-coverage` gibi global dotnet tool'lar için `~/.dotnet/tools` PATH'tedir. Agent açılışta `java`, `node`, `npm`, `maven`, `dotnet`, `docker` capability'lerini otomatik kaydeder.

## Kurulum

### 1. Agent image'ını build et ve push et

```bash
docker build --platform linux/amd64 -t yourregistry/azuredevopsagent-dind:<tag> .
docker push yourregistry/azuredevopsagent-dind:<tag>
```

Sürümleri pinlemek için (verilmezse hepsi latest):

```bash
docker build \
  --build-arg RUNNER_VERSION=4.x.y \
  --build-arg KUBECTL_VERSION=v1.x.y \
  --build-arg HELM_VERSION=v3.x.y \
  --build-arg DOCKER_TAG=27-cli \
  -t yourregistry/azuredevopsagent-dind:<tag> .
```

Arm64 için: `--build-arg K8S_ARCH=arm64` ve `Dockerfile` içindeki `TARGETARCH=linux-arm64`.

Sonra [kubernetes/deployment.yaml](kubernetes/deployment.yaml) içindeki `image` alanını güncelle. Registry private ise `imagePullSecrets` de gerekir.

### 2. Azure DevOps hazırlığı

- Bir **Agent Pool** oluştur (Organization Settings → Agent pools).
- **PAT** üret. Yetki: `Agent Pools (Read & manage)`.

### 3. Namespace ve Secret

```bash
kubectl create namespace azagent
bash kubernetes/secret-creater.sh
```

Script sırasıyla Azure DevOps URL'ini (`https://dev.azure.com/<org>`), PAT'i, pool adını ve namespace'i (`azagent`) sorar.

### 4. RBAC ve Deployment

```bash
kubectl apply -f kubernetes/rbac.yaml
kubectl apply -f kubernetes/deployment.yaml
```

Birkaç dakika içinde agent'lar pool'da **Online** görünür.

> `rbac.yaml` agent'a tüm namespace'lerde `edit` yetkisi verir. Daha dar yetki için ClusterRoleBinding'i RoleBinding'e çevir.

### 5. (Opsiyonel) Helm repo

Pod her başladığında `HELM_REPO_NAME` ve `HELM_REPO_URL` env'leri varsa `helm repo add` + `helm repo update` çalışır. Env yoksa hiçbir şey yapılmaz.

| Env | Zorunlu | Açıklama |
|---|---|---|
| `HELM_REPO_NAME` | evet | Repo adı |
| `HELM_REPO_URL` | evet | Repo URL'i |
| `HELM_REPO_USERNAME` | hayır | Auth açıksa |
| `HELM_REPO_PASSWORD` | hayır | Auth açıksa (Secret'tan ver) |

## Docker-in-Docker nasıl çalışır

- `dind` container'ı `privileged` çalışır ve Docker daemon'ı barındırır. Agent container'ı `privileged` değildir.
- Agent, daemon'a `tcp://localhost:2376` üzerinden **TLS** ile bağlanır. Sertifikalar `docker-certs` emptyDir'i ile paylaşılır; sertifikası olmayan başka pod'lar daemon'ı kullanamaz.
- `/azp/_work` iki container'da **aynı yola** mount edilir. `docker run -v $(Build.SourcesDirectory)/...` gibi bind mount'ları (örn. Trivy task'ı) daemon çözdüğü için bu gereklidir.
- `start.sh`, agent'ı Azure DevOps'a kaydetmeden önce daemon'ın hazır olmasını bekler (en fazla ~2 dk).

### Dikkat

- **Privileged:** Cluster'da Pod Security Admission / policy'nin `azagent` namespace'inde privileged'a izin vermesi gerekir. Güvenilmeyen kod çalıştıran (fork PR'ları) pool'larda kullanma.
- **Cache:** `/var/lib/docker` emptyDir olduğu için pod yenilenince imaj/katman cache'i gider. Kalıcı cache için PVC kullanılabilir (replica başına ayrı olmalı).
- **Disk:** Uzun yaşayan pod'larda disk dolabilir; pipeline sonunda `docker system prune -f` eklenebilir.
- **Kaynak:** `dind` container'ının CPU/bellek limitleri `deployment.yaml`'da ayrı tanımlıdır.

## Pipeline'da kullanım

```yaml
pool:
  name: <pool-adı>

steps:
- script: |
    docker build -t <registry>/<image>:$(Build.BuildId) .
    docker push <registry>/<image>:$(Build.BuildId)
  displayName: Docker build & push

- script: |
    helm upgrade --install myapp ./chart -n myapp --set image.tag=$(Build.BuildId)
  displayName: Deploy
```

Registry kimlik bilgilerini pipeline'a düz metin yazma; secret variable / variable group veya `Docker@2` + service connection kullan.
