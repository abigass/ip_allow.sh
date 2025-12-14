# ip_allow.sh
```
██╗██████╗      █████╗ ██╗     ██╗      ██████╗ ██╗    ██╗
██║██╔══██╗    ██╔══██╗██║     ██║     ██╔═══██╗██║    ██║
██║██████╔╝    ███████║██║     ██║     ██║   ██║██║ █╗ ██║
██║██╔═══╝     ██╔══██║██║     ██║     ██║   ██║██║███╗██║
██║██║         ██║  ██║███████╗███████╗╚██████╔╝╚███╔███╔╝
╚═╝╚═╝         ╚═╝  ╚═╝╚══════╝╚══════╝ ╚═════╝  ╚══╝╚══╝
```
自动化添加端口ip白名单的工具。
对iptables进行自动化操作。

## 脚本说明
在命令执行的目录下需要有`ports/xxx/ipv4.txt`或`ports/xxx/ipv6.txt`。
其中：
- `xxx`是想要设置白名单的端口
- `ipv4.txt`文件中，每行一条`ip`（例`127.0.0.1`）或者一个`CIDR`（例`192.168.0.0/24`）
- `ipv6.txt`同理
- ip文件中，允许`#`开头的注释

运行脚本时，会：
- 自动读取`ports/xxx/ipv4.txt`和`ports/xxx/ipv6.txt`
- 将`xxx`端口设置为默认`drop`丢弃，然后将ip文件中的每一行加入允许通过的白名单。

## 用法：
```bash
bash ipallow_cn.sh -h|--help                  # 显示帮助/版本信息
sudo bash ipallow_cn.sh <port> [port2 ...]    # 仅应用指定端口白名单
sudo bash ipallow_cn.sh                       # 应用 ./ports 下全部端口白名单
sudo bash ipallow_cn.sh show                  # 从当前 iptables/ip6tables 规则展示统计
sudo bash ipallow_cn.sh delete [port ...]     # 删除本脚本添加的端口白名单
```

###  1. 显示帮助：
```bash
bash ipallow_cn.sh -h|--help                  # 显示帮助/版本信息
```

### 2. 应用指定/所有端口白名单
#### 应用指定端口白名单
```bash
sudo bash ipallow_cn.sh <port> [port2 ...]    # 仅应用指定端口白名单
```

样例：应用`443`和`8080`端口，`./ports/443/ipv4.txt`和`./ports/443/ipv6.txt`已有ip信息，`8080`同理。
```
root@simple:~/ip-allow# sudo bash ipallow_cn.sh 443 8080
端口 443 IPv4 白名单已刷新，规则链：IPALLOW_443（已添加：196，已跳过：0）
端口 443 IPv6 白名单已刷新，规则链：IPALLOW6_443（已添加：90，已跳过：0）
端口 8080 IPv4 白名单已刷新，规则链：IPALLOW_8080（已添加：197，已跳过：0）
端口 8080 IPv6 白名单已刷新，规则链：IPALLOW6_8080（已添加：90，已跳过：0）
```

#### 应用所有端口白名单
```bash
sudo bash ipallow_cn.sh                       # 应用 ./ports 下全部端口白名单
```

如果`ports/`文件夹下有`443`和`8080`和`8443`, 此命令会同时添加三个端口的白名单。

### 3. 展示本脚本已添加的白名单规则
```bash
sudo bash ipallow_cn.sh show                  # 从当前 iptables/ip6tables 规则展示统计
```

会从iptables中读取。
样例：读取已写入的所有端口：

```
root@simple:~/ip-allow# sudo bash ipallow_cn.sh show
端口   IPv4数量 IPv6数量
443      196        90        
8080     197        90   
```

### 4. 删除指定/所有端口白名单
#### 删除指定端口白名单
```bash
sudo bash ipallow_cn.sh delete [port ...]     # 删除本脚本添加的端口白名单
```

会提示是否删除。
样例：

```
root@simple:~/ip-allow# sudo bash ipallow_cn.sh delete 443
是否确认清除443端口ip白名单？[y/N] y
已删除443端口：共292条
```

#### 删除所有端口白名单
```bash
sudo bash ipallow_cn.sh delete                # 删除本脚本添加的所有端口白名单
```

会提示是否删除。
样例：
```
root@simple:~/ip-allow# sudo bash ipallow_cn.sh delete
是否确认清除所有本脚本添加的端口ip白名单？[y/N] y
已删除443端口：共292条
已删除8080端口：共293条
共删除2个端口的白名单
```

## 意义何在？
cdn厂商会提供源站防护，可以设置只允许这些回源ip，来检测或防止对网站源站的ddos等攻击
<img width="2169" height="1308" alt="OriginIP" src="https://github.com/user-attachments/assets/ce787855-1b14-4b87-bddc-9b9a1062ff8b" />

用本脚本可以快速设置白名单。

## 代码逻辑
```mermaid
flowchart TD
    A([开始]) --> B{是否为 root 用户?}
    B -- 否 --> B1[退出：需要 root 权限]
    B -- 是 --> C{是否已安装 iptables?}
    C -- 否 --> C1[退出：缺少 iptables]
    C -- 是 --> D{PORTS_DIR 目录是否存在?}
    D -- 否 --> D1[退出：未找到端口目录]
    D -- 是 --> E{是否通过参数指定端口?}

    E -- 是 --> F[遍历参数中的端口]
    E -- 否 --> G[列出 PORTS_DIR 下的子目录]

    G --> H{是否存在端口目录?}
    H -- 否 --> H1[退出：没有可处理的端口]
    H -- 是 --> I[遍历每个端口目录]

    F --> J[为当前端口应用规则]
    I --> J

    J --> K{是否存在 ipv4.txt 或 ipv6.txt?}
    K -- 否 --> K1[跳过该端口]
    K -- 是 --> L[生成规则注释信息]

    L --> M{是否存在 ipv4.txt?}
    M -- 是 --> M1[创建或清空 IPv4 专用链]
    M1 --> M2[根据 ipv4.txt 添加 ACCEPT 规则]
    M2 --> M3[添加最终 DROP 规则]
    M3 --> M4[确保 INPUT 链跳转到 IPv4 专用链]

    M -- 否 --> M5[跳过 IPv4 规则]

    L --> N{是否存在 ipv6.txt?}
    N -- 是 --> N1[创建或清空 IPv6 专用链]
    N1 --> N2[根据 ipv6.txt 添加 ACCEPT 规则]
    N2 --> N3[添加最终 DROP 规则]
    N3 --> N4[确保 INPUT 链跳转到 IPv6 专用链]

    N -- 否 --> N5[跳过 IPv6 规则]

    M4 --> O[处理下一个端口]
    M5 --> O
    N4 --> O
    N5 --> O

    O --> P{是否还有端口?}
    P -- 是 --> J
    P -- 否 --> Q([结束])


```
