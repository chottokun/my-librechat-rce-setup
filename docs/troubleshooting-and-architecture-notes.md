# LibreChat & Code Interpreter サンドボックス 構築・運用知見とトラブルシューティング

本ドキュメントは、閉域網環境における **LibreChat** および **Code Interpreter (RCE) サンドボックス** の構築・実用化にあたって得られた技術的知見、設定上の注意点、およびトラブルシューティングの記録です。

---

## 1. ドメイン設定と SSL/TLS 証明書

### 1.1 ドメイン名の一致原則
- `.env` の `DOMAIN`、`nginx/nginx.conf` の `server_name`、および SSL 証明書の **SAN（Subject Alternative Name）** は必ず一致させる必要があります。
- **設定例**:
  - `.env`: `DOMAIN=librechat.example.com`, `DOMAIN_CLIENT=https://librechat.example.com`, `DOMAIN_SERVER=https://librechat.example.com`
  - `nginx/nginx.conf`: `server_name librechat.example.com localhost;`
  - 証明書生成: `bash scripts/generate-self-signed-cert.sh --force librechat.example.com`

---

## 2. 外部 LLM API（さくらインターネット AI / OpenAI互換）連携の知見

### 2.1 `librechat.yaml` における環境変数展開の仕様
- **注意点**: LibreChat の YAML パーサーは `${VAR}` の単純な変数置換のみをサポートしています。Bash のような `${VAR:-default}` 形式（デフォルト値指定）は解釈されず、文字列リテラルとしてそのまま渡されてしまいます。
- **対策**: デフォルト値は `.env` 側で設定するか、YAML 内には `${VAR}` のみを記述します。

### 2.2 さくらAI API のモデル指定と `fetch: true`
- さくらの AI 高火力 API では、モデル名にプレフィックスが含まれます（例: `preview/Qwen3.6-35B-A3B`, `preview/Kimi-K2.7-Code`）。
- `models.fetch: true` を設定することで、さくらの API（`/v1/models`）から利用可能な最新モデル一覧を自動取得し、UI ドロップダウンに反映できます。
- **推奨設定 (`librechat.yaml`)**:
  ```yaml
  endpoints:
    custom:
      - name: "Sakura-AI"
        apiKey: "${EXTERNAL_API_KEY}"
        baseURL: "${EXTERNAL_API_URL}"
        models:
          default:
            - "preview/Qwen3.6-35B-A3B"
            - "preview/Kimi-K2.7-Code"
            - "preview/Qwen3-VL-30B-A3B-Instruct"
          fetch: true
        titleConvo: true
        titleModel: "preview/Qwen3.6-35B-A3B"
        modelDisplayLabel: "さくらAI"
  ```

---

## 3. ユーザー登録と認証設定

### 3.1 新規登録・サインアップ画面の有効化
初期状態でユーザー登録画面が表示されない、またはログインできない場合は、`docker-compose.yml` の `api` サービスに以下の環境変数が正しく渡されているか確認します：
- `ALLOW_REGISTRATION=true`: 新規ユーザー登録を許可
- `ALLOW_EMAIL_LOGIN=true`: メール/パスワード認証を有効化
- `ALLOW_UNVERIFIED_EMAIL_LOGIN=true`: 閉域網等でメール送信サーバーがない環境での即時ログインを許可

---

## 4. Code Interpreter (RCE) 連携のアーキテクチャとトラブルシューティング

### 4.1 ポート番号の不一致（ECONNREFUSED）
- **現象**: `connect ECONNREFUSED 172.xx.0.x:7000`
- **原因**: `code-api` イメージ（Uvicorn）はデフォルトで **ポート 8000** でリッスンしています。
- **解決策**:
  - `docker-compose.yml` および `.env` において `LIBRECHAT_CODE_BASEURL=http://code-api:8000`、`CODE_API_PORT=8000` を設定。

### 4.2 内部通信時の 401 認証エラー（Invalid API Key）
- **現象**: `CodeAPI request failed: POST http://code-api:8000/exec returned 401, body: {"detail":"Invalid API Key"}`
- **原因**:
  - LibreChat の `bash_tool` は、同一 Docker ネットワーク内の内部通信として認証ヘッダーを付与せずにリクエストを送信する仕様です。
  - `code-api` 側で認証スキップを有効にする環境変数名は `DISABLE_AUTH` ではなく **`DISABLE_CODE_API_AUTH`** でした。
- **解決策**:
  - `docker-compose.yml` の `code-api` サービス環境変数に **`DISABLE_CODE_API_AUTH=true`** を設定。
  - これにより、閉域隔離ネットワーク（`rce-backend` / `rce-isolated`）内からのリクエストを安全に即時実行可能となります。

---

## 5. セッション分離・ファイル混在防止（マルチテナント隔離）の実証知見

### 5.1 隔離のメカニズム
- **一時ワークスペース分離**:
  各コード実行セッションごとに固有の UUID ディレクトリ（`/tmp/{session_uuid}/`）が動的生成されます。
- **Linux Mount Namespace & NsJail**:
  サンドボックスプロセスは自身のセッションディレクトリのみがマウントされた状態で動作し、他セッションやホストのディレクトリへの横断アクセスは OS レベルで遮断（`FileNotFoundError`）されます。
