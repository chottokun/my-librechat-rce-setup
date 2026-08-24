# RCE（Code Interpreter Sandbox）閉空間・完全隔離検証レポート

## 1. 概要

本ドキュメントは、LibreChat および Code Interpreter サンドボックス実行環境（RCE: Remote Code Execution）が**完全な閉空間（外部インターネットおよび他層から遮断された隔離環境）**として設計・動作していることを実証し、その技術的根拠をまとめたものです。

---

## 2. 閉空間アーキテクチャ（多層防御モデル）

本システムは、コード実行のリスクを局所化するため、以下の **5層の防御壁（Defense in Depth）** を構築しています。

```
[ 社内LAN / クライアント ]
            │ (HTTPS 443)
            ▼
┌──────────────────────────────────────────────────────────┐
│ 1. フロントエンド公開層 (public-frontend ネットワーク)    │
│    - enterprise-nginx (SSL/TLS終端, レートリミット)       │
│    - librechat-api (認証・セッション管理)                 │
│    - librechat-mongodb (会話・ユーザー永続化)            │
└───────────────────────────┬──────────────────────────────┘
                            │ (内部API通信のみ)
                            ▼
┌──────────────────────────────────────────────────────────┐
│ 2. RCE連携層 (rce-backend ネットワーク)                   │
│    - rce-code-api (APIキー認証・キュー配信ゲートウェイ)    │
└───────────────────────────┬──────────────────────────────┘
                            │ (タスク投入)
                            ▼
┌──────────────────────────────────────────────────────────┐
│ 3. 完全隔離層 (rce-isolated: internal=true ネットワーク)  │
│    - rce-redis (非公開タスクキュー)                      │
│    - rce-minio (S3セッション分離ストレージ)              │
│    - rce-code-worker (NsJail Ephemeral Sandbox)          │
│       ├─ Linux Namespaces (PID, NET, MNT, IPC, UTS)      │
│       ├─ cgroups v2 (CPU: 2core, Mem: 2GB, PIDs: 50)     │
│       └─ 外部インターネット接続: 完全遮断 (No Gateway)   │
└──────────────────────────────────────────────────────────┘
```

---

## 3. 隔離性の実機検証結果

Worker コンテナ（`rce-code-worker`）内から各種宛先への通信テストを実施し、閉空間性を実証しました。

### 3.1 実機テスト結果

| 送信元 | 宛先 | 対象 | ポート | 検証結果 | 隔離ステータス |
|:---|:---|:---|:---|:---|:---|
| **Worker** | `8.8.8.8` | 外部パブリックDNS | 53 | **`Network is unreachable`** | ✅ **完全遮断 (Egress Block)** |
| **Worker** | `1.1.1.1` | 外部インターネット | 80 | **`Network is unreachable`** | ✅ **完全遮断 (Egress Block)** |
| **Worker** | `142.250.196.142` | Google 外部IP | 443 | **`Network is unreachable`** | ✅ **完全遮断 (Egress Block)** |
| **Worker** | `librechat-mongodb` | ユーザーDB | 27017 | **`Temporary failure in name resolution`** | ✅ **層間分離 (No Route)** |
| **Worker** | `enterprise-nginx` | リバースプロキシ | 80 | **`Temporary failure in name resolution`** | ✅ **層間分離 (No Route)** |
| **Worker** | `rce-redis` | タスクキュー | 6379 | **`Connected`** | ✅ **許可通信のみ (Internal Only)** |
| **Worker** | `rce-minio` | S3互換ストレージ | 9000 | **`Connected`** | ✅ **許可通信のみ (Internal Only)** |

---

## 4. 閉空間・隔離性の技術的根拠

### 根拠 1: Docker `internal: true` によるネットワーク層遮断 (L3/L4)
- **設定内容 (`docker-compose.yml`)**:
  ```yaml
  networks:
    rce-isolated:
      driver: bridge
      internal: true  # 外部ネットワーク・インターネットへのルーティングを完全遮断
  ```
