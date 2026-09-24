# VPS 流量统计 & Telegram 日报管理工具

基于 `vnStat` + `Telegram Bot` 的 VPS 流量统计与日报推送脚本，支持一键安装、菜单管理、定时发送、周期累计、限额进度条等功能。

---

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/SunMoonWithYou/vps_traffic/main/install.sh -o install.sh && chmod +x install.sh && sudo ./install.sh
```

或使用 `wget`：

```bash
wget -O install.sh https://raw.githubusercontent.com/SunMoonWithYou/vps_traffic/main/install.sh && chmod +x install.sh && sudo ./install.sh
```

也可以直接运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SunMoonWithYou/vps_traffic/main/install.sh)
```

---

## 功能特性

- 自动检查并安装依赖：`vnstat`、`bc`、`curl`、`cron`
- 自动启用 `vnstat` 与 `cron` 服务
- 统计昨日上传、下载、合计流量
- 支持 4 种流量统计模式：
  - `1` 入 + 出
  - `2` 仅入站
  - `3` 仅出站
  - `4` 入 / 出每日取大
- 支持自定义每月重置日
- 支持设置月流量限额，并生成 Telegram 进度条
- 支持 Telegram Bot 日报推送
- 支持 Markdown 格式消息
- 自动写入 `crontab` 定时任务
- 提供中文菜单管理：
  - 全新安装
  - 修改配置参数
  - 仅更新脚本逻辑
  - 手动发送测试报表
  - 彻底卸载
  - 退出

---

## 支持系统

- Debian / Ubuntu
- CentOS / RHEL

建议使用 `root` 用户或具有 `sudo` 权限的用户运行。  
系统需要支持 `systemd`、`cron`，并且已正确识别网卡。

---

## 使用方法

运行主脚本后，会显示如下菜单：

```text
===========================================
    流量统计 TG 管理工具 v3.1
===========================================
 1. 全新安装 (配置+逻辑)
 2. 修改配置参数
 3. 仅更新脚本逻辑
 4. 手动发送测试报表
 5. 彻底卸载
 6. 退出
===========================================
```

首次使用请选择 `1` 进行全新安装。

---

## 配置说明

安装过程中会要求填写以下参数：

| 配置项 | 说明 |
|---|---|
| `HOST_ALIAS` | 主机别名，显示在 Telegram 日报中 |
| `TG_TOKEN` | Telegram Bot Token |
| `TG_CHAT_ID` | Telegram Chat ID |
| `RESET_DAY` | 每月流量重置日，范围 `1-31` |
| `MAX_GB` | 月流量限额，单位 GB |
| `INTERFACE` | 网卡名称，默认自动读取默认路由网卡 |
| `RUN_TIME` | 每日发送时间，格式 `HH:MM`，例如 `01:30` |
| `TRAFFIC_MODE` | 流量统计模式：`1` 入+出，`2` 仅入站，`3` 仅出站，`4` 入/出取大 |

配置文件保存位置：

```bash
/etc/vnstat_tg.conf
```

报表执行脚本保存位置：

```bash
/usr/local/bin/vnstat_tg_report.sh
```

定时任务示例：

```bash
30 1 * * * /bin/bash /usr/local/bin/vnstat_tg_report.sh
```

查看当前定时任务：

```bash
crontab -l
```

---

## Telegram Bot 准备

1. 在 Telegram 中找到 `@BotFather`
2. 创建 Bot，获取 `Bot Token`
3. 获取 `Chat ID`
   - 私聊：可以先给 Bot 发送一条消息，然后访问：
     ```text
     https://api.telegram.org/bot<你的TOKEN>/getUpdates
     ```
   - 也可以使用 `@userinfobot` 获取自己的 Chat ID
   - 群组：将 Bot 拉入群组，并给予发言权限，群组 Chat ID 通常为负数
4. 将 `TG_TOKEN` 和 `TG_CHAT_ID` 填入安装配置中

---

## 日报内容示例

Telegram 日报大致包含以下内容：

```text
📊 流量日报

💻主机：xxxx
🛜 地址：x.x.x.x

⬇️ 下载：x.xx GB
⬆️ 上传：x.xx GB
📈 模式：入+出

🧮 合计：x.xx GB

📅 周期：2025-01-01 ~ 2025-01-31
🔄 重置：每月 1 号

⏳ 累计：x.xx / xxx GB
🎯 进度：🟩🟩🟩⬜⬜⬜⬜⬜⬜⬜ 30%

🕙 2025-01-01 01:30
```

---

## 项目结构

```text
vps_traffic/
├── README.md
└── vps_traffic.sh
```

其中 `vps_traffic.sh` 为本项目主管理脚本。

---

## 卸载

可以在菜单中选择 `5. 彻底卸载`。

也可以手动卸载：

```bash
crontab -l | grep -v '/usr/local/bin/vnstat_tg_report.sh' | crontab -
sudo rm -f /usr/local/bin/vnstat_tg_report.sh /etc/vnstat_tg.conf
```

---

## 常见问题

### 1. 收不到 Telegram 消息

请检查：

- `TG_TOKEN` 是否正确
- `TG_CHAT_ID` 是否正确
- Bot 是否被用户拉黑
- 群组中 Bot 是否有发言权限
- 服务器是否能访问 `api.telegram.org`

### 2. 流量显示为 0

请检查：

- 网卡名称是否正确
- `vnstat` 是否已初始化
- 执行 `vnstat -d` 是否有昨日数据
- 系统时间、时区是否正确

查看时区：

```bash
timedatectl
```

### 3. vnStat 没有数据

可以手动更新：

```bash
sudo vnstat -i 你的网卡 --update
```

查看状态：

```bash
vnstat -i 你的网卡
```

### 4. 安装依赖失败

请确认：

- 系统软件源可用
- 当前用户有 `root` 或 `sudo` 权限
- 服务器网络正常

---

## 安全提示

- `/etc/vnstat_tg.conf` 中保存了 Telegram Bot Token，请勿泄露。
- 建议设置权限：
  ```bash
  sudo chmod 600 /etc/vnstat_tg.conf
  ```
- 不要将真实 Token、Chat ID 提交到 GitHub 仓库。
- 本脚本会安装依赖、修改 `crontab`、创建系统文件，请先在测试环境验证。

---

## 贡献

欢迎提交 Issue 或 Pull Request。

如果这个项目对你有帮助，欢迎给一个 Star ⭐

---

## License

MIT License

---

## 致谢

感谢 `vnStat`、`Telegram Bot API` 以及所有开源项目。
