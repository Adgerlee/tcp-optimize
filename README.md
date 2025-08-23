# 🎯 TCP Optimize

> 一个简单高效的跨境网络 TCP 自动化调优脚本，旨在提升高延迟、高丢包场景下的网络性能。

⭐ 如果你觉得有用，请点个 Star 支持我！

---

## 🖼️ TCP 优化示意图

![TCP 参数优化对比](https://gateway.pinata.cloud/ipfs/QmSNtyPho8JXxvieLR41EbVzm7FfWk4eLJasGh5NtN3V93 "TCP 参数优化对比")

> **图示**：优化前后在跨境链路（高延迟、高丢包）下的连接效率对比

---

## 📖 简介

该脚本通过调整 Linux 内核的 TCP 参数来优化网络性能，尤其适用于跨境通信场景。它支持三种模式：全球优化、自动检测优化和本地优化。

---

## 🚀 使用方法

### 1. 下载脚本

使用 `curl` 或 `wget` 下载脚本：

```bash
curl -O https://raw.githubusercontent.com/Adgerlee/tcp-optimize.sh/main/tcp-optimize.sh
或

bash
wget https://raw.githubusercontent.com/Adgerlee/tcp-optimize.sh/main/tcp-optimize.sh
2. 添加执行权限
确保脚本具有可执行权限：

bash
chmod +x tcp-optimize.sh
3. 运行脚本
根据你的需求选择合适的运行模式：

🌍 跨境优化（推荐）
适用于中国与海外之间的服务器通信：

bash
sudo ./tcp-optimize.sh --target=global
🤖 自动优化
脚本会自动检测网络环境并应用最优参数：

bash
sudo ./tcp-optimize.sh --target=auto
🏠 本地优化
适用于低延迟、高带宽的本地或同区域网络：

bash
sudo ./tcp-optimize.sh --target=local
🔧 支持的优化项
脚本会自动调整以下 Linux 内核参数：

net.ipv4.tcp_congestion_control：启用 BBR 或 cubic 拥塞控制算法
net.ipv4.tcp_window_scaling：启用窗口缩放
net.core.rmem_max / wmem_max：设置最大接收/发送缓冲区大小
net.ipv4.tcp_tw_reuse：允许重用 TIME-WAIT sockets
net.ipv4.tcp_fin_timeout：设置 FIN-WAIT-2状态的超时时间
❓ 常见问题
Q: 我需要备份现有的配置吗？

A: 是的，建议在运行脚本前备份 /etc/sysctl.conf 文件，以便恢复默认设置。

bash
cp /etc/sysctl.conf /etc/sysctl.conf.bak
Q: 如何撤销这些优化？

A: 可以通过恢复备份文件或手动将修改的参数复原。


💬 联系我
如果有任何问题或建议，欢迎通过以下方式联系我：

GitHub: @Adgerlee
希望这份 README 能帮助你更好地展示你的项目！如果你有其他具体需求或想添加更多信息，随时告诉我 😊


