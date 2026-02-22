# PVE 一键安装脚本

本工具将指导你如何使用一键脚本快速安装 **Proxmox VE (PVE)**，适用于 **物理服务器/裸机**（通常基于 Debian 11/12/13）。  
⚠️ 注意：PVE 需要安装在 **物理机** 或 **支持虚拟化的虚拟机** 上，且需 **UEFI 启动模式** 和 **直接访问物理磁盘**。

---

## 一、前置条件

### 1. 硬件要求
- **CPU**：支持虚拟化（Intel VT-x 或 AMD-V，需在 BIOS 中开启）
- **内存**：建议至少 **4GB**（生产环境推荐 8GB+）
- **系统**：建议使用Debian 13（老机器建议Debian 12或者更旧版本）
- **架构*8：arm64-adm64
- **磁盘**：建议 **50GB 以上可用空间**（PVE 系统盘 + 存储池）
- **网络**：稳定的网络连接（用于下载安装包和更新）


---

## 二、运行 一键安装脚本
**1.安装所需基本环境**
```apt update -y
apt install wget curl sudo git screen nano iptables-persistent iptables redis-server lsb-release unzip -y
```

 **2.一键自动化安装脚本**
 
 ```
bash <(curl -sL https://raw.githubusercontent.com/Xiaolqy/pve-install/main/install-pve.sh)
 ```
或者
```自行在发布页面下载文件
执行install-pve.sh
然后就没了
```

**3.最后登录面板**
这里我也不多讲了
