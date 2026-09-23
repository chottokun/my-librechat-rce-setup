---
type: architecture
title: CI/CD Workflow Design / CI/CDワークフロー設計
description: Design and rationale for the GitHub Actions CI workflow for this repository.
generated: false
status: active
tags: [ci, github-actions, architecture]
---

# CI/CD Workflow Design / CI/CDワークフロー設計

This document outlines the design and rationale behind the GitHub Actions Continuous Integration (CI) workflow for this repository.
本文書は、本リポジトリにおけるGitHub Actionsによる継続的インテグレーション(CI)ワークフローの設計と意図を説明します。

## CI Scope & Realistic Tiering / CIの範囲と現実的な階層化

The CI workflow is divided into two tiers to balance fast feedback on pull requests with thorough integration validation on the main branch.
CIワークフローは、プルリクエスト時の迅速なフィードバックと、メインブランチでの徹底的な統合検証のバランスを取るため、2つの階層に分かれています。

### Tier 1: Fast Feedback (Validation) / 高速フィードバック（検証）

This job runs on all PRs and pushes to `main`. It focuses on quick, static checks.
このジョブはすべてのPRと`main`へのプッシュで実行され、迅速な静的チェックに焦点を当てています。

* **Shell Script Validation / シェルスクリプト検証**: Uses ShellCheck to ensure `scripts/*.sh` adhere to strict error handling and best practices (`set -euo pipefail`).
* **Docker Compose Config / Docker Compose設定検証**: Validates the `docker-compose.yml` syntax using a generated `.env` file from `.env.example`.
* **Repository Integrity / リポジトリ整合性**: Checks that submodules (e.g., `code-interpreter`) are correctly initialized and that no sensitive information is leaked.

### Tier 2: Build & Integration Validation / ビルドおよび統合検証

This job runs only on pushes to `main` or manual triggers (`workflow_dispatch`), and depends on Tier 1 passing. It performs heavy builds and integration tests.
このジョブは`main`へのプッシュまたは手動トリガー時のみ実行され、Tier 1の成功に依存します。負荷の高いビルドと統合テストを実行します。

* **Build Verification / ビルド検証**: Builds `Dockerfile.sandbox-runner` and related containers using Docker Buildx to ensure there are no build errors. Layer caching is leveraged where possible.
* **Environment Constraints / 環境制約**: Given GitHub Actions standard Ubuntu runners do not provide nested `/dev/kvm` by default, the workflow configures the environment to use `KVM_ENABLED=false` (Direct NsJail mode).
* **Integration Testing / 統合テスト**: Boots the Docker Compose stack and executes `scripts/test-e2e-ssl.sh` to verify end-to-end functionality within the constraints of the standard runner.

## Principles / 原則

* **Robustness / 堅牢性**: Simple, maintainable configuration avoiding unnecessary fragility.
* **Security / セキュリティ**: Uses `.env.example` and self-signed certificates; no real secrets are exposed or required.
* **Bilingual / バイリンガル**: Comments and documentation are in English and Japanese.
