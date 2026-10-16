# XrayInstall

Alpine Linux / OpenRC 上的 VLESS + REALITY + Vision 一键安装和管理脚本。支持 IPv4、IPv6、NAT 公网端口、自定义 SNI、独立回落目标、多用户与自动低内存配置。

## 安装

以 root 执行，支持 Alpine 3.21 及更新版本。核心通过 [XTLS 官方 Alpine 安装脚本](https://github.com/XTLS/Xray-install/tree/main/alpinelinux)获取，跟随官方最新版本和架构检测。

```sh
apk add --no-cache curl ca-certificates
curl -fL https://raw.githubusercontent.com/TheFunny233/XrayInstall/main/xray-reality.sh -o /root/xray-reality.sh
ash /root/xray-reality.sh install
```

默认 TCP 443、SNI `www.amd.com`；自动检测公网 IPv4，失败后尝试 IPv6。安装成功后可直接使用 `xray-reality` 管理。已有节点不会被默认重建；需要重建时加 `--force`，会生成新 UUID 和密钥，旧配置会备份。

IPv6 节点：

```sh
ash /root/xray-reality.sh install 443 --ipv6 --sni www.amd.com
# 手动指定公网 IPv6；分享链接自动使用 [IPv6]:端口
ash /root/xray-reality.sh install 443 --ipv6 --address 2001:db8::123 --sni www.amd.com
```

`2001:db8::123` 是文档示例，请替换成实际可路由公网地址。IPv6 默认监听 `::`；Linux 默认设置下也可接受 IPv4，具体取决于 `net.ipv6.bindv6only`，脚本不会修改该内核设置。客户端网络需要有 IPv6。脚本不配置服务商路由、NAT、安全组或主机防火墙。

NAT 主机（内部端口 83、外部端口 20443）：

```sh
ash /root/xray-reality.sh install 83 --address your-server.example.com --public-port 20443 --sni www.amd.com
```

独立配置 SNI、回落目标和监听地址：

```sh
ash /root/xray-reality.sh install 443 --ipv6 --sni www.example.com --target www.example.com:443 --listen ::
# 回落目标也可以为 [公网IPv6]:443，SNI 仍应为该目标证书支持的域名
```

SNI 不加协议、路径或端口，国际化域名先转换为 Punycode。目标应从服务器可达并支持合适的 TLS 服务，证书应涵盖 SNI。配置检查通过只证明格式正确，不保证目标适合 REALITY；实际连接还需客户端测试。

## 自动低内存优化

读取 `/proc/meminfo` 和可用 cgroup v1/v2 限制，取最小有效内存，避免把宿主机内存当成容器配额。安装时自动应用：

| 有效内存 | GOMEMLIMIT | GOGC | connIdle | bufferSize |
| --- | --- | --- | --- | --- |
| ≤128 MiB | 约31%，最低16MiB | 50 | 120秒 | 64KB |
| ≤256 MiB | 50% | 75 | 180秒 | 128KB |
| ≤512 MiB | 65% | 100 | 180秒 | 256KB |
| >512 MiB | 80% | 100 | 300秒 | 512KB |

例如 128,000,000 字节配额会识别为约122MiB，配置约38MiB Go 软内存限制。该值不是 RSS 或整个容器的硬上限；网络内存、其他进程、文件缓存仍需空间。32/64MB 环境不保证可用，高并发或测速仍可能 OOM。

连接策略使用当前 Xray 正确的 `policy.levels.0` 结构。`bufferSize` 是每请求内部缓冲阈值，不是预分配内存，也不包括内核 TCP 缓冲。握手上限默认15秒，半关闭连接等待1秒；关闭统计和访问日志，保留 warning 错误日志。缩小缓冲或提高 GC 频率可能牺牲吞吐、增加 CPU；应结合实际负载调整。

安装包和解压临时目录放在 `/root` 文件系统，避免默认 `/tmp` 为 tmpfs 时占用内存；不安装面板和数据库。官方安装器仍会解压完整发行包，安装峰值内存依然取决于文件系统和发行包大小。错误日志由用户按需轮转，脚本不启动额外的日志守护进程。

优化思路参考 [lgdlkq/32m](https://github.com/lgdlkq/32m) 的极简部署和 [singbox-lite](https://github.com/0xdabiaoge/singbox-lite) 的 cgroup/Go 内存预算；实现已按当前 [Xray Policy 文档](https://xtls.github.io/en/config/policy.html)重新编写。未照搬旧项目的平铺 policy 或32位架构假设。

## 管理命令

```sh
xray-reality show                         # 节点参数及所有用户分享链接
xray-reality status                       # 真实监听、RSS、内存与 OOM
xray-reality check                        # 校验完整 confdir
xray-reality log                          # 最近100行错误日志
xray-reality start                        # 或 stop / restart
xray-reality update                       # 升级官方最新核心，失败回滚
xray-reality change-port 8443              # 修改监听和分享端口
xray-reality change-port 83 20443          # NAT：监听端口和公网端口
xray-reality set-address '2001:db8::123'    # 修改分享地址，需已启用 IPv6 监听
xray-reality set-address example.com 20443 # 域名及公网端口
xray-reality set-listen ::                 # 启用 IPv6 监听，不重建用户/密钥
xray-reality set-sni www.amd.com           # 默认同步回落目标为该域名:443
xray-reality set-sni www.amd.com www.amd.com:443
xray-reality add-user '手机 1'             # 中文、空格备注自动 URL 编码
xray-reality del-user UUID                # 拒绝删除最后一个用户
xray-reality optimize                     # 重算预算，应用连接策略、关闭访问日志
xray-reality memory
xray-reality set-memory 40MiB 50           # 手动设置 Go 参数
xray-reality reset-memory                 # 恢复 Go 默认，保留连接策略
xray-reality set-policy 120 64 15          # 空闲秒数 缓冲KB 握手秒数
xray-reality uninstall --yes
```

管理命令作用于第一个、由本脚本创建的入站，不用于管理第三方面板配置。每次配置、内存参数或核心更新先创建备份，配置校验和真实端口监听检查失败时恢复原配置、状态、核心与服务文件；原来运行的服务会尝试重新启动。仅安装、核心更新和卸载备份核心二进制，普通配置修改只备份配置，避免小磁盘反复存储大文件。备份在 `/root/xray-reality-backups/`，包含私钥，请勿上传或分享；按需自行清理旧备份。断电、SIGKILL 无法触发 shell 回滚，此时可从备份手动恢复，并检查后删除残留的 `/run/xray-reality.lock`。互斥锁会阻止并发管理命令覆盖配置。

`set-address` 只修改分享元数据，不重启服务。其他修改通常重启 Xray，会短暂断开现有连接。修改 SNI、地址、端口后需要在客户端重新导入 `show` 输出的链接。

## 升级旧管理脚本

```sh
curl -fL https://raw.githubusercontent.com/TheFunny233/XrayInstall/main/xray-reality.sh -o /root/xray-reality.new.sh
ash -n /root/xray-reality.new.sh
cp /root/xray-reality.new.sh /usr/local/bin/xray-reality
chmod 700 /usr/local/bin/xray-reality
xray-reality optimize
```

兼容旧版 `/etc/xray-reality.env`，未记录公网端口时默认等于原监听端口。`optimize` 保留现有用户、端口、SNI 和 REALITY 密钥，但会覆盖等级0连接策略、Go 参数和访问日志设置。

## 验证

```sh
busybox ash -n xray-reality.sh
shellcheck -s ash xray-reality.sh
busybox ash tests/unit.sh ./xray-reality.sh
```

单元测试覆盖地址校验、IPv6 URI 格式和备注编码、内存档位及 policy 输出；实机安装/回滚测试另外进行。运行单元测试需要 `busybox` 和 `jq`。

已在 Alpine 3.23 / x86_64 / 192,000,000 字节 cgroup 内存配额下完成安装和管理命令实测：IPv6 回环连接上的 REALITY + Vision 握手、经 SOCKS 发起 HTTPS 请求、占用端口触发回滚、增删用户、SNI/端口修改、内存参数修改与重算。公网 IPv6 入站连通性仍取决于服务商和客户端网络。