- **動作原理**:
  - Docker デーモンは `internal: true` が指定されたブリッジネットワークに対し、デフォルトゲートウェイを設定せず、ホストの `iptables` における FORWARD ルールおよび NAT/IPマスカレードを一切生成しません。
  - これにより、コンテナ内のルーティングテーブルに外部向けのデフォルトルートが存在しなくなり、外部IP宛のパケットはカーネルレベルで即時破棄（`[Errno 101] Network is unreachable`）されます。

### 根拠 2: ネットワークブリッジ分離によるフロントエンド層の保護
- `librechat-mongodb` や `enterprise-nginx` は `public-frontend` ネットワークにのみ所属しており、Worker が属する `rce-isolated` とは物理的・論理的に異なるサブネット・ブリッジに収容されています。
- Worker から DB や Nginx への名前解決（DNS）および直接パケット送信は Docker エンジンによって完全にブロックされます。

### 根拠 3: NsJail / Linux Namespaces によるプロセス・OS層の隔離
Worker コンテナ内でコードが実行される際、NsJail による Ephemeral Sandbox（使い捨て分離空間）が生成されます：
- **`CLONE_NEWPID` (PID Namespace)**: サンドボックス内からは自己のプロセスツリーのみが可視化され、ホストや他コンテナのプロセス探索・シグナル送信が不可能。
- **`CLONE_NEWNET` (Network Namespace)**: サンドボックス内部のネットワークスタックをループバック（`127.0.0.1`）のみに限定し、コンテナ外へのソケット通信を無効化。
- **`CLONE_NEWNS` (Mount Namespace)**: ルートファイルシステムを読み取り専用（Read-Only）としてマウントし、書き込みは Ephemeral な `/tmp` 領域のみに制限。
- **`CLONE_NEWUTS` / `CLONE_NEWIPC`**: ホスト名および共有メモリ等の IPC 通信を完全に分離。

### 根拠 4: cgroups v2 によるハードウェアリソース制限
悪意のあるコード（無限ループ、Fork Bomb、大量メモリアロケーション）によるホスト停止・DoS攻撃を防止するため、リソース上限を厳格に制限しています：
- **CPU制限**: 最大 2.0 コア (`WORKER_CPU_LIMIT=2.0`)
- **メモリ制限**: 最大 2048 MB (`WORKER_MEMORY_LIMIT=2048M`)
- **プロセス数制限**: 最大 50 プロセス (`WORKER_PIDS_LIMIT=50`)
- **実行時間制限**: 最大 30 秒 (`MAX_EXECUTION_TIME=30` 超過時は強制 SIGKILL)

### 根拠 5: MinIO によるデータ・セッション分離
- ユーザーからアップロードされたファイルや実行出力は、MinIO オブジェクトストレージ上の固有セッションプレフィックス `/{session_id}/` に限定して保存されます。
- 他セッションのストレージ領域へのアクセスは遮断され、セッション終了後（`SESSION_TTL_HOURS=24`）にデータは自動消滅します。

### 根拠 6: 最小権限原則（Least Privilege）と認証防壁
- Worker は特権を持たない一般ユーザー（`USER 1001`）権限で実行。
- LibreChat と Code API Gateway 間の通信は共有シークレットキー（`LIBRECHAT_CODE_API_KEY`）による Bearer トークン認証で保護。

---

## 5. まとめ

実機テストおよび設定検証の結果、本リポジトリの RCE 実行環境は：
1. **外部インターネットへの通信が 100% 遮断されていること**
2. **MongoDB や Nginx などの管理・フロントエンド層へ直接アクセスできないこと**
3. **カーネル名前空間・cgroups・NsJail により安全な使い捨てサンドボックス内で実行されること**

が証明されており、**エンタープライズ閉域網における完全な閉空間・安全なコード実行環境**が確立されています。
