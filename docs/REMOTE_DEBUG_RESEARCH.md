# 跨网络无线调试方案调研

## 背景

当前使用 `hdc tconn 192.168.1.69:39915` 进行无线调试，要求手机和 Dell Server 在同一局域网。当手机在外网（4G/5G）而 Dell Server 在家中时，需要一种方案实现远程无线调试。

## hdc 协议分析

### 协议特征
- **传输层**: 纯 TCP 连接，默认端口 5555（可配置）
- **认证**: **无** — 源码中硬编码 `AUTH_NONE`，无 RSA 密钥、无 TLS、无密码、无设备端确认弹窗
- **加密**: **无** — `DecryptPayload()` 仅做静态版本校验和 CRC 校验，源码注释 `// reserve for encrypt here`

### 与 ADB 对比
| 特性 | hdc | ADB (经典模式) | ADB (Android 11+ 无线) |
|------|-----|----------------|----------------------|
| 传输 | 纯 TCP | 纯 TCP | TLS |
| 认证 | 无 | RSA 密钥对 + 设备端确认 | 6 位 PIN 配对 |
| 端口 | 5555（可配置） | 5555 | 随机端口 + mDNS |

### 安全警告
hdc 端口直接暴露到公网**极其危险**。ADB 5555 端口暴露导致数万台设备被 Satori 变种等僵尸网络入侵。hdc 连认证都没有，风险更大——任何人 `hdc tconn <公网IP>:5555` 即可获得完整 shell 权限。

---

## 方案对比

### 方案 1: VPN（推荐）

#### 1a: 利用现有 OpenVPN 服务器 (112.124.98.68)

**原理**: 手机和 Dell Server 都连入 VPN，获得虚拟局域网 IP，`hdc tconn <VPN-IP>:5555` 直接可用。

**配置步骤**:
1. Dell Server 安装 OpenVPN 客户端并连接到 112.124.98.68
2. HarmonyOS 手机安装 OpenVPN 客户端并连接
3. 确认双方获得 VPN 子网 IP（如 10.8.0.x）
4. Dell Server 上: `hdc tconn <手机VPN-IP>:5555`

**优点**:
- 已有基础设施，零额外成本
- VPN 提供加密传输和认证，弥补 hdc 无认证的缺陷
- 对 hdc 透明，无需修改任何配置

**缺点**:
- OpenVPN 性能一般（用户态 TCP-over-TCP），延迟偏高
- HarmonyOS 不一定有 OpenVPN 客户端
- 需确认 VPN 服务器配置了 client-to-client 路由

**可行性**: ★★★★☆ — 如果 HarmonyOS 支持 OpenVPN

#### 1b: Tailscale（最推荐）

**原理**: 基于 WireGuard 的 mesh VPN，自动 NAT 穿透，P2P 直连或通过 DERP relay。

**配置步骤**:
1. 注册 Tailscale 账号（免费 100 台设备）
2. Dell Server 安装: `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`
3. 手机安装 Tailscale 客户端（如果 HarmonyOS 应用市场有的话）
4. 两端登录同一账号
5. `hdc tconn <手机Tailscale-IP>:5555`

**优点**:
- 零配置 NAT 穿透（即使双方都在 NAT 后）
- WireGuard 内核级加密，低延迟
- IP 稳定不变
- 社区已验证 ADB over Tailscale 可行，hdc 同理

**缺点**:
- HarmonyOS 可能没有 Tailscale 客户端（**关键瓶颈**）
- 依赖第三方服务

**可行性**: ★★★☆☆ — 取决于 HarmonyOS 客户端可用性

#### 1c: WireGuard 自建

**原理**: 在阿里云 VPS 上部署 WireGuard 服务端，手动配置。

**配置步骤**:
1. VPS (112.124.98.68) 上安装 WireGuard:
   ```bash
   apt install wireguard
   wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
   ```
