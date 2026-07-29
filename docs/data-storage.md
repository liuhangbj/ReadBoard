# 本地数据约定

源码仓库不保存任何用户内容或运行时产物。

## Application Support

```text
~/Library/Application Support/ReadBoard/
├── readboard.db
├── readboard.db-wal
├── readboard.db-shm
├── secrets.json
├── backups/
├── trash/
└── models/
```

- `readboard.db*`：SQLite 主库及 WAL 文件。
- `secrets.json`：本机加密的服务凭证。
- `backups`：数据库滚动热备。
- `trash`：清理内容前生成的可恢复快照。
- `models`：按需下载的 Whisper 模型。

## 其他目录

```text
~/Library/Caches/ReadBoard/    可安全重建的缓存
~/Library/Logs/ReadBoard/      运行日志
~/Applications/ReadBoard.app   本地开发部署产物
```

测试和维护工具通过 `READBOARD_DB` 或 `--db` 使用显式数据库路径，禁止默认访问源码仓库中的数据库。
