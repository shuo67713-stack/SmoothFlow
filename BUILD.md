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

## GitHub Release 建议

- Tag：`v5.0.4`
- Release title：`SmoothFlow v5.0.4 — Open Source Preparation`
- 上传 `SmoothFlow_5.0.4_OPD2513.zip` 和对应 `.sha256` 文件。
- Release notes 使用 `CHANGELOG.md` 中的 v5.0.4 条目，并明确当前没有实机性能基准。
