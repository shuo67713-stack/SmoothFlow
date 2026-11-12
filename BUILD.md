# 构建与发布

## 环境

- POSIX Shell（Android `sh` / Linux `/bin/sh`）
- `zip`、`sha256sum`
- 推荐先运行仓库中的隔离自测

## 本地构建

在仓库根目录运行：

```sh
sh scripts/package.sh
```

默认在 `dist/` 生成安装 ZIP 和 SHA-256 校验文件。也可以指定输出目录：

```sh
sh scripts/package.sh /path/to/output
```

脚本只打包模块运行所需文件，不把 `.git`、GitHub 工作流、酷安文案或发布清单塞进安装包。

## 发布前检查

1. 执行 `sh tests/selftest.sh`，记录完整输出。
2. 执行 `sh -n` 检查所有运行脚本。
3. 检查 `module.prop` 的版本、版本号和作者字段。
4. 检查 ZIP 根目录直接包含 `module.prop`、`service.sh`、`post-fs-data.sh`、`uninstall.sh`。
5. 检查脚本执行权限；不要在重新压缩时丢失 `0755` 权限。
6. 计算 SHA-256，并在 GitHub Release 和酷安帖子中同时提供。
7. 完成目标设备安装、升级、重启、模式切换、恢复和卸载实测后，再将“实机验证”状态改为通过。

## 5.0.6-rc1 候选版发布建议

- Tag：`v5.0.6-rc1`（候选版，不是正式版）
- Release title：`SmoothFlow v5.0.6-rc1 — Candidate`
- 上传 `SmoothFlow_5.0.6-rc1_OPD2513.zip` 和对应 `.sha256` 文件。
- 同时附上 `VERSION_5.0.6-rc1_BASELINE.md`，明确本候选版从 5.0.4 Patch3 ReviewFix 演进，尚未核对 5.0.5 正式源码差异。
- 未完成 OPD2513 真机安装、启停、模式切换、恢复和卸载回归前，不得标记为正式发布或宣称性能提升。
