---
type: concept
title: RCE Isolation Verification
description: Technical report verifying the isolation of the Code Interpreter Sandbox (RCE).
generated: false
status: active
tags: [security, isolation, rce, sandbox]
---

# RCE Isolation Verification / RCE閉空間・隔離検証レポート

## 1. Overview / 概要

This document demonstrates and provides the technical basis that the LibreChat and Code Interpreter Sandbox (RCE) environment operates as a **completely closed space (an isolated environment cut off from the external internet and other layers)**.
本ドキュメントは、LibreChat および Code Interpreter サンドボックス実行環境（RCE）が**完全な閉空間（外部インターネットおよび他層から遮断された隔離環境）**として設計・動作していることを実証し、その技術的根拠をまとめたものです。

---

## 2. Closed Space Architecture (Defense in Depth) / 閉空間アーキテクチャ（多層防御モデル）

The system constructs five layers of defense walls to localize code execution risks:
本システムは、コード実行のリスクを局所化するため、以下の5層の防御壁を構築しています。

```
[ Internal LAN / クライアント ]
            │ (HTTPS 443)
            ▼
┌──────────────────────────────────────────────────────────┐
│ 1. Public Frontend Layer / フロントエンド公開層           │
│    - enterprise-nginx (SSL/TLS, Rate Limit)              │
│    - librechat-api (Auth/Session)                        │
│    - librechat-mongodb (DB)                              │
└───────────────────────────┬──────────────────────────────┘
                            │ (Internal API only)
                            ▼
┌──────────────────────────────────────────────────────────┐
│ 2. RCE Gateway Layer / RCE連携層                          │
│    - rce-code-api (API Key Auth, Task Gateway)           │
└───────────────────────────┬──────────────────────────────┘
                            │ (Task Queue)
                            ▼
┌──────────────────────────────────────────────────────────┐
│ 3. Isolated Layer / 完全隔離層 (internal=true)            │
│    - rce-redis (Task Queue)                              │
│    - rce-minio (S3 Session Storage)                      │
│    - rce-code-worker (NsJail Ephemeral Sandbox)          │
│       ├─ Linux Namespaces (PID, NET, MNT, IPC, UTS)      │
│       ├─ cgroups v2 (CPU: 2core, Mem: 2GB, PIDs: 50)     │
│       └─ Egress: Blocked / 外部通信完全遮断              │
└──────────────────────────────────────────────────────────┘
```

---

## 3. Isolation Test Results / 隔離性の実機検証結果

We conducted communication tests from within the Worker container to verify the closed environment.
Worker コンテナ内から各種宛先への通信テストを実施し、閉空間性を実証しました。

| Source / 送信元 | Destination / 宛先 | Target / 対象 | Port | Result / 検証結果 | Status / 隔離ステータス |
|:---|:---|:---|:---|:---|:---|
| **Worker** | `8.8.8.8` | Public DNS | 53 | **`Network is unreachable`** | ✅ **Egress Blocked / 完全遮断** |
| **Worker** | `1.1.1.1` | Internet | 80 | **`Network is unreachable`** | ✅ **Egress Blocked / 完全遮断** |
| **Worker** | `example.com` | External Web | 443 | **`Network is unreachable`** | ✅ **Egress Blocked / 完全遮断** |
| **Worker** | `librechat-mongodb` | User DB | 27017 | **`Temporary failure in name resolution`** | ✅ **Layer Isolated / 層間分離** |
| **Worker** | `enterprise-nginx` | Proxy | 80 | **`Temporary failure in name resolution`** | ✅ **Layer Isolated / 層間分離** |
| **Worker** | `rce-redis` | Task Queue | 6379 | **`Connected`** | ✅ **Internal Only / 許可通信のみ** |
| **Worker** | `rce-minio` | S3 Storage | 9000 | **`Connected`** | ✅ **Internal Only / 許可通信のみ** |

---

## 4. Technical Basis for Isolation / 閉空間・隔離性の技術的根拠

### Basis 1: Network Layer Blocking via Docker `internal: true` / ネットワーク層遮断
- Setting `internal: true` prevents Docker from assigning a default gateway, completely discarding any external routing at the kernel level.
- Docker デーモンは `internal: true` が指定されたネットワークに対し、デフォルトゲートウェイを設定せず、外部宛のパケットはカーネルレベルで即時破棄されます。

### Basis 2: Bridge Separation Protecting Frontend / ネットワークブリッジ分離
- The worker cannot resolve or route to frontend containers (`mongodb`, `nginx`) as they exist on different bridge networks.
- Worker から DB や Nginx への名前解決および直接通信は Docker エンジンによって完全にブロックされます。

### Basis 3: Process/OS Isolation via NsJail & Linux Namespaces / プロセス・OS層の隔離
- **PID Namespace**: Only the sandbox process tree is visible. (自己プロセスのみ可視化)
- **Network Namespace**: Loopback only (`127.0.0.1`). (ループバックのみ)
- **Mount Namespace**: Root filesystem is Read-Only, except for an ephemeral `/tmp` space. (ルートFSは読み取り専用)

### Basis 4: Hardware Limitations via cgroups v2 / ハードウェアリソース制限
- **CPU**: Max 2.0 cores.
- **Memory**: Max 2048 MB.
- **PIDs**: Max 50 processes.
- **Time Limits**: Hard SIGKILL after 30 seconds.
- 悪意のあるコードによるホスト停止を防止するため、CPU・メモリ・プロセス数・実行時間を厳格に制限しています。

### Basis 5: Storage Separation via MinIO / MinIO によるデータ分離
- Files are isolated strictly under `/{session_id}/` prefixes.
- アップロードされたファイルや実行出力は固有セッションプレフィックスに限定保存されます。

### Basis 6: Least Privilege Principle / 最小権限原則
- The Worker runs as a non-privileged user (`USER 1001`).
- API communications are protected by a shared secret (`<API_KEY>`).
- Workerは一般ユーザー権限で実行され、API通信はシークレットキーで保護されます。

---

## 5. Summary / まとめ

Testing and configuration review proves that:
1. External internet access is 100% blocked.
2. Direct access to the frontend layer (MongoDB/Nginx) is blocked.
3. Code runs within a secure, ephemeral namespace/cgroup sandbox.
This establishes a perfectly closed, highly secure Code Interpreter environment.

実機テストおよび設定検証の結果、本RCE実行環境は外部通信の完全遮断、フロントエンドへのアクセス不可、および安全な使い捨てサンドボックス内での実行が証明されており、完全な閉空間・安全なコード実行環境が確立されています。