- **MinIO オブジェクトストレージ分離**:
  アップロードファイルおよび生成ファイルは、セッションIDプレフィックス `/{session_id}/...` 配下に分離保存されます。

### 5.2 実機検証結果
- セッション A で作成した機密ファイルは、セッション B からのディレクトリ走査（`os.listdir`）および直接読取（`open`）の両方において完全に隔離され、混在が発生しないことを実証済みです。

---

## 6. クイック運用チートシート

```bash
# 1. サービスの再起動と最新ビルド適用
docker compose up -d --build

# 2. SSL証明書の再発行（ドメイン変更時）
bash scripts/generate-self-signed-cert.sh --force <DOMAIN_NAME>
docker compose restart nginx

# 3. 統合E2Eテストスイート（SSL・API・ストレージ・RCE自動検証）
bash scripts/test-e2e-ssl.sh

# 4. 個別ヘルスチェック確認
bash scripts/health-check.sh
```

---

## 7. KVM 非対応環境（クラウド VM / VPS / ネスト仮想化なし環境）での運用

### 7.1 発生するエラー
`/dev/kvm` が存在しない環境で起動すると、以下のエラーが発生します：
```text
Error response from daemon: error gathering device information: cannot find device "/dev/kvm"
```

### 7.2 解決手順（NsJail 直接モードへの切り替え）
1. **`.env` の設定変更**:
   ```env
   KVM_ENABLED=false
   ```
2. **`docker-compose.yml` の調整**:
   `sandbox-runner` サービスの `devices` をコメントアウトし、`privileged: true` を付与します。
   ```yaml
   sandbox-runner:
     privileged: true  # MicroVMの代わりにコンテナ内NsJailでNamespaceを作成するために付与
     # devices:
     #   - ${KVM_DEVICE_PATH:-/dev/kvm}:/dev/kvm
     environment:
       - KVM_ENABLED=false
   ```
3. **コンテナの再起動**:
   ```bash
   docker compose up -d --build sandbox-runner
   ```

---

## 8. LibreChat 連携時の BaseURL パス仕様 (`/v1`)

### 8.1 発生した事象 (404 Not Found)
LibreChat から Code Interpreter へのファイルアップロード時に `Error uploading code environment file: Request failed with status code 404` が発生。

### 8.2 原因と対策
- LibreChat は `${LIBRECHAT_CODE_BASEURL}/upload` 形式でリクエストを送信しますが、`code-api` は全エンドポイントを `/v1` 配下で公開しています。
- **対策**: `.env` および `docker-compose.yml` において `LIBRECHAT_CODE_BASEURL=http://code-api:3112/v1` と末尾に `/v1` を含める設定とします。

---

## 9. 日本語ファイル名の文字化け問題と一時的回避策 (Docker 起動時パッチ)

### 9.1 現象
日本語ファイル名（例: `Github_Code_Reviewer_日本語_-saved.md`）をアップロードした際、Code Interpreter サンドボックス内で `Github_Code_Reviewer_æ—¥æœ¬èªž_-saved.md` のように文字化けする。

### 9.2 原因
- `code-interpreter` 側のマルチパート解析モジュール `busboy` において、デフォルト文字コード（`defParamCharset` / `defCharset`）が未指定だったため、HTTPの歴史的仕様に従って `Latin-1 (ISO-8859-1)` としてUTF-8バイト列がパースされていました。
- `file-server.ts` 側には `defCharset: 'utf8', defParamCharset: 'utf8'` が設定されているのに対し、APIゲートウェイ側の `router.ts` にのみ抜け落ちていたという実装の非対称性に起因します。

### 9.3 外部リポジトリを変更しない一時的回避策 (選択肢1: Docker 起動時パッチ)
外部コード（`code-interpreter`）の Git ワークツリーをクリーンな状態に保つため、`docker-compose.yml` の `entrypoint` にてコンテナ起動時に自動で UTF-8 設定を注入する方式を採用しています。

```yaml
  code-api:
    # 外部リポジトリを変更せず、起動時にUTF-8ファイル名対応パッチ（defCharset/defParamCharset）を注入
    entrypoint: >
      /bin/sh -c "
      bun -e \"
        const fs = require('fs');
        const file = '/app/.build-api/api-server.js';
        if (fs.existsSync(file)) {
          let code = fs.readFileSync(file, 'utf8');
          code = code.replace(/(headers:\w+\.headers),/g, '\\$1,defCharset:\\\"utf8\\\",defParamCharset:\\\"utf8\\\",');
          fs.writeFileSync(file, code);
        }
      \";
      exec bun run .build-api/api-server.js
      "
```

### 9.4 上流（公式リポジトリ）への Issue 報告・改善検討
本件は `file-server.ts` と `router.ts` 間の実装齟齬（`file-server.ts` には `defCharset: 'utf8'` が設定されているが `router.ts` では未指定）によるものであるため、将来的には公式リポジトリ（上流）へ **GitHub Issue** として現象と原因を報告し、メンテナーと協議の上で根本修正を取り込んでもらう方向で検討します。

