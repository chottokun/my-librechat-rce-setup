---
type: concept
title: LibreChat RCE Setup
description: Docker Compose setup for a personal LibreChat and Code Interpreter (RCE) sandbox in a fully isolated environment.
generated: false
status: active
tags: [readme, librechat, rce, sandbox, docker]
---

# LibreChat RCE Setup / LibreChat & RCE 隔離セットアップ

This repository provides a Docker Compose setup for a personal **LibreChat** and **Code Interpreter (RCE)** sandbox running in a completely isolated, air-gapped environment.
外部通信を遮断した自閉・完全隔離環境で動作する、個人向けの **LibreChat** および **Code Interpreter (RCE)** サンドボックスの Docker Compose セットアップ構成です。

> **Note**: This repository is for personal custom configuration and verification. It is not affiliated with the official LibreChat project.
> **Note**: 本リポジトリは公式の LibreChat プロジェクトとは無関係の個人的なカスタム構成・検証用セットアップです。

---

## 1. Quick Start / クイックスタート

### 1.1 Clone Repository and Submodules / リポジトリとサブモジュールのクローン
```bash
# Clone with submodules / サブモジュールを含めてクローン
git clone --recursive <repository-url>
cd my-librechat-rce-setup

# If already cloned / 既に通常の clone を行っている場合:
git submodule update --init --recursive
```

### 1.2 Configuration / 設定ファイルの作成
```bash
cp .env.example .env
# Edit .env to add your <API_KEY> and secrets using dummy or real tokens.
# 必要に応じて .env 内の API キーやシークレットを編集します。
```

### 1.3 Generate SSL/TLS Certificates / SSL/TLS 証明書の生成 (開発・テスト用)
```bash
# Auto-generate self-signed SSL certificates / 自己署名SSL証明書を自動生成 (nginx/certs/ 配下に出力)
bash scripts/generate-self-signed-cert.sh --force
```

### 1.4 Validate Configuration / 設定ファイルの構文検証 (任意)
```bash
docker compose config
```

### 1.5 Start Services / サービスの起動
```bash
docker compose up -d --build
```

Access the service via your browser at `https://localhost` (or your configured domain).
起動後、ブラウザで `https://localhost` (または設定したドメイン) にアクセスします。

---

## 2. Verification and Testing / 動作確認・テスト

```bash
# Run End-to-End Test Suite (SSL, API, Storage, RCE) / 統合 E2E テストスイートの実行
bash scripts/test-e2e-ssl.sh

# Container Health Checks / コンテナ個別ヘルスチェック
bash scripts/health-check.sh

# Shell Script Static Analysis / シェルスクリプトの静的解析 (ShellCheck)
shellcheck scripts/*.sh
```

---

## 3. Key Refactoring and Security / 主なリファクタリング・セキュリティ適用事項

- **Secret Separation / 機密情報の完全分離:** Passwords, secrets, and API keys (`<API_KEY>`) are strictly managed via environment variables (`.env`).
- **Health Checks / ヘルスチェック・依存連携:** Utilizing `condition: service_healthy` in `docker-compose.yml` for robust container orchestration.
- **Script Hardening / スクリプトの堅牢化:** Enforcing `set -euo pipefail` and zero ShellCheck warnings.

---

## 4. Documentation Structure / ドキュメント構成

Comprehensive documentation in OKF v0.2 format is available in the `docs/` directory:
詳細なドキュメントは `docs/` フォルダ配下にあります（OKF v0.2形式）：

- **[Documentation Index / 目次](docs/README.md)**
- **Architecture / アーキテクチャ**
  - [Architecture Notes / アーキテクチャノート](docs/architecture/architecture-notes.md)
  - [RCE Isolation Verification / RCE隔離検証](docs/architecture/rce-isolation.md)
  - [Security Considerations / セキュリティ考察](docs/architecture/security.md)
- **Infrastructure / インフラストラクチャ**
  - [Deployment Guide / デプロイメントガイド](docs/infrastructure/deployment-guide.md)

---

## 5. License and Acknowledgements / ライセンス・クレジット

### Repository License / 本リポジトリのライセンス
Files, scripts, and documentation in this repository are available under the [MIT License](LICENSE). They are provided "as is" without warranty.
本リポジトリ内の設定ファイル、スクリプト、ドキュメントは [MIT License](LICENSE) のもとで公開・利用可能です。無保証での提供となります。

### Upstream Components / 関連・利用コンポーネントのライセンス帰属
- **[LibreChat](https://github.com/danny-avila/LibreChat)**: MIT License (Copyright (c) Danny Avila)
- **[Code Interpreter Sandbox](https://github.com/LibreChat-AI/code-interpreter)**: Apache License 2.0 (Copyright (c) LibreChat-AI)
- **[NsJail](https://github.com/google/nsjail)**: Apache License 2.0 (Copyright (c) Google LLC)
- **[MinIO](https://github.com/minio/minio)**: GNU AGPLv3 (Copyright (c) MinIO, Inc.)
- **Redis / MongoDB / Nginx**: Licensed under their respective project terms.

### Disclaimer / 免責事項
This setup is for personal verification and custom operation. The author holds no liability for any direct or indirect damages or troubles arising from the use of this configuration. Please use it at your own risk.
本構成の利用によって生じた直接的・間接的な損害やトラブルについて、作成者は一切の責任を負いません。自己責任でご利用ください。