2. 配置 `/etc/wireguard/wg0.conf`:
   ```ini
   [Interface]
   Address = 10.66.66.1/24
   ListenPort = 51820
   PrivateKey = <server-private-key>

   [Peer]  # Dell Server
   PublicKey = <dell-public-key>
   AllowedIPs = 10.66.66.2/32

   [Peer]  # 手机
   PublicKey = <phone-public-key>
   AllowedIPs = 10.66.66.3/32
   ```
3. Dell Server 和手机各自配置 WireGuard 客户端
4. `hdc tconn 10.66.66.3:5555`

**优点**:
- 内核级性能，延迟极低（比 OpenVPN 快 3-4 倍）
- 完全自控，不依赖第三方
- 配置简单稳定

**缺点**:
- 同样依赖 HarmonyOS 是否有 WireGuard 客户端
- 需要手动管理密钥

**可行性**: ★★★☆☆ — 同样受限于 HarmonyOS 客户端

---

### 方案 2: 端口转发 / 内网穿透

#### 2a: frp

**原理**: 在 VPS 上运行 frps，Dell Server 上运行 frpc，将手机的 hdc 端口映射到公网。

**注意**: 这里的场景是 Dell Server 需要连接手机。关键问题是**手机**在外网，Dell Server 在家里。frp 通常用于将内网服务暴露到公网。

**实际场景**: Dell Server（内网）通过 frp 暴露自己的端口 → 手机在外时连不上 Dell Server → 但 hdc 是 Dell Server 连手机，不是反过来。

**修正思路**: 需要在**手机侧**运行 frpc 将 hdc 端口转发出去，或者换个方向思考：
- 手机在 4G 网络下，IP 不固定且在运营商 NAT 后
- 手机上无法运行 frpc（HarmonyOS 限制）
- **此方案在"手机在外"场景下不太适用**

**替代思路**: 如果场景反过来（Dell Server 在外，手机在家），frp 就很合适——在家里跑 frpc 转发手机端口。

**VPS 配置** (frps - 112.124.98.68):
```toml
bindPort = 7000
auth.token = "your-secret-token"
```

**家里 Dell Server 配置** (frpc):
```toml
serverAddr = "112.124.98.68"
serverPort = 7000
auth.token = "your-secret-token"

[[proxies]]
name = "hdc-debug"
type = "tcp"
localIP = "192.168.1.69"   # 手机局域网 IP
localPort = 39915
remotePort = 15555
```

**外面的电脑连接**:
```bash
hdc tconn 112.124.98.68:15555
```

**优点**:
- 配置简单，已有 VPS 可用
- 支持 token 认证（frp 层面）

**缺点**:
- **仅适用于 Dell Server 在外、手机在家的场景**
- hdc 无加密，frp token 仅保护隧道建立，不保护传输内容
- 需要配合防火墙限制 IP 访问

**可行性**: ★★★★☆ — 但仅限"出门带笔记本、手机留家里"的场景

#### 2b: Cloudflare Tunnel

**原理**: 通过 cloudflared 建立到 Cloudflare 边缘的隧道，可加 Zero Trust 访问策略。

**优点**:
- 免费，自带 TLS 和认证（Cloudflare Access）
- 无需公网 IP

**缺点**:
- 需要两端都安装 cloudflared
- TCP 代理配置较复杂
- 额外延迟（经过 Cloudflare 边缘节点）

**可行性**: ★★☆☆☆ — 过于复杂

#### 2c: ngrok

**原理**: `ngrok tcp 5555` 快速建立 TCP 隧道。

**优点**:
- 一行命令即可
- 自动 NAT 穿透

**缺点**:
- 免费版每次地址随机变化
- TCP 隧道免费版无认证，任何知道地址的人都能连
- 付费版较贵

**可行性**: ★★☆☆☆ — 适合临时测试，不适合日常使用

---

### 方案 3: SSH 端口转发

**原理**: 通过 SSH 隧道将远程 hdc 端口映射到本地。

**前提**: 家中 Dell Server 能通过 SSH 访问（直接公网 IP 或通过 VPS 跳板）。

**配置步骤**:

**场景 A**: Dell Server 有公网 IP 或已做端口映射
```bash
# 在外面的笔记本上
ssh -L 5555:192.168.1.69:39915 user@home-server-ip -N
hdc tconn 127.0.0.1:5555
```

