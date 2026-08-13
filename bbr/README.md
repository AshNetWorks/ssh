# Debian BBR / 入口服务器网络优化脚本

本仓库提供 3 个不同强度的 Debian 网络优化脚本。

> 建议先了解每个版本的区别，再选择执行。  
> 修改内核网络参数存在一定风险，生产环境建议先在测试机验证。

## 版本说明

### `bbrs.sh` — 推荐版

推荐用于纯入口服务器，例如：

- nyanpass
- HAProxy
- Soga
- L4 TCP/UDP 入口
- 高并发代理入口

特点：

- BBR + `fq`
- 提高 `somaxconn`
- 提高 SYN backlog
- 提高网卡 backlog
- 扩大 TCP 缓冲区
- 扩大本地临时端口范围
- 自动按内存设置 conntrack
- 调整文件描述符上限
- 使用 `/etc/sysctl.d/99-entry-tuning.conf`
- 不直接覆盖整个 `/etc/sysctl.conf`
- 保留 ICMP/Ping
- 更适合长期用于入口服务器

**推荐优先使用此版本。**

一键执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/AshNetWorks/ssh/refs/heads/main/bbrs.sh)
```

或者先下载再执行：

```bash
curl -fsSL https://raw.githubusercontent.com/AshNetWorks/ssh/refs/heads/main/bbrs.sh -o /root/bbrs.sh
chmod +x /root/bbrs.sh
bash /root/bbrs.sh
```

---

### `bbrb.sh` — 基础版

相对简单的 BBR/网络参数配置脚本。

特点：

- 参数数量较少
- 根据内存调整 TCP Buffer
- 可选择是否禁止 ICMP/Ping
- 直接备份并重写 `/etc/sysctl.conf`
- 适合测试、小型服务器或者希望配置比较简单的环境

执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/AshNetWorks/ssh/refs/heads/main/bbrb.sh)
```

由于此版本带交互选项，执行后根据提示选择：

```text
当前机器内存是否 >= 1GB ? [Y/n]
是否要【禁止 ICMP】（不回应 ping）? [y/N]
```

一般建议：

```text
内存 >= 1GB：Y
禁止 ICMP：N
```

---

### `bbrx.sh` — 激进版

高强度网络参数版本。

当前脚本地址：

```text
https://raw.githubusercontent.com/AshNetWorks/ssh/refs/heads/main/bbrx.sh
```

执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/AshNetWorks/ssh/refs/heads/main/bbrx.sh)
```

也可以：

```bash
curl -fsSL https://raw.githubusercontent.com/AshNetWorks/ssh/refs/heads/main/bbrx.sh -o /root/bbrx.sh
chmod +x /root/bbrx.sh
bash /root/bbrx.sh
```

特点：

- 参数较为激进
- conntrack 上限设置非常高
- TIME_WAIT、KeepAlive、FIN timeout 等回收参数较激进
- 适合明确知道这些参数影响，并且已经实测过的特殊入口环境

**不建议新机器默认使用。**

如果只是普通纯入口服务器，建议使用 `bbrs.sh`。

---

## 推荐顺序

```text
bbrs.sh  推荐版   ★★★★★
bbrb.sh  基础版   ★★★★
bbrx.sh  激进版   ★★★
```

一般入口机器：

```text
优先 bbrs.sh
```

需要简单配置：

```text
使用 bbrb.sh
```

确认需要非常激进的参数：

```text
使用 bbrx.sh
```

---

## 执行后检查

查看 BBR：

```bash
sysctl net.ipv4.tcp_congestion_control
```

推荐版正常应看到：

```text
net.ipv4.tcp_congestion_control = bbr
```

查看队列算法：

```bash
sysctl net.core.default_qdisc
```

推荐版正常应看到：

```text
net.core.default_qdisc = fq
```

查看监听队列：

```bash
sysctl net.core.somaxconn
```

查看 conntrack：

```bash
sysctl net.netfilter.nf_conntrack_count
sysctl net.netfilter.nf_conntrack_max
```

---

## 建议

执行网络优化后，建议重启服务器：

```bash
reboot
```

或者至少重启相关入口程序。

例如 Soga：

```bash
soga restart
```

> 注意：脚本会修改系统内核网络参数。执行前请确保拥有服务器控制台/VNC等备用登录方式，以便错误配置时恢复。
