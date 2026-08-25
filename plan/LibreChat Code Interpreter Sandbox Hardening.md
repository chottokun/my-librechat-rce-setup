# **エンタープライズオンプレミス環境におけるLibreChat & Code Interpreter完全実装計画書**

金融、官公庁、医療、製造などの高度なセキュリティ要件を求めるエンタープライズ組織向けに、外部インターネットから完全に遮断された閉域網（エアギャップ環境）において、LibreChatおよびCode Interpreter（動的コード実行機能: RCE）を安全かつ堅牢にデプロイ・運用するための詳細実装計画（Implementation Master Plan）を提示します。  

本計画書では、最前段にNginxリバースプロキシを配置してSSL/TLS終端を担当させるとともに、最新の公式エコシステム（[LibreChat-AI/code-interpreter](https://github.com/LibreChat-AI/code-interpreter)）に準拠した **MinIO**（S3互換ストレージ）および **Redis**（インメモリタスクキュー）を軸とした本番運用アーキテクチャを定義します。

---

## **1. プロジェクト概要と前提条件・要求仕様**

### **1.1 システム要件と前提環境**

* **ネットワーク環境**: 完全自閉型ネットワーク（外部インターネット接続なし、DNS外部ルックアップ不能）。  
* **LLM基盤**: 閉域網内に設置されたローカル推論サーバー（Ollama, vLLM, または TGI インスタンス）。  
* **証明書環境**: 社内PKI（プライベート認証局）発行のX.509 Server Certificate、または自己署名証明書。  
* **開発・コード方針**: コンテナソースコードの独自改変は行わない。オープンソースコミュニティ（`LibreChat-AI` 公式）および企業ポリシーに則った標準運用。

### **1.2 ハードウェア推奨スペック（単一ノードデプロイの場合）**

* **CPU**: 8 Core 以上（Worker SandboxおよびNginx/LibreChat並列処理用）  
* **RAM**: 32 GB 以上（推論エンジン同居時は別途GPU/RAMを割り当て）  
* **Storage**: NVMe / SSD 250 GB 以上（過渡的ファイル処理およびログ用）  
* **OS**: Red Hat Enterprise Linux 9 / Ubuntu 22.04 LTS / Debian 12

---

## **2. コンポーネント選定理由と最新仕様**

本構成では、生産実績・API互換性・公式動作実績を最優先してプロダクトを選定しています。

### **2.1 公式 RCE 基盤：LibreChat-AI/code-interpreter への対応**

* **公式リポジトリ準拠**: 旧 `ClickHouse/code-interpreter` から LibreChat 公式である `LibreChat-AI/code-interpreter` へ統合・標準化されたアーキテクチャに対応。
* **サンドボックス実行権限と分離**: NsJail（Linux Namespace + Cgroups + Seccomp）および `KVM_ENABLED` 設定によるマイクロVM/コンテナ隔離のハイブリッド対応。

### **2.2 S3互換ストレージ：MinIO の採用理由**

* **圧倒的な生産実績**: クラウドネイティブなプライベートS3ストレージとして世界中で採用されているデファクトスタンダード。  
* **機能網羅性と完全互換性**: AWS S3 APIとの完全な互換性、自動オブジェクトライフサイクル管理（セッションファイルの自動TTL消去）、直感的なWebコンソール管理UIを標準提供。  
* **公式統合**: LibreChat公式 Code Interpreter（`code-api` / `file-server`）が標準テストおよび公式デプロイガイドで直接動作確認を行っているストレージ基盤。

### **2.3 インメモリデータストア：Redis の採用理由**

* **圧倒的な業界実績**: Celery, BullMQ, 各種分散キューイングシステムの基盤として長年実績を持つ高速インメモリデータストア。  
* **低遅延タスク配信**: Code API Gateway から Worker Sandbox へのタスク配信（Pub/Sub・Queue）において高い信頼性を発揮。

---

## **3. オンプレミス完全閉域アーキテクチャ設計と通信トポロジー**

最前段にNginxリバースプロキシを配置し、HTTPS (443) のみを社内ユーザーLANに公開します。LibreChat本体、Code API Gateway、Worker Sandbox、ストレージ、データベース群はすべてDocker内部ネットワーク上に隠蔽し、直接アクセスを遮断します。

### **3.1 コンポーネント役割定義**

| コンポーネント | 採用プロダクト | 役割・機能 | 通信ポート（外部/内部） | 所属ネットワーク |
| :---- | :---- | :---- | :---- | :---- |
| **Reverse Proxy** | **Nginx** | SSL/TLS終端、リバースプロキシ、WebSocket中継、バッファ制御 | Host 80, 443 | public-frontend |
| **App API** | **LibreChat API** | UI提供、ユーザー管理、LLMプロンプト制御、セッション管理 | Container 3080 | public-frontend, rce-backend |
| **Database** | **MongoDB** | ユーザーデータ、会話履歴、設定値の永続化 | Container 27017 | public-frontend |
| **RCE Gateway** | **Code API Gateway** | コード実行タスクの受付、APIキー認証、Redisキュー投入 | Container 7000 (または 3112) | rce-backend, rce-isolated |
| **RCE Worker** | **Worker Sandbox** | NsJail / MicroVM 内でのコード実行（Ephemeral Sandbox） | なし（Worker動作） | rce-isolated |
| **Queue / Cache** | **Redis** | タスクキュー管理およびセッションメタデータキャッシュ | Container 6379 | rce-isolated |
| **Object Storage** | **MinIO** | セッション分離型オブジェクトストレージ（/{session_id}/ 保存） | Container 9000 (Console: 9001) | rce-isolated |
| **Storage Init** | **MinIO Init (mc)** | 起動時のバケット（code-interpreter-files）自動作成 | なし（Job完了後停止） | rce-isolated |

### **3.2 3層ネットワーク隔離トポロジー**

1. **`public-frontend` (Bridge)**: Nginx, LibreChat API, MongoDB が所属。社内ユーザーLANからのアクセスを受付。
2. **`rce-backend` (Bridge)**: LibreChat API ↔ Code API Gateway 間の通信を仲介。
3. **`rce-isolated` (Bridge, `internal: true`)**: Code API, Redis, MinIO, Worker Sandbox が所属。**外部ルーティング完全遮断**によりSSRFおよび情報漏洩を物理防止。

### **3.3 通信フロー制御**

> 1. **ユーザーリクエスト**: 社内端末からNginxへ HTTPS (Port 443) アクセス。  
> 2. **Web/WebSocket中継**: Nginxが復号後、LibreChat API (Port 3080) へ転送。  
> 3. **推論処理**: LibreChatが社内ローカルLLM（Ollama等）へプロンプト送信。  
> 4. **コード実行指示**: LLMがコード生成時、LibreChatが会話ID（session_id）を付与して Code API (Port 7000/3112) へリクエスト。  
> 5. **サンドボックス分離実行**: WorkerがRedisからタスクを取得し、MinIOから該当 session_id のファイルを一時領域に復元後、NsJail内でコードを実行。  
> 6. **結果同期**: 生成物（画像等）をMinIOの /{session_id}/ 領域へ保管し、Worker内のメモリ/ローカルディスクを即座に消去。

---

## **4. 詳細構成定義と設定ファイル実装仕様**

### **4.1 Nginx リバースプロキシ設定 (`nginx/nginx.conf`)**

SSL/TLS終端、WebSocket中継、セキュリティヘッダー、タイムアウト延長、および大容量ファイル受信用設定を適用したNginx構成です。

```nginx
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 2048;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # データ分析用大容量ファイル受信用設定 (100MB)
    client_max_body_size 100M;

    # LLM生成およびコード実行待機用タイムアウト設定 (10分)
    proxy_connect_timeout 600s;
    proxy_send_timeout    600s;
    proxy_read_timeout    600s;

    # レートリミット設定
    limit_req_zone $binary_remote_addr zone=api_limit:10m rate=30r/s;

    # セキュリティヘッダー
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    server {
        listen 80;
        server_name librechat.internal.domain;

        location /nginx-health {
            access_log off;
            return 200 "OK";
            add_header Content-Type text/plain;
        }

        location / {
            return 301 https://$host$request_uri;
        }
    }

    server {
        listen 443 ssl http2;
        server_name librechat.internal.domain;

        ssl_certificate     /etc/nginx/certs/server.crt;
        ssl_certificate_key /etc/nginx/certs/server.key;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5:!RC4;
        ssl_prefer_server_ciphers on;
        ssl_session_cache shared:SSL:10m;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

        location / {
            limit_req zone=api_limit burst=50 nodelay;

            proxy_pass http://api:3080;
              
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # WebSocket ストリーミング設定 (LLMリアルタイム出力用)
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";

            proxy_buffering off;
            proxy_read_timeout 86400s;
        }

        location /api/ {
            limit_req zone=api_limit burst=50 nodelay;

            proxy_pass http://api:3080;

            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Authorization $http_authorization;

            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";

            proxy_buffering off;
        }
    }
}
```

### **4.2 Worker Sandbox 用 Dockerfile (`Dockerfile.worker`)**

閉域環境でのデータ解析およびグラフ描画に必要なPythonライブラリと日本語フォント、およびMatplotlibの日本語デフォルト設定を事前組み込み（Pre-baking）します。

```dockerfile
FROM ghcr.io/clickhouse/code-interpreter-worker:latest

USER root

# 日本語フォントおよび描画ライブラリ依存関係の導入
RUN apt-get update && apt-get install -y --no-install-recommends \
    fonts-ipafont-gothic \
    fonts-ipafont-mincho \
    libgomp1 \
    ffmpeg \
    ghostscript \
    && rm -rf /var/lib/apt/lists/*

# 日本語表示対応および主要Pythonパッケージの事前インストール
RUN pip install --no-cache-dir \
    numpy==1.26.4 \
    pandas==2.2.2 \
    matplotlib==3.8.4 \
    seaborn==0.13.2 \
    scipy==1.13.0 \
    sympy==1.12 \
    openpyxl==3.1.2 \
    scikit-learn==1.4.2 \
    japanize-matplotlib==1.1.3 \
    pillow==10.3.0

# Matplotlib デフォルト日本語フォント設定
RUN python3 -c "\
import matplotlib; \
import os; \
mpl_dir = matplotlib.get_configdir(); \
os.makedirs(mpl_dir, exist_ok=True); \
with open(os.path.join(mpl_dir, 'matplotlibrc'), 'w') as f: \
    f.write('font.family : IPAGothic\n'); \
    f.write('axes.unicode_minus : False\n'); \
" && \
    python3 -c "import matplotlib.font_manager; matplotlib.font_manager._load_fontmanager(try_read_cache=False)"

USER 1001
```

### **4.3 統合 Docker Compose 定義 (`docker-compose.yml`)**

MinIOおよびRedisを中心とし、厳格なネットワーク隔離（`internal: true`）、ヘルスチェックによる起動制御、およびDocker Compose V2仕様に適合したリソース制限（`deploy.resources.limits`）を課したプロダクション構成定義です。

```yaml
version: '3.8'

networks:
  public-frontend:
    driver: bridge
  rce-backend:
    driver: bridge
  rce-isolated:
    driver: bridge
    internal: true # 外部アクセスおよびルーティングを全遮断

services:
  # 1. SSL/TLS リバースプロキシ (Nginx)
  nginx:
    image: nginx:1.25-alpine
    container_name: enterprise-nginx
    restart: unless-stopped
    ports:
      - "${NGINX_HTTP_PORT:-80}:80"
      - "${NGINX_HTTPS_PORT:-443}:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/certs:/etc/nginx/certs:ro
    networks:
      - public-frontend
    depends_on:
      api:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "--no-check-certificate", "--spider", "-q", "http://localhost:80/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

  # 2. LibreChat API サービス
  api:
    image: ghcr.io/danny-avila/librechat-dev-api:latest
    container_name: librechat-api
    restart: unless-stopped
    environment:
      - PORT=${LIBRECHAT_PORT:-3080}
      - MONGO_URI=${MONGO_URI:-mongodb://mongodb:27017/LibreChat}
      - DOMAIN_CLIENT=${DOMAIN_CLIENT:-https://librechat.internal.domain}
      - DOMAIN_SERVER=${DOMAIN_SERVER:-https://librechat.internal.domain}
      - LIBRECHAT_CODE_BASEURL=${LIBRECHAT_CODE_BASEURL:-http://code-api:7000}
      - LIBRECHAT_CODE_API_KEY=${LIBRECHAT_CODE_API_KEY}
    volumes:
      - ./librechat.yaml:/app/librechat.yaml:ro
    networks:
      - public-frontend
      - rce-backend
    depends_on:
      mongodb:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:3080/api/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

  # 3. データベース (MongoDB)
  mongodb:
    image: mongo:6.0
    container_name: librechat-mongodb
    restart: unless-stopped
    volumes:
      - mongo_data:/data/db
    networks:
      - public-frontend
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 20s

  # 4. デファクトS3ストレージ (MinIO) - セッション分離管理
  minio:
    image: minio/minio:RELEASE.2025-09-07T16-13-09Z
    container_name: rce-minio
    restart: unless-stopped
    command: server /data --console-address ":${MINIO_CONSOLE_PORT:-9001}"
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    volumes:
      - minio_data:/data
    networks:
      - rce-isolated
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 15s

  # 4a. MinIO バケット初期化 (ワンショット)
  minio-init:
    image: minio/mc:latest
    container_name: rce-minio-init
    entrypoint: >
      /bin/sh -c "
      until mc alias set myminio http://minio:9000 $${MINIO_ROOT_USER} $${MINIO_ROOT_PASSWORD} 2>/dev/null; do
        sleep 2;
      done;
      mc mb myminio/$${MINIO_BUCKET} --ignore-existing;
      "
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
      MINIO_BUCKET: ${MINIO_BUCKET:-code-interpreter-files}
    networks:
      - rce-isolated
    depends_on:
      minio:
        condition: service_healthy
    restart: "no"

  # 5. タスクキュー & セッション管理 (Redis)
  redis:
    image: redis:7.2-alpine
    container_name: rce-redis
    restart: unless-stopped
    command: redis-server --requirepass "${REDIS_PASSWORD}" --maxmemory 256mb --maxmemory-policy allkeys-lru
    networks:
      - rce-isolated
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 10s

  # 6. Code Interpreter API Gateway
  code-api:
    image: ghcr.io/clickhouse/code-interpreter-api:latest
    container_name: rce-code-api
    restart: unless-stopped
    environment:
      - PORT=${CODE_API_PORT:-7000}
      - REDIS_HOST=${REDIS_HOST:-redis}
      - REDIS_PORT=${REDIS_PORT:-6379}
      - REDIS_PASSWORD=${REDIS_PASSWORD}
      - S3_ENDPOINT=${S3_ENDPOINT:-minio:9000}
      - S3_ACCESS_KEY=${S3_ACCESS_KEY}
      - S3_SECRET_KEY=${S3_SECRET_KEY}
      - S3_BUCKET=${S3_BUCKET:-code-interpreter-files}
      - S3_SECURE=${S3_SECURE:-false}
      - CODEAPI_API_KEY=${CODEAPI_API_KEY}
      - KVM_ENABLED=${KVM_ENABLED:-false}
    depends_on:
      redis:
        condition: service_healthy
      minio:
        condition: service_healthy
    networks:
      - rce-backend
      - rce-isolated
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:7000/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 15s

  # 7. Code Interpreter Sandboxed Worker (NsJail)
  code-worker:
    build:
      context: .
      dockerfile: Dockerfile.worker
    container_name: rce-code-worker
    restart: unless-stopped
    privileged: true # NsJailのNamespace作成に必須
    environment:
      - REDIS_HOST=${REDIS_HOST:-redis}
      - REDIS_PORT=${REDIS_PORT:-6379}
      - REDIS_PASSWORD=${REDIS_PASSWORD}
      - S3_ENDPOINT=${S3_ENDPOINT:-minio:9000}
      - S3_ACCESS_KEY=${S3_ACCESS_KEY}
      - S3_SECRET_KEY=${S3_SECRET_KEY}
      - S3_BUCKET=${S3_BUCKET:-code-interpreter-files}
      - S3_SECURE=${S3_SECURE:-false}
      - MAX_EXECUTION_TIME=${MAX_EXECUTION_TIME:-30}
      - MAX_MEMORY_MB=${MAX_MEMORY_MB:-1024}
      - SESSION_TTL_HOURS=${SESSION_TTL_HOURS:-24}
      - KVM_ENABLED=${KVM_ENABLED:-false}
      - SANDBOX_USE_CGROUPV2=${SANDBOX_USE_CGROUPV2:-true}
      - SANDBOX_MAX_PROCESS_COUNT=${SANDBOX_MAX_PROCESS_COUNT:-100}
    deploy:
      resources:
        limits:
          cpus: "${WORKER_CPU_LIMIT:-2.0}"
          memory: ${WORKER_MEMORY_LIMIT:-2048M}
          pids: ${WORKER_PIDS_LIMIT:-50}
    depends_on:
      redis:
        condition: service_healthy
      minio:
        condition: service_healthy
    networks:
      - rce-isolated # インターネット通信完全不可

volumes:
  mongo_data:
  minio_data:
```

### **4.4 LibreChat 設定定義 (`librechat.yaml`)**

```yaml
version: 1.1.5

cache: true

# エージェントおよびツール設定
agents:
  capabilities:
    - "code_interpreter"
  tools:
    - "code_interpreter"

# オフライン・プライバシー設定
interface:
  privacyPolicy:
    externalUrl: ""
  termsOfService:
    externalUrl: ""

fileConfig:
  serverFileSizeLimit: 100
  avatarSizeLimit: 2

rateLimits:
  fileUploads:
    ipMax: 50
    ipWindowInMinutes: 60
    userMax: 25
    userWindowInMinutes: 60
```

---

## **5. フェーズ別デプロイメントロードマップ（構築手順）**

### **ステージ 1: オンライン開発環境での事前ビルドと移送**

> 1. 接続可能な端末で Dockerfile.worker から Worker 用イメージをビルド、および構成アーカイブを作成。  
>    ```bash
>    bash scripts/export-images.sh ./image-archives
>    ```
> 2. 生成されたイメージアーカイブ群を物理ストレージ経由でオンプレ閉域サーバーへ移送。  
> 3. 閉域サーバー上でイメージをロード。  
>    ```bash
>    bash scripts/export-images.sh --load ./image-archives
>    ```

### **ステージ 2: 証明書配置と環境設定**

> 1. 社内PKI発行の `server.crt` および `server.key` を `./nginx/certs/` に配置（テスト時は `bash scripts/generate-self-signed-cert.sh` を利用可）。  
> 2. 秘密鍵のパーミッションを設定（`chmod 600 ./nginx/certs/server.key`）。  
> 3. `.env` ファイルに本番シークレットを設定。

### **ステージ 3: サービス起動と健全性判定**

> 1. サービスを一括起動。  
>    ```bash
>    docker compose up -d
>    ```
> 2. 包括的ヘルスチェックスクリプトを実行。  
>    ```bash
>    bash scripts/health-check.sh
>    ```

---

## **6. セキュリティ検証・監査プロトコル**

本番稼働前に実施する検証項目一覧です。

| テスト大分類 | 実験手法・プロンプト | 期待動作（合格条件） |
| :---- | :---- | :---- |
| **1. セッション間ファイル隔離** | チャットAで `/mnt/data/test.txt` を生成後、チャットBで同参照 | ファイルが存在せず `FileNotFoundError` になること。 |
| **2. SSRF・外部通信拒否** | コード実行で `requests.get('http://192.168.1.1')` を試行 | `internal: true` により即座にコネクションエラーとなること。 |
| **3. プロセス爆発（Fork Bomb）** | `import os; [os.fork() for _ in range(100)]` を実行 | `pids: 50` 制限により即座に停止し、他サービスが健全であること。 |
| **4. SSL終端と暗号化通信** | 社内端末から `https://librechat.internal.domain` アクセス | SSL証明書が正常認識され、443ポートで保護されること。 |

---

## **7. 結論**

本マスタープランでは、ソースコード改変を行わない運用環境およびオープンな開発方針を踏まえ、**実効性とパフォーマンス・互換性が最も保証されている MinIO および Redis** をコアに選定し、`LibreChat-AI` 公式リポジトリ構成と Docker Compose V2 仕様への完全対応を行いました。最前段の Nginx による SSL 終端と、NsJail および MinIO によるセッション単位の隔離機構を組み合わせることで、完全閉域のオンプレミス環境において最高レベルの安定性とセキュリティを備えた動的コード実行基盤が完結します。