**场景 B**: 通过 VPS 跳板（Dell Server 先反向连接 VPS）

Dell Server 上建立反向隧道:
```bash
# Dell Server → VPS
ssh -R 22222:localhost:22 user@112.124.98.68 -N
```

外面的笔记本通过 VPS 二次转发:
```bash
# 笔记本 → VPS → Dell Server → 手机
ssh -L 5555:192.168.1.69:39915 -J user@112.124.98.68:22222 user@dell-server -N
hdc tconn 127.0.0.1:5555
```

**优点**:
- SSH 提供完整加密和认证
- 不需要在手机上安装任何额外软件
- 利用现有 SSH 基础设施

**缺点**:
- **仅适用于手机在家、人在外的场景**（需要 Dell Server 和手机在同一局域网）
- 多跳延迟
- SSH 连接可能不稳定需要 autossh 维持

**可行性**: ★★★★☆ — 手机在家时的最佳安全方案

---

### 方案 4: 远程桌面

**原理**: 远程连接到家中 Windows/Dell Server，在那里运行 DevEco Studio。

**工具选项**:
- **RDP (Windows Remote Desktop)**: Windows 自带，需路由器端口映射或 VPN
- **Parsec**: 低延迟游戏级远程桌面，免费
- **ToDesk / 向日葵**: 国内穿透方案，无需端口映射
- **VS Code Remote SSH**: 只远程代码编辑，不含 IDE 全部功能

**配置步骤** (以 ToDesk 为例):
1. Dell Server 安装 ToDesk 并获取设备码
2. 手机/外出笔记本安装 ToDesk
3. 输入设备码连接

**优点**:
- **不需要手机在身边** — 可以用 DevEco 的模拟器调试
- 使用家中电脑的全部算力
- 配置最简单
- **如果手机也在家（USB 连着 Dell Server），这是最完美的方案**

**缺点**:
- 延迟明显（尤其 4G 网络下），编码体验差
- 需要持续稳定的网络连接
- 手机不在身边时无法做真机调试
- 流量消耗大

**可行性**: ★★★★★ — 最简单，但体验取决于网络质量

---

### 方案 5: 云端构建 + 远程安装

**原理**: 在云服务器上搭建 HarmonyOS 构建环境，构建 HAP 后推送到手机安装。

**配置步骤**:
1. 云服务器安装 HarmonyOS SDK 和命令行构建工具
2. 配置 CI/CD (GitHub Actions / Jenkins)
3. 代码推送后自动构建
4. 构建产物通过某种方式安装到手机

**优点**:
- 构建不受本地环境限制
- 可集成 CI/CD

**缺点**:
- HarmonyOS 构建环境依赖 DevEco Studio，命令行构建支持有限
- **无法实现热重载和断点调试** — 这是致命缺点
- 安装到手机仍然需要 hdc 连接
- 搭建成本高

**可行性**: ★★☆☆☆ — 适合 CI/CD，不适合日常开发调试

---

## 方案对比总结

| 方案 | 安全性 | 延迟 | 复杂度 | 成本 | 手机在外可用 | 手机在家可用 | 推荐度 |
|------|--------|------|--------|------|-------------|-------------|--------|
| OpenVPN (已有) | ★★★★ | ★★★ | ★★★★ | 免费 | 需客户端 | ✅ | ★★★★ |
| Tailscale | ★★★★★ | ★★★★★ | ★★★★★ | 免费 | 需客户端 | ✅ | ★★★★★ |
| WireGuard 自建 | ★★★★★ | ★★★★★ | ★★★ | 免费 | 需客户端 | ✅ | ★★★★ |
| frp | ★★★ | ★★★★ | ★★★★ | 免费 | ❌ | ✅ | ★★★ |
| SSH 隧道 | ★★★★★ | ★★★ | ★★★ | 免费 | ❌ | ✅ | ★★★★ |
| 远程桌面 | ★★★ | ★★ | ★★★★★ | 免费 | 仅模拟器 | ✅ | ★★★★ |
| 云端构建 | ★★★★ | N/A | ★ | 高 | 部分 | 部分 | ★★ |

