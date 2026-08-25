# LibreChat & Code Interpreter デプロイメントガイド

## 概要

本ガイドは、エンタープライズ閉域網環境において LibreChat と Code Interpreter（RCE）を
安全にデプロイするための手順書です。

## 前提条件

| 項目 | 要件 |
|:-----|:-----|
| **OS** | RHEL 9 / Ubuntu 22.04 LTS / Debian 12 |
| **CPU** | 8 Core 以上 |
| **RAM** | 32 GB 以上 |
| **Storage** | NVMe/SSD 250 GB 以上 |
| **Docker** | Docker Engine 24.0+ / Docker Compose V2 |
| **ネットワーク** | 閉域網（外部インターネット接続なし） |
| **仮想化支援 (推奨)** | （KVM/ネスト仮想化有効時: MicroVM隔離、無効時: NsJail直接隔離） |

## ディレクトリ構成

```
RCE_LC/
├── .env.example                    # 環境変数テンプレート（網羅的定義）
├── .env                            # 環境変数（実運用値、.env.exampleからコピー）
├── docker-compose.yml              # 統合Docker Compose定義
├── Dockerfile.worker               # Worker Sandboxカスタムイメージ
├── rce_requirements.txt            # Worker Sandbox用Pythonパッケージ一覧
├── librechat.yaml                  # LibreChat設定（LLMエンドポイント等）
├── nginx/
│   ├── nginx.conf                  # Nginx SSL/TLSリバースプロキシ設定
│   └── certs/
│       ├── server.crt              # SSL証明書（手動配置 or スクリプト生成）
│       └── server.key              # 秘密鍵
├── scripts/
│   ├── init-minio.sh               # MinIOバケット初期化
│   ├── generate-self-signed-cert.sh # 自己署名証明書生成
│   ├── test-e2e-ssl.sh             # 統合E2Eテストスイート
│   ├── export-images.sh            # イメージエクスポート/ロード
│   └── health-check.sh             # ヘルスチェック
└── docs/
    ├── deployment-guide.md                    # 本ガイド
    ├── rce-isolation-verification.md           # RCE閉空間・隔離検証レポート
    ├── troubleshooting-and-architecture-notes.md # 構築・運用知見とトラブルシューティング
    └── security-considerations.md             # セキュリティ考察・リスク評価レポート
```

---

## ステージ 1: オンライン開発環境での事前ビルドと移送

> **実施場所**: インターネット接続可能な開発端末

### 1.1 リポジトリのクローンと設定

```bash
# サブモジュールを含めてクローン
git clone --recursive <repository-url>
cd RCE_LC

# 既存クローンの場合はサブモジュールを初期化・取得
git submodule update --init --recursive

# .env.example をコピーして .env を作成
cp .env.example .env

# 必要に応じて .env および rce_requirements.txt を編集
vi .env
```

### 1.2 Dockerイメージのプルとカスタムビルド

```bash
# 全イメージのプル + カスタムWorkerイメージのビルド + アーカイブ化
bash scripts/export-images.sh ./image-archives
```

出力されるアーカイブ一覧:
- `nginx__1.25-alpine.tar.gz`
- `ghcr.io__danny-avila__librechat-dev-api__latest.tar.gz`
- `mongo__6.0.tar.gz`
- `minio__minio__RELEASE.2025-09-07T16-13-09Z.tar.gz`
- `minio__mc__latest.tar.gz`
- `redis__7.2-alpine.tar.gz`
- `rce_lc-code-api__latest.tar.gz`
- `rce_lc-service-worker__latest.tar.gz`
- `rce_lc-sandbox-runner__latest.tar.gz`
- `rce_lc-egress-gateway__latest.tar.gz`
- `rce_lc-file-server__latest.tar.gz`
- `rce_lc-tool-call-server__latest.tar.gz`

### 1.3 物理メディアへのコピー

```bash
# USBストレージや外付けHDDへコピー
cp -r ./image-archives /media/usb-drive/
cp -r ./ /media/usb-drive/RCE_LC/
```

---

## ステージ 2: 閉域サーバーへの移送とイメージロード

> **実施場所**: 閉域網内のデプロイサーバー

### 2.1 ファイルの配置

```bash
# 物理メディアからプロジェクトディレクトリをコピー
cp -r /media/usb-drive/RCE_LC /opt/RCE_LC
cd /opt/RCE_LC
```

### 2.2 Dockerイメージのロード

```bash
bash scripts/export-images.sh --load /media/usb-drive/image-archives

# ロード確認
docker images
```

---

## ステージ 3: 証明書配置と環境設定

### 3.1 SSL証明書の配置

**オプションA: 社内PKI証明書を使用（推奨）**

```bash
# 社内PKI発行の証明書を配置
cp /path/to/pki/server.crt ./nginx/certs/server.crt
cp /path/to/pki/server.key ./nginx/certs/server.key
chmod 600 ./nginx/certs/server.key
```

**オプションB: 自己署名証明書を生成（開発・テスト用）**

```bash
bash scripts/generate-self-signed-cert.sh librechat.internal.domain
```

### 3.2 環境変数の設定

```bash
# .env ファイルを環境に合わせて編集
vi .env
```

**必ず変更すべき項目:**

