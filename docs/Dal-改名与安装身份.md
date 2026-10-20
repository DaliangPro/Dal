# Dal 改名与安装身份

产品、源码模块、可执行文件、正式安装包统一使用 **Dal**，GitHub 仓库为 `DaliangPro/Dal`，正式安装位置是 `/Applications/Dal.app`。

## 兼容身份

Bundle ID `pro.daliang.muse`、原 `Muse Local` 签名证书、`~/Library/Application Support/Muse/`、钥匙串服务与已有设置键保持不变。这些是旧用户的升级身份，不是产品展示名称。改动它们可能导致已有词库、历史、凭据或权限失联，因此本次不迁移用户数据。既有本地服务协议字段也保留兼容。

## 安装与升级

- 使用 `bash scripts/deploy.sh` 构建并安装；开发启动入口同样调用这一事务安装流程。
- 先构建 Dal 候选，验证 Bundle ID、名称、可执行文件、严格签名及维护者证书指纹，再停止自己的精确路径进程。构建失败时原应用继续工作。
- 目标缺少身份、属于其他应用、签名错误或路径含非系统符号链接时一律停止。不得通过覆盖 `APP_BUNDLE_ID` 绕过。
- 旧名迁移仅检查 `/Applications/Muse.app` 与 `/Applications/Muse 输入法.app`；只有标识为 `pro.daliang.muse` 且符合原签名的包才迁移。Meta Muse（包括 `com.meta.endo`、`com.facebook.hatch`）及任何其他身份均跳过，不退出、不移动、不注销。
.app 默认构建输出位于 `dist/package.noindex/Dal.app`；DMG 构建结束后也会禁用临时候选。

- 旧包归档为 `.app.disabled`，避免启动台再次收录。安装失败会尝试恢复旧包；记录与候选留在隔离目录供排障。
- 下载更新必须匹配 Dal 制品名、应用身份、签名团队、版本与摘要；拒绝把产品名改回旧名。现有自动更新仍关闭，不因改名擅自开启。
- 公共手动分发仍使用原本机签名。改用 Developer ID 证书时须显式更新受信任身份并测试，不能仅接受任意有效签名。

## 验证

`python3 -m unittest discover -s scripts -p 'test_app_identity.py' -v` 在隔离假应用上验证 Meta/未知/缺失身份、符号链接、错签名、旧名称与复制失败保护；Swift 更新器回归另测 Meta 目标无文件改动与无启动副作用。测试不会操作实际 Meta 应用。
