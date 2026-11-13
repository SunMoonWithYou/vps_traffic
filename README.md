<p align="center">
  <img src="banner.png" width="100%" alt="vnStat 流量统计 & Telegram 日报管理工具">
</p>

# 流量统计 & Telegram 管理工具

[![Version](https://img.shields.io/badge/version-v4.8-blue.svg)](https://github.com)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)]()

一个基于 `vnstat` 的服务器流量统计与上报工具。支持每日 Telegram 流量日报、每小时向 Cloudflare Worker 上报真实流量数据，并兼容任意服务器时区。

## ✨ 功能特性

- **每日 Telegram 流量日报**
  - 自动统计昨日真实下载/上传流量
  - 支持 4 种流量统计模式
  - 可视化进度条 + 彩色状态提示
  - 显示计费周期、重置日、累计用量等完整信息

- **每小时 Cloudflare Worker 上报**
  - 按**北京时间**上报上一个完整小时的流量数据
  - 自动处理时区转换（兼容任意服务器时区）
  - 携带设备唯一编码，方便多设备管理

- **灵活的流量统计模式**
  - 模式 1：入站 + 出站（默认）
  - 模式 2：仅入站
  - 模式 3：仅出站
  - 模式 4：入/出取大

- **设备唯一编码**
  - 优先使用 `/etc/machine-id`
  - 次选网卡 MAC 地址
  - 兜底生成随机 ID，确保设备可识别

- **其他特性**
  - 自动日志轮转（超过 5MB 自动清理）
  - 兼容 Debian / Ubuntu / CentOS / RHEL 等主流发行版
  - 交互式配置，一键安装/修改/卸载
  - 计费周期自动计算（支持自定义重置日）

## 📋 系统要求

- Linux 系统（Debian/Ubuntu/CentOS/RHEL 等）
- Root 权限
- 依赖软件：`vnstat`、`bc`、`curl`、`cron`（脚本会自动安装）

## 🚀 快速安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SunMoonWithYou/vps_traffic/main/install.sh)
```

选择菜单中的 **1) 全新安装**，按提示完成配置即可。

## ⚙️ 配置说明

运行脚本后进入交互式配置，需要填写以下信息：

| 配置项          | 说明                           | 示例                      |
| --------------- | ------------------------------ | ------------------------- |
| 主机别名        | 在 Telegram 消息中显示的主机名 | `HK-VPS-01`               |
| Bot Token       | Telegram Bot Token             | `123456:ABC-DEF...`       |
| Chat ID         | Telegram 接收消息的 Chat ID    | `123456789`               |
| 重置日          | 每月流量重置日期（1-31）       | `1`                       |
| 限额 (GB)       | 月度流量上限                   | `2000`                    |
| 流量统计方式    | 1-4 对应四种模式               | `1`                       |
| 每小时上报      | 是否开启 Worker 上报（0/1）    | `1`                       |
| Worker 上报地址 | Cloudflare Worker 的完整 URL   | `https://xxx.workers.dev` |
| 上传密钥        | Worker 验证密钥                | `your-secret-key`         |
| 网卡            | 监控的网络接口                 | `eth0` / `ens3`           |
| 每日报表时间    | 日报发送时间（HH:MM）          | `01:30`                   |

配置完成后会自动生成：

- 配置文件：`/etc/vnstat_tg.conf`（权限 600）
- 执行脚本：`/usr/local/bin/vnstat_tg_report.sh`
- 定时任务：cron 自动添加

## 📊 使用方式

运行脚本后会出现菜单：

```
===========================================
      流量统计管理工具  v4.8
===========================================

  1) 全新安装
  2) 修改配置
  3) 更新脚本逻辑

  4) 测试日报      (仅 Telegram)
  5) 测试实时上报  (仅 Worker)

  6) 彻底卸载
  7) 退出

===========================================
```

### 手动测试

```bash
# 测试 Telegram 日报
sudo /usr/local/bin/vnstat_tg_report.sh daily

# 测试 Worker 小时上报
sudo /usr/local/bin/vnstat_tg_report.sh hourly

# 查看日志
tail -f /tmp/vnstat_tg.log
```

## 📱 Telegram 日报示例

```
📊 流量日报

💻 主机：HK-VPS-01
🛜 地址：1.2.3.4

⬇️ 下载：12.34 GB
⬆️ 上传：5.67 GB
📈 模式：入+出

🧮 昨日：18.01 GB

📅 周期：2025-11-01 ~ 2025-11-30
🔄 重置：每月 1 号

⏳ 累计：456.78 / 2000 GB
🎯 进度：🟩🟩🟩⬜⬜⬜⬜⬜⬜⬜ 22%

🕙 2025-11-13 01:30
```

## ☁️ Cloudflare Worker 上报格式

小时上报时会向 Worker 发送如下 JSON（示例）：

```json
{
  "device_id": "a1b2c3d4e5f6...",
  "host": "HK-VPS-01",
  "ip": "1.2.3.4",
  "type": "hourly",
  "mode": "入+出",
  "rx": "-",
  "tx": "-",
  "yest_gb": "-",
  "today_gb": "-",
  "used_gb": "456.78",
  "max_gb": "2000",
  "pct": "22",
  "period_start": "2025-11-01",
  "period_end": "2025-11-30",
  "reset_day": "1",
  "time": "2025-11-13 08:10",
  "iso": "2025-11-13T00:10:00Z",
  "hourly": [
    {
      "key": "2025-11-13 07:00",
      "date": "2025-11-13",
      "hour": "07:00",
      "rx_mb": 123.45,
      "tx_mb": 67.89,
      "total_mb": 191.34
    }
  ]
}
```

> **注意**：`hourly` 字段中的时间始终为**北京时间**的上一个完整小时，脚本会自动完成时区转换。

## 🕒 定时任务

安装后会自动添加以下 cron 任务：

```bash
# 每日报表（时间可自定义）
30 1 * * * /bin/bash /usr/local/bin/vnstat_tg_report.sh daily >> /tmp/vnstat_tg.log 2>&1

# 每小时上报（如开启）
10 * * * * /bin/bash /usr/local/bin/vnstat_tg_report.sh hourly >> /tmp/vnstat_tg.log 2>&1
```

## 🗑️ 卸载

运行脚本选择 **6) 彻底卸载**，会自动清理：

- 定时任务
- 执行脚本 `/usr/local/bin/vnstat_tg_report.sh`
- 配置文件 `/etc/vnstat_tg.conf`
- 日志文件 `/tmp/vnstat_tg.log`

## 🔧 常见问题

**Q: 小时上报的时间不对？**  
A: v4.8 已修复时区转换错位问题。脚本会正确获取北京时间上一个完整小时，并用绝对时间戳查询 vnstat 本地数据。

**Q: 为什么日报没有昨日数据？**  
A: 请确认 `vnstat` 已正常运行并有历史数据。可执行 `vnstat -d` 检查。

**Q: Worker 上报失败？**  
A: 检查 `/tmp/vnstat_tg.log` 日志，确认 `WORKER_URL` 和 `UPLOAD_KEY` 配置正确，以及网络可达。

**Q: 如何查看当前配置？**  
A: `sudo cat /etc/vnstat_tg.conf`

## 📝 更新日志

### v4.8

- 修复时区转换错位 Bug
- 优化小时数据查询逻辑，使用绝对时间戳避免时差计算错误
- 改进日志输出，更清晰地显示北京时间与本地查表时间的对应关系

### v4.7 及更早

- 基础功能实现
- 支持多种流量统计模式
- 添加设备唯一编码
- 日志轮转与错误处理优化

## 📄 许可证

MIT License

## 🙏 致谢

- [vnstat](https://humdi.net/vnstat/) - 流量统计核心
- Telegram Bot API
- Cloudflare Workers

---

如果这个工具对你有帮助，欢迎 Star ⭐ 支持一下！