| 変数 | 説明 | デフォルト値 |
|:-----|:-----|:------------|
| `DOMAIN` | 社内ドメイン名 | `librechat.internal.domain` |
| `MINIO_ROOT_PASSWORD` | MinIO管理者パスワード | `Secure_Encrypted_Minio_Password_98765` |
| `REDIS_PASSWORD` | Redisパスワード | `Secure_Redis_Password_54321` |
| `LIBRECHAT_CODE_API_KEY` | Code Interpreter APIキー | `Internal_Enterprise_RCE_Secret_Key_2026` |
| `CODEAPI_API_KEY` | Code API認証キー | `Internal_Enterprise_RCE_Secret_Key_2026` |

### 3.3 Nginx設定のドメイン名更新

```bash
# nginx.conf内のドメイン名を実際の値に更新
sed -i 's/librechat.internal.domain/YOUR_ACTUAL_DOMAIN/g' nginx/nginx.conf
```

---

## ステージ 4: サービス起動と健全性判定

### 4.1 サービスの一括起動

```bash
docker compose up -d
```

### 4.2 起動状態の確認

```bash
# 全コンテナの状態確認
docker compose ps

# 期待される出力:
# enterprise-nginx     running (healthy)
# librechat-api        running (healthy)
# librechat-mongodb    running (healthy)
# rce-minio            running (healthy)
# rce-minio-init       exited (0)          ← ワンショットジョブなので正常終了
# rce-redis            running (healthy)
# rce-code-api         running (healthy)
# rce-code-worker      running
```

### 4.3 ログの確認

```bash
# 全サービスのログを確認
docker compose logs -f

# 特定サービスのログを確認
docker compose logs -f code-api code-worker minio
```

### 4.4 包括的ヘルスチェック

```bash
bash scripts/health-check.sh
```

---

## ステージ 5: セキュリティ検証

### 5.1 セッション間ファイル隔離テスト

LibreChatのUIで以下を実行:

1. **チャットA** で以下のコードを実行:
   ```python
   with open('/mnt/data/test.txt', 'w') as f:
       f.write('Secret data from Chat A')
   print('ファイル作成完了')
   ```

2. **チャットB** で以下のコードを実行:
   ```python
   with open('/mnt/data/test.txt', 'r') as f:
       print(f.read())
   ```

**期待結果**: チャットBで `FileNotFoundError` が発生すること。

### 5.2 SSRF・外部通信拒否テスト

Code Interpreter で以下を実行:
```python
import urllib.request
urllib.request.urlopen('http://192.168.1.1')
```

**期待結果**: 接続エラー（`rce-isolated` ネットワークにより外部通信が遮断）。

### 5.3 プロセス爆発（Fork Bomb）テスト

```python
import os
[os.fork() for _ in range(100)]
```

**期待結果**: `pids_limit` により即座に停止し、他サービスが健全であること。

### 5.4 SSL終端テスト

社内端末のブラウザから:
```
https://librechat.internal.domain
```

**期待結果**: SSL証明書が正常認識され、443ポートで保護されていること。

---

## トラブルシューティング

### Q: LibreChatが起動しない
```bash
docker compose logs api
# MongoDBへの接続エラーの場合:
docker compose restart mongodb
docker compose restart api
```

### Q: Code Interpreterが動作しない
```bash
# Code APIのログを確認
docker compose logs code-api

# Redis接続を確認
docker compose exec redis redis-cli -a ${REDIS_PASSWORD} ping

# MinIO接続を確認
docker compose exec minio mc alias set local http://localhost:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}
```

### Q: SSL証明書エラー
```bash
# 証明書の有効期限を確認
openssl x509 -in nginx/certs/server.crt -noout -enddate

# 証明書のCNを確認
openssl x509 -in nginx/certs/server.crt -noout -subject
```

### Q: Workerがクラッシュする
```bash
# privilegedモードが有効か確認（NsJailに必須）
docker inspect rce-code-worker --format '{{.HostConfig.Privileged}}'

# cgroupv2が有効か確認
cat /sys/fs/cgroup/cgroup.controllers
```

---

## アーキテクチャ図

```
社内LAN
    │
    ▼ HTTPS (443)
┌─────────────┐
│   Nginx     │ ← SSL/TLS終端, WebSocket中継
│ (public-    │
│  frontend)  │
└──────┬──────┘
       │ HTTP (3080)
       ▼
┌─────────────┐     ┌──────────────┐
│ LibreChat   │────▶│   MongoDB    │
│   API       │     │              │
│ (public-    │     │ (public-     │
│  frontend,  │     │  frontend)   │
│  rce-backend│     └──────────────┘
└──────┬──────┘
       │ HTTP (7000)
       ▼
┌─────────────┐
│  Code API   │ ← APIキー認証, タスクキュー投入
│  Gateway    │
│ (rce-backend│
│  rce-       │
│  isolated)  │
└──────┬──────┘
       │ Redis Queue
       ▼
┌─────────────┐     ┌──────────────┐     ┌──────────────┐
│   Worker    │────▶│    Redis     │     │    MinIO     │
│  Sandbox    │     │  (Queue)     │     │  (S3互換)    │
│  (NsJail)   │────▶│              │     │              │
│ (rce-       │     └──────────────┘     └──────────────┘
│  isolated)  │              ▲                    ▲
└─────────────┘              │                    │
       │                     │                    │
       └─────────────────────┴────────────────────┘
              rce-isolated (internal: true)
              → 外部インターネット通信完全遮断
```
