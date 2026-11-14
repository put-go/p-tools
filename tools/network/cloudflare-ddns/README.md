# Cloudflare DDNS

适用于 Debian/Ubuntu，使用 Bash 4+、root 权限及 apt-get。安装时自动安装 curl、jq、cron、util-linux、ca-certificates，保存配置并立即更新一次 DNS。

## 执行

```bash
git clone https://github.com/put-go/p-tools.git
cd p-tools/tools/network/cloudflare-ddns
sudo bash ddns.sh 'YOUR_CF_TOKEN' 'YOUR_ZONE_ID' 'ddns.example.com' 1 0 1 true false 60
```

前三个参数必填，其余可省略：

```bash
sudo bash ddns.sh 'YOUR_CF_TOKEN' 'YOUR_ZONE_ID' 'ddns.example.com'
```

| 位置 | 参数 | 默认值 | 说明 |
| --- | --- | --- | --- |
| 1 | TOKEN | 必填 | 目标 Zone 的 DNS 编辑权限 |
| 2 | ZONE_ID | 必填 | 32 位十六进制 Zone ID |
| 3 | DNS_NAME | 必填 | 完整域名 |
| 4 | A_INDEX | 1 | IPv4 记录序号，0 禁用 |
| 5 | AAAA_INDEX | 0 | IPv6 记录序号，0 禁用 |
| 6 | INTERVAL | 1 | 分钟，可选 1/2/5/10/15/30 |
| 7 | AUTO_CREATE | true | 没有匹配记录时自动创建，仅支持序号 1 |
| 8 | PROXIED | false | 新记录是否开启代理 |
| 9 | TTL | 60 | 新记录 TTL：1 或 60–86400 秒；代理开启时固定为 1 |

至少启用一种 IP 类型。布尔值使用 true/false。记录先按创建时间升序、再按 ID 排序，首次选择后固定 ID；记录被删除时不会自动切换到其他记录。已有记录只修改 IP，保留原 TTL 和代理设置。未取得有效公网 IP 时跳过对应地址类型并记录 WARN。

命令行参数可能留在 Shell 历史及短暂出现在进程参数中。不要将实际 Token 写入仓库或分享执行命令。

## 自动任务及文件

脚本使用单套配置；再次带参数执行将替换配置和该工具的 cron 条目，保留其他 cron 条目。暂不支持同一台机器独立配置多个域名任务。

| 路径 | 用途 |
| --- | --- |
| /var/lib/cloudflare-ddns-index/ddns.sh | 安装后的脚本，权限 700 |
| /var/lib/cloudflare-ddns-index/config.sh | 配置及 Token，权限 600 |
| /var/lib/cloudflare-ddns-index/*.id | 固定的 DNS 记录 ID |
| /var/lib/cloudflare-ddns-index/ddns.log | cron 执行日志 |

安装会启用并启动 cron；默认每分钟运行 `ddns.sh --run`，不会再次询问参数或安装依赖。运行使用 flock 防止重入。日志不会自动轮转。

```bash
sudo crontab -l
sudo tail -n 50 /var/lib/cloudflare-ddns-index/ddns.log
sudo bash /var/lib/cloudflare-ddns-index/ddns.sh --run
```

如果固定记录已删除，核实目标后移除报错中指定的 `.id` 文件，下次运行会重新按序号选择。

## 卸载

执行 `sudo crontab -e`，只删除带有 `# cloudflare-ddns-index:/var/lib/cloudflare-ddns-index` 标记的行。等待正在进行的更新结束后，如不再需要配置和日志，再删除 `/var/lib/cloudflare-ddns-index` 目录。卸载不会删除 Cloudflare 上的 DNS 记录，也无需停用其他任务共用的 cron 服务。
