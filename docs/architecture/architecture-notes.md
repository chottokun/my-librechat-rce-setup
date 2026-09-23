---
type: concept
title: Architecture & Troubleshooting Notes
description: Technical insights and troubleshooting for the deployment of LibreChat and Code Interpreter Sandbox.
generated: false
status: active
tags: [architecture, troubleshooting, design]
---

# Architecture & Troubleshooting Notes / 構築・運用知見とトラブルシューティング

This document records technical insights, configuration notes, and troubleshooting history derived from deploying **LibreChat** and **Code Interpreter (RCE) Sandbox** in a closed network environment.
本ドキュメントは、閉域網環境における **LibreChat** および **Code Interpreter (RCE) サンドボックス** の構築・実用化にあたって得られた技術的知見、設定上の注意点、およびトラブルシューティングの記録です。

---

## 1. Domain and SSL/TLS / ドメイン設定と SSL/TLS 証明書

### 1.1 Domain Matching Principle / ドメイン名の一致原則
- The `DOMAIN` in `.env`, the `server_name` in `nginx/nginx.conf`, and the **SAN (Subject Alternative Name)** of the SSL certificate must strictly match.
- `.env` の `DOMAIN`、`nginx/nginx.conf` の `server_name`、および SSL 証明書の SAN は必ず一致させる必要があります。

---

## 2. External LLM API Integration / 外部 LLM API 連携の知見

### 2.1 Environment Variables in `librechat.yaml` / 環境変数展開の仕様
- **Note**: The LibreChat YAML parser only supports simple variable substitution `${VAR}`. Defaults like `${VAR:-default}` are passed as literal strings. Set defaults in `.env`.
- **注意点**: YAML パーサーは `${VAR}` の単純な変数置換のみをサポートします。デフォルト値は `.env` 側で設定してください。

### 2.2 Model Fetching / モデル指定と `fetch: true`
- Using `models.fetch: true` automatically populates the model dropdown from the upstream provider's `/v1/models` endpoint.
- `models.fetch: true` を設定することで、利用可能な最新モデル一覧を自動取得し UI に反映できます。

---

## 3. Registration and Authentication / ユーザー登録と認証設定

### 3.1 Enabling Sign-ups / 新規登録画面の有効化
If registration is disabled, verify these variables on the `api` service:
初期状態でユーザー登録画面が表示されない場合は、以下を確認します：
- `ALLOW_REGISTRATION=true`
- `ALLOW_EMAIL_LOGIN=true`

---

## 4. Code Interpreter Integration & Troubleshooting / RCE 連携とトラブルシューティング

### 4.1 Port Mismatch (ECONNREFUSED) / ポート番号の不一致
- **Issue**: `connect ECONNREFUSED 172.xx.0.x:7000`
- **Cause**: The `code-api` image (Uvicorn) listens on **port 8000** by default.
- **Fix**: Set `LIBRECHAT_CODE_BASEURL=http://code-api:8000` and `CODE_API_PORT=8000`.

### 4.2 401 Unauthorized during Internal Communication / 内部通信時の 401 認証エラー
- **Issue**: LibreChat tool requests to CodeAPI return `401 Invalid API Key`.
- **Cause**: LibreChat's `bash_tool` skips sending Auth headers for internal Docker network requests.
- **Fix**: Set **`DISABLE_CODE_API_AUTH=true`** for the `code-api` service to bypass auth for internal network requests securely.

---

## 5. Multi-tenant Isolation Proof / セッション分離の実証知見

### 5.1 Isolation Mechanism / 隔離のメカニズム
- **Ephemeral Workspaces**: A unique UUID directory (`/tmp/{session_uuid}/`) is generated per session.
- **Mount Namespace**: Processes only mount their own session directory.
- **MinIO Segregation**: Objects are saved under `/{session_id}/...`.

---

## 6. Operation Cheat Sheet / クイック運用チートシート

```bash
# 1. Restart and rebuild / 再起動とビルド
docker compose up -d --build

# 2. SSL Cert Generation / SSL証明書の再発行
bash scripts/generate-self-signed-cert.sh --force <DOMAIN_NAME>
docker compose restart nginx

# 3. E2E Test Suite / 統合E2Eテスト
bash scripts/test-e2e-ssl.sh

# 4. Health Checks / ヘルスチェック
bash scripts/health-check.sh
```

---

## 7. Environments without KVM Support / KVM 非対応環境での運用

### 7.1 Fallback to NsJail Direct Mode / NsJail 直接モードへの切り替え
If `/dev/kvm` is missing (e.g. VPS or cloud VMs without nested virtualization), configure `.env` with:
`/dev/kvm` が存在しない環境では以下を設定します：
```env
KVM_ENABLED=false
```
And grant `privileged: true` to the `sandbox-runner` container in `docker-compose.yml`.

---

## 8. LibreChat BaseURL Path / BaseURL パス仕様 (`/v1`)

- **Issue**: Uploading files fails with `404 Not Found`.
- **Fix**: The `LIBRECHAT_CODE_BASEURL` must include the `/v1` suffix (e.g., `http://code-api:8000/v1`).

---

## 9. Fully Baked Sandbox Architecture / 完全自己完結型（Baked）設計の採用

### 9.1 Background / 背景
When `KVM_ENABLED=false`, the standard behavior expects dynamic mounts (`/host-packages`) from the host or K8s PVC, causing boot delays or missing dependencies.
`KVM_ENABLED=false` 時、標準動作ではホストからの動的マウントを期待するため、依存関係が見つからずエラーが発生します。

### 9.2 Decision: Pre-baked Dockerfile / 親リポジトリでの Baked イメージ採用
We introduced a custom `Dockerfile.sandbox-runner` at the root repository to completely pre-bake all python dependencies, node runtime, and Japanese fonts (e.g. `japanize-matplotlib`) into the image.
完全自己完結させる `Dockerfile.sandbox-runner` を採用しました。
- **Benefits**: Instant boot times, perfect Japanese font support, and zero modifications required to the upstream submodule tree.
- **利点**: 即時起動、完全な日本語環境サポート、上流サブモジュールへの修正不要。
