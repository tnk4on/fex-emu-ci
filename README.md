# FEX-Emu CI Tests

GitHub Actions + AWS EC2 Graviton (aarch64) で FEX-Emu の x86_64 エミュレーション機能をテストする。

## アーキテクチャ

```
GitHub Actions (ubuntu-latest)
  → AWS EC2 Graviton (t4g.small, Fedora aarch64)
    → Podman build (Containerfile.test: static-pie FEXInterpreter)
      → Podman run --privileged (テスト実行)
```

## テスト内容

### Tier 1: インストール検証
- aarch64 アーキテクチャ確認
- FEXInterpreter static-pie バイナリ検証
- RootFS 確認
- x86_64 直接実行 (`FEXInterpreter /rootfs/usr/bin/uname -m`)

### Tier 2: binfmt_misc + Podman
- binfmt_misc 登録
- `podman run --platform linux/amd64` で x86_64 コンテナ実行
- ARM64 リグレッションテスト
- 安定性テスト (3回連続)

## FEXInterpreter ビルド

`Containerfile.test` は [podman-machine-os の Containerfile.COREOS](https://github.com/containers/podman-machine-os) と
同一の設定で FEXInterpreter を static-pie ビルドする。

## 使い方

### GitHub Actions (自動)
```bash
# push / PR で自動実行
# 手動実行
gh workflow run test-fex.yml
```

### ローカル (Fedora aarch64)
```bash
podman build -t fex-test -f Containerfile.test .
podman run --rm --privileged fex-test
```

## AWS コスト見積

- インスタンス: `t4g.small` (2vCPU, 2GB, $0.0168/h)
- 実行時間: ~15分
- コスト: ~$0.005/回
