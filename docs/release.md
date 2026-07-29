# 发布流程

## 持续集成

每次推送和 Pull Request 由 GitHub Actions 在隔离数据库中执行：

1. 安装 Node 依赖。
2. 执行 `swift build`。
3. 执行 `swift test`。
4. 验证打包脚本能够生成完整 App。

## 正式发布

创建 `vX.Y.Z` 标签后，发布工作流应：

1. Release 编译并组装 `ReadBoard.app`。
2. 使用 Developer ID Application 证书和 Hardened Runtime 签名。
3. 打包为 ZIP 或 DMG。
4. 提交 Apple 公证并装订票据。
5. 使用 `codesign`、`spctl` 验证最终产物。
6. 创建 GitHub Release 并上传安装包。

签名证书、证书密码和公证凭证只能放入 GitHub Actions Secrets，不能写入源码、脚本或配置文件。

发布工作流需要配置以下仓库 Secrets：

- `DEVELOPER_ID_CERTIFICATE_BASE64`：Developer ID Application 的 P12 文件经 Base64 编码后的内容。
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`：导出 P12 时设置的密码。
- `APPLE_API_KEY_ID`：App Store Connect 团队 API Key ID。
- `APPLE_API_ISSUER_ID`：App Store Connect Issuer ID。
- `APPLE_API_PRIVATE_KEY_BASE64`：团队 API Key 的 P8 文件经 Base64 编码后的内容。

必须使用团队 API Key；个人 API Key 不能调用 `notarytool`。

当前机器只有 Apple Development 证书；在取得 Developer ID Application 证书前，发布工作流只做结构准备，不创建面向用户的未签名版本。
