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

## 9. 日本語ファイル名の文字化け問題（上流PRマージにより根本解決済み）

### 9.1 現象
日本語ファイル名（例: `Github_Code_Reviewer_日本語_-saved.md`）をアップロードした際、Code Interpreter サンドボックス内で `Github_Code_Reviewer_æ—¥æœ¬èªž_-saved.md` のように文字化けする現象がありました。

### 9.2 原因
- `code-interpreter` 側のマルチパート解析モジュール `busboy` において、デフォルト文字コード（`defParamCharset` / `defCharset`）が未指定だったため、HTTPの歴史的仕様に従って `Latin-1 (ISO-8859-1)` としてUTF-8バイト列がパースされていました。
- `file-server.ts` 側には `defCharset: 'utf8', defParamCharset: 'utf8'` が設定されているのに対し、APIゲートウェイ側の `router.ts` にのみ抜け落ちていたという実装の非対称性に起因していました。

### 9.3 上流への PR と解決（PR #65）
公式リポジトリ（`LibreChat-AI/code-interpreter`）へ本件の修正 PR（[PR #65](https://github.com/LibreChat-AI/code-interpreter/pull/65)）を提出し、無事に上流 `main` にマージされました。

これにより、以前適用していた `docker-compose.yml` での `entrypoint` 起動時動的パッチは不要となり削除されました。サブモジュールを最新の公式コードに追従させるだけで、日本語等の非ASCIIファイル名がネイティブに正しく処理されます。

---

## 10. サンドボックス Runner の完全自己完結型（Baked）設計とアーキテクチャ考察

### 10.1 背景と課題（`KVM_ENABLED=false` 時の unhealthy エラー）
`KVM_ENABLED=false`（Direct NsJail モード）でサンドボックスを起動した際、コンテナ起動時に `/pkgs` が空となり、Python や Node ランタイムが見つからず `sandbox-runner is unhealthy` エラーが発生していました。

本家のコードおよびコミット履歴（コミット `4b72e9d` / PR #32）を調査したところ、以下の設計背景が判明しました：
- **KVM モード (`KVM_ENABLED=true`)**: MicroVM（libkrun）の共有フォルダ（virtio-fs）で多数のファイルを読み込むと FD（ファイルディスクリプタ）枯渇を引き起こすため、ext4 ブロックイメージ（`/sandbox-rootfs.img`）の中に `/pkgs` をすべて焼き込む **Block-root package delivery（Baked）** が導入された。
- **Direct NsJail モード (`KVM_ENABLED=false`)**: ホストの Linux Namespace を直接使うため virtio-fs の FD 枯渇問題は発生しない。そのため、Kubernetes の PVC 共有運用およびローカル開発でのビルド時間短縮を目的として、ホスト/PVC からの動的マウント（`/host-packages`）がそのまま仕様として維持されていた。

### 10.2 検討された3つのアプローチと評価

| アプローチ | 概要 | 評価と課題 |
| :--- | :--- | :--- |
| **案 1: 本家標準の KVM MicroVM に移行** | `KVM_ENABLED=true` にし、本家の `sandbox-runner-true` をそのまま使用 | ホストマシンに `/dev/kvm` があれば最高強度の MicroVM 隔離が得られる。しかし、OS とパッケージが ext4 ディスクイメージに固定されているため、**サブモジュールを無修正に保ちつつ独自ライブラリ（`japanize-matplotlib` 等）や日本語フォントを追加することが極めて困難**。 |
| **案 2: K8s / 本家仕様に準拠した Volume 初期化運用** | `package-init` コンテナを起動時に実行し、Docker 名前付きボリュームに `/pkgs` を展開 | 本家の PVC 運用思想には合致するが、**初回起動に 15〜20 分の待機時間が発生**する。また、日本語フォント（OS領域）の問題はボリュームマウントだけでは解決できない。 |
| **案 3: 親リポジトリ管理の Baked イメージ (採用)** | 親リポジトリに [`Dockerfile.sandbox-runner`](../Dockerfile.sandbox-runner) を配置し、ビルド時に完全自己完結させる | **最も実用的で堅牢。** 日本語フォント（`fonts-dejavu`, `fonts-liberation` 等）および `rce_requirements.txt`（`japanize-matplotlib` 等）を含めて 1 つの Docker イメージとして完結。初回起動は即時完了し、サブモジュール `code-interpreter` は 100% clean を維持できる。 |

### 10.3 本リポジトリでの設計決定
上流への性急な PR や Issue 作成は行わず、本リポジトリでは **案 3（親リポジトリ管理の `Dockerfile.sandbox-runner` による完全自己完結型 Baked イメージ）を正式な標準構成** として採用・定着させます。

これにより：
1. **高い可搬性と即時起動**: ホスト側のディレクトリ事前作成やマウント権限トラブル、初回起動時の十数分に及ぶパッケージ初期化待ちが一切ありません。
2. **完全な日本語環境サポート**: `japanize-matplotlib` による日本語グラフ描画や日本語フォントがコンテナ単体で確実に機能します。
3. **上流サブモジュールの保守性**: `code-interpreter` 側のワーキングツリーを一切汚さず、常に上流最新コードに安全に追従できます。

