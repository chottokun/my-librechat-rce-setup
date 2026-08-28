# my-librechat-rce-setup

外部通信を遮断した自閉・完全隔離環境で動作する、個人向けの **LibreChat** および **Code Interpreter (RCE)** サンドボックスの Docker Compose セットアップ構成です。

> **Note**: 本リポジトリは公式の LibreChat プロジェクトとは無関係の個人的なカスタム構成・検証用セットアップです。

---

## クイックスタート

### 1. リポジトリとサブモジュールのクローン
```bash
# サブモジュールを含めてクローン
git clone --recursive <repository-url>
cd my-librechat-rce-setup

# 既に通常の clone を行っている場合:
git submodule update --init --recursive
```

### 2. 設定ファイルの作成
```bash
cp .env.example .env
# 必要に応じて .env 内の API キーやシークレットを編集
vi .env
```

### 3. SSL/TLS 証明書の生成 (開発・テスト用)
```bash
# 自己署名SSL証明書を自動生成 (nginx/certs/ 配下に出力)
bash scripts/generate-self-signed-cert.sh --force
```

### 4. 設定ファイルの構文検証 (任意)
```bash
docker compose config
```

### 5. サービスの起動
```bash
docker compose up -d --build
```

起動後、ブラウザで `https://localhost` (または設定したドメイン) にアクセスします。

---

## 動作確認・テスト

```bash
# 統合 E2E テストスイートの実行 (SSL, API, ストレージ, RCE検証)
bash scripts/test-e2e-ssl.sh

# コンテナ個別ヘルスチェック
bash scripts/health-check.sh

# シェルスクリプトの静的解析 (ShellCheck)
shellcheck scripts/*.sh
```

---

## 主なリファクタリング・セキュリティ適用事項

- **機密情報の完全分離:** `docker-compose.yml` 内の各種パスワード・シークレット・APIキーをテンプレート直書きから環境変数定義（`.env`）へ統一。
- **ヘルスチェック・依存連携:** コンテナ間接続の堅牢化のため、`depends_on` に `condition: service_healthy` と各サービスのヘルスチェックエンドポイントを網羅。
- **スクリプトの堅牢化:** `set -euo pipefail` の徹底、依存コマンド（`docker`, `openssl`, `curl` 等）の事前検証関数、非対話実行時のフォールバックおよび ShellCheck 解析のゼロ警告達成。

---

## 主要構成・ドキュメント

| ファイル / ディレクトリ | 役割 |
|:---|:---|
| [`docker-compose.yml`](docker-compose.yml) | 統合コンテナ定義 (Nginx, API, DB, MinIO, Redis, RCE Gateway/Worker) |
| [`.env.example`](.env.example) | 網羅的な環境変数テンプレート (LLM APIキー、各種設定) |
| [`librechat.yaml`](librechat.yaml) | LibreChat 設定 (各種 LLM エンドポイント、ファイル上限等) |
| [`rce_requirements.txt`](rce_requirements.txt) | RCE Worker サンドボックス用 Python パッケージ一覧 |
| [`docs/deployment-guide.md`](docs/deployment-guide.md) | 閉域網デプロイメント詳細ガイド |
| [`docs/rce-isolation-verification.md`](docs/rce-isolation-verification.md) | RCE 閉空間・完全隔離検証レポート |
| [`docs/troubleshooting-and-architecture-notes.md`](docs/troubleshooting-and-architecture-notes.md) | 構築・運用知見とトラブルシューティング |
| [`docs/security-considerations.md`](docs/security-considerations.md) | セキュリティ考察・リスク評価レポート |

---

## ライセンス・クレジット (License & Acknowledgements)

### 本リポジトリのライセンス
本リポジトリ内の設定ファイル、スクリプト、ドキュメントは [MIT License](LICENSE) のもとで公開・利用可能です（自由に変更・利用いただけますが、無保証です）。

### 関連・利用コンポーネントのライセンス帰属
本セットアップで利用・連携している主要なオープンソースソフトウェアの著作権・ライセンスは各原著作者に帰属します。

- **[LibreChat](https://github.com/danny-avila/LibreChat)**: MIT License (Copyright (c) Danny Avila)
- **[Code Interpreter Sandbox / Worker](https://github.com/LibreChat-AI/code-interpreter)**: Apache License 2.0 (Copyright (c) LibreChat-AI)
- **[NsJail](https://github.com/google/nsjail)**: Apache License 2.0 (Copyright (c) Google LLC)
- **[MinIO](https://github.com/minio/minio)**: GNU AGPLv3 (Copyright (c) MinIO, Inc.)
- **[Redis](https://redis.io/) / [MongoDB](https://www.mongodb.com/) / [Nginx](https://nginx.org/)**: 各プロジェクトのライセンス条項に準拠
- **Google Noto Fonts (`fonts-noto-cjk`)**: SIL Open Font License 1.1 に準拠

### 免責事項 (Disclaimer)
- 本リポジトリは個人の検証およびカスタム運用を目的とした構成セットであり、公式の LibreChat や各コンポーネントの開発元とは一切関係ありません。
- コード実行サンドボックスの隔離性や安全性については設計・テストを行っていますが、本構成の利用によって生じた直接的・間接的な損害やトラブルについて、作成者は一切の責任を負いません。運用環境のセキュリティ要件に応じて自己責任でご利用ください。

