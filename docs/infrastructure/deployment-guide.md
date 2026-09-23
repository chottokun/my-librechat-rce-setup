---
type: concept
title: Deployment Guide
description: Step-by-step guide to deploying LibreChat and Code Interpreter in an isolated, air-gapped environment.
generated: false
status: active
tags: [deployment, infrastructure, air-gap, offline]
---

# Deployment Guide / デプロイメントガイド

## Overview / 概要

This guide provides step-by-step instructions for securely deploying LibreChat and Code Interpreter (RCE) in an enterprise air-gapped (closed network) environment.
本ガイドは、エンタープライズ閉域網環境において LibreChat と Code Interpreter（RCE）を安全にデプロイするための手順書です。

## Prerequisites / 前提条件

| Requirement / 項目 | Details / 要件 |
|:-----|:-----|
| **OS** | RHEL 9 / Ubuntu 22.04 LTS / Debian 12 |
| **CPU** | 8 Core+ |
| **RAM** | 32 GB+ |
| **Storage / ストレージ** | NVMe/SSD 250 GB+ |
| **Docker** | Docker Engine 24.0+ / Docker Compose V2 |
| **Network / ネットワーク** | Air-gapped (No internet) / 閉域網（外部インターネット接続なし） |
| **Virtualization / 仮想化** | KVM supported (recommended) / 仮想化支援 (推奨) |

## Directory Structure / ディレクトリ構成

```
RCE_LC/
├── .env.example                    # Env var template / 環境変数テンプレート
├── .env                            # Active environment file / 環境変数
├── docker-compose.yml              # Main compose file / 統合Docker Compose定義
├── Dockerfile.worker               # Sandbox image builder / Worker Sandboxカスタムイメージ
├── rce_requirements.txt            # Python dependencies / Worker Sandbox用Pythonパッケージ
├── librechat.yaml                  # App config / LibreChat設定
├── nginx/                          # Reverse proxy config / リバースプロキシ設定
├── scripts/                        # Utility scripts / ユーティリティスクリプト
└── docs/                           # Documentation / ドキュメント
```

---

## Stage 1: Pre-build in an Online Environment / ステージ 1: オンライン環境での事前ビルド

> **Location**: Developer machine with Internet access
> **実施場所**: インターネット接続可能な開発端末

### 1.1 Clone and Setup / クローンと設定

```bash
git clone --recursive <repository-url>
cd RCE_LC

cp .env.example .env
# Edit .env and rce_requirements.txt as needed
# 必要に応じて .env および rce_requirements.txt を編集
```

### 1.2 Pull, Build, and Export / イメージのプル・ビルド・エクスポート

```bash
# Export all images to tarballs / 全イメージをアーカイブ化
bash scripts/export-images.sh ./image-archives
```

### 1.3 Transfer to Physical Media / 物理メディアへのコピー

Copy the repository and `image-archives` to a USB drive or external HDD.
生成されたアーカイブ群とリポジトリを USB ストレージなどへコピーします。

---

## Stage 2: Load on Air-gapped Server / ステージ 2: 閉域サーバーでのロード

> **Location**: Target air-gapped server
> **実施場所**: 閉域網内のデプロイサーバー

### 2.1 Load Images / イメージのロード

```bash
cd /opt/RCE_LC
bash scripts/export-images.sh --load ./image-archives

# Verify / ロード確認
docker images
```

---

## Stage 3: Certificates & Environment / ステージ 3: 証明書配置と環境設定

### 3.1 SSL Certificate / SSL証明書の配置

**Option A: Enterprise PKI (Recommended) / 社内PKI証明書 (推奨)**
Copy `server.crt` and `server.key` into `./nginx/certs/` and `chmod 600`.

**Option B: Self-signed (Dev/Test) / 自己署名 (テスト用)**
```bash
bash scripts/generate-self-signed-cert.sh <YOUR_DOMAIN>
```

### 3.2 Configure `.env` / 環境変数の設定

Edit `.env` to match your production environment. **Crucial variables:**
必ず変更すべき項目:
- `DOMAIN`: Internal domain name / 社内ドメイン名 (e.g. `example.internal`)
- `MINIO_ROOT_PASSWORD`: MinIO Password / MinIO管理者パスワード
- `REDIS_PASSWORD`: Redis Password / Redisパスワード
- `LIBRECHAT_CODE_API_KEY`: Code Interpreter API Key

Update Nginx config to match:
```bash
sed -i 's/librechat.internal.domain/YOUR_ACTUAL_DOMAIN/g' nginx/nginx.conf
```

---

## Stage 4: Launch and Verify / ステージ 4: サービス起動と健全性判定

### 4.1 Start Services / 起動

```bash
docker compose up -d
```

### 4.2 Health Checks / ヘルスチェック

```bash
docker compose ps
bash scripts/health-check.sh
docker compose logs -f
```

---

## Stage 5: Security Validation / ステージ 5: セキュリティ検証

Run the following inside LibreChat's Code Interpreter:
LibreChat上で以下のテストを実行して隔離を確認します:

### 5.1 Egress Test / 外部通信拒否テスト
```python
import urllib.request
urllib.request.urlopen('http://8.8.8.8')
```
*Expected*: Connection error. / *期待結果*: 接続エラー。

### 5.2 Resource Limits (Fork Bomb) / プロセス爆発テスト
```python
import os
[os.fork() for _ in range(100)]
```
*Expected*: Process gets killed immediately without affecting other services. / *期待結果*: pids制限により即座に停止。
