# p-tools

个人工具仓库。后续独立工具统一放在这里维护，每个工具有自己的目录和说明。

## 工具目录

| 分类 | 工具 | 用途 |
| --- | --- | --- |
| 网络 | [Cloudflare DDNS](tools/network/cloudflare-ddns/) | 位置参数配置、固定记录 ID、自动安装 cron |

## 文件夹规划

```text
p-tools/
├── README.md
├── AGENTS.md
└── tools/
    └── network/
        └── cloudflare-ddns/
            ├── README.md
            └── ddns.sh
```

统一采用 `tools/<分类>/<工具名>/`。分类按需要新增，例如 `system`（系统维护）、`backup`（备份）、`database`（数据库）、`development`（开发辅助）；没有工具时不创建空目录。分类和工具名使用小写英文及连字符。

每个工具的 README 应包含平台要求、依赖、执行示例、参数、产生的文件和清理方法。新增工具时更新上面的目录表。可复用的独立工具放入本仓库，业务项目专用脚本留在原项目。

不要提交 Token、密码、实际运行配置、日志或其他私密数据。