---

## 推荐方案

### 核心问题
hdc 调试的根本约束是: **Dell Server 需要能 TCP 连接到手机的 hdc 端口**。当手机在外网（4G/5G）时，手机 IP 不固定且在运营商 NAT 后，无法从外部直接连接。

### 按场景推荐

#### 场景 A: 手机在家（USB 连着 Dell Server），人在外
**最佳方案: 远程桌面 + SSH 隧道**

这是最实用的方案:
1. 手机 USB 连接 Dell Server（或同一局域网无线连接）
2. 出门后通过远程桌面（ToDesk/向日葵/RDP）连回 Dell Server
3. 在远程桌面中使用 DevEco Studio，hdc 在本地网络完成
4. 体验等同于坐在电脑前

```
[你在外面] → 远程桌面 → [Dell Server] → hdc USB/WiFi → [手机在家]
```

#### 场景 B: 手机带出门，需要真机调试
**最佳方案: VPN (OpenVPN 已有 / Tailscale)**

前提: HarmonyOS 设备能安装 VPN 客户端。

```
[Dell Server] → VPN → [VPN 服务器] ← VPN ← [手机在外]
                  hdc tconn <手机VPN-IP>:5555
```

如果 HarmonyOS 无法安装 VPN 客户端，则此场景**暂无完美解决方案**。退而求其次:
- 带一台笔记本出门，笔记本和手机在同一热点下用 hdc 连接
- 笔记本通过 VPN/SSH 连回家中 Dell Server 同步代码

#### 场景 C: 临时需要，快速验证
**最佳方案: frp + SSH 隧道**

快速搭建，用完即关:
```bash
# Dell Server 上
ssh -R 15555:192.168.1.69:39915 user@112.124.98.68 -N

# 外面笔记本上
hdc tconn 112.124.98.68:15555
```

### 最终建议

1. **日常开发**: 远程桌面方案（手机留家里 USB 连着） — 最稳定、零配置
2. **需要真机在手**: 先确认 HarmonyOS 是否支持 VPN 客户端（OpenVPN/WireGuard）
3. **长期方案**: 在 VPS 上部署 frp，配合 iptables 限制访问 IP，用于"手机在家"场景的灵活调试
4. **安全红线**: 永远不要将 hdc 端口直接暴露到公网

---

## 附录: 快速配置参考

### frp 配置（手机在家场景）

**VPS (112.124.98.68) - frps.toml**:
```toml
bindPort = 7000
auth.token = "your-secret-token-here"
```

```bash
./frps -c frps.toml
```

**Dell Server - frpc.toml**:
```toml
serverAddr = "112.124.98.68"
serverPort = 7000
auth.token = "your-secret-token-here"

[[proxies]]
name = "hdc-debug"
type = "tcp"
localIP = "192.168.1.69"
localPort = 39915
remotePort = 15555
```

```bash
./frpc -c frpc.toml
```

**外出笔记本连接**:
```bash
hdc tconn 112.124.98.68:15555
```

**VPS 防火墙限制**:
```bash
# 仅允许你的手机 IP 访问（如果 IP 固定）
iptables -A INPUT -p tcp --dport 15555 -s YOUR_IP -j ACCEPT
iptables -A INPUT -p tcp --dport 15555 -j DROP
```

### SSH 反向隧道（手机在家场景）

**Dell Server 上**:
```bash
# 安装 autossh 保持连接
apt install autossh

# 建立反向隧道，将手机 hdc 端口映射到 VPS
autossh -M 20000 -R 15555:192.168.1.69:39915 user@112.124.98.68 -N -f
```

**外出笔记本上**:
```bash
hdc tconn 112.124.98.68:15555
```

### OpenVPN（双端场景）

确认 VPN 服务器 `/etc/openvpn/server.conf` 包含:
```
client-to-client
push "route 10.8.0.0 255.255.255.0"
```

Dell Server 和手机均连接 VPN 后:
```bash
hdc tconn <手机VPN-IP>:5555
```
