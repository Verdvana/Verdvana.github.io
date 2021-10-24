---
layout: post
title:  "Ubuntu 18.04 LTS 系统下SSR全局代理"
date:   2019-1-14 11:59:10 +0700
tags:
  - Linux
---

-------
### 1.前言

&#160; &#160; &#160; &#160; 在Ubuntu 18.04 LTS中实现全局代理，代理模式为PAC模式。本文几乎全部参考了[fattoliu666](https://ywnz.com/linuxjc/2687.html)的文章，只不过他这里面有多处错误，直接套用会出错，我对其修改了一小下。


* 系统版本：Ubuntu 18.04 LTS
* 准备工具：SSR服务

-------
### 2.详细步骤

&#160; &#160; &#160; &#160; 打开终端（快捷键"ctrl"+"alt"+"t"）。更新软件源。


```shell
sudo apt update
```

&#160; &#160; &#160; &#160; 安装python-pip。

```shell
sudo apt install python-pip
```

&#160; &#160; &#160; &#160; 安装 shadowsocks。

```shell
sudo pip install shadowsocks
```

&#160; &#160; &#160; &#160; 配置 shadowsocks。

```shell
sudo gedit /etc/shadowsocks.json
```
&#160; &#160; &#160; &#160; 在 shadowsocks.json 文件中写入：
```json
{
    "server": "your_server_ip", //代理服务器IP地址
    "server_port": your_server_port,  //代理服务器端口地址
    "local_port": 1080,
    "password": "yourpassword",   //代理密码
    "timeout": 600,
    "method": "aes-256-cfb"  //数据加密方式
}
```
&#160; &#160; &#160; &#160; 启动 shadowsocks。
```shell
sudo sslocal -c /etc/shadowsocks.json -d start
```

&#160; &#160; &#160; &#160; 这一步会报错，这个问题是由于在openssl1.1.0版本中，废弃了EVP_CIPHER_CTX_cleanup函数。

&#160; &#160; &#160; &#160; 解决方法：

&#160; &#160; &#160; &#160; 1、打开shadowsocks.json：
```shell
sudo vim /etc/shadowsocks.json
```

&#160; &#160; &#160; &#160; 2、按下“i”切换到插入模式。

&#160; &#160; &#160; &#160; 3、将第52行

&#160; &#160; &#160; &#160; libcrypto.EVP_CIPHER_CTX_cleanup.argtypes = (c_void_p,)

&#160; &#160; &#160; &#160; 改为

&#160; &#160; &#160; &#160; libcrypto.EVP_CIPHER_CTX_reset.argtypes = (c_void_p,)

&#160; &#160; &#160; &#160; 4、将第111行

&#160; &#160; &#160; &#160; libcrypto.EVP_CIPHER_CTX_cleanup(self._ctx)

&#160; &#160; &#160; &#160; 改为

&#160; &#160; &#160; &#160; libcrypto.EVP_CIPHER_CTX_reset(self._ctx)


&#160; &#160; &#160; &#160; 修改完之后保存退出：按下“ESC”退出插入模式，输入“:wq”保存退出。然后再次执行：
```shell
sudo sslocal -c /etc/shadowsocks.json -d start
```

&#160; &#160; &#160; &#160; 这样就成功启动shadowssocks。

&#160; &#160; &#160; &#160; 安装GenPAC
```shell
sudo pip install genpac
pip install --upgrade genpac
```

&#160; &#160; &#160; &#160; 完成之后下载GFWlist：

```shell
genpac --proxy="SOCKS5 127.0.0.1:1080" --gfwlist-proxy="SOCKS5 127.0.0.1:1080" -o autoproxy.pac --gfwlist-url="https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt"
```

&#160; &#160; &#160; &#160; 这样PAC文件“autoproxy.pac”就下载到user目录下了。然后进入：设置—网络—网络代理，选择手动，URL 指向该文件路径即可，url 格式为：
file:///home/{user}/autoproxy.pac （{user}替换成自己的用户名）。

&#160; &#160; &#160; &#160; 搞定，上个Google试一下。

&#160; &#160; &#160; &#160; 为 git 配置代理，否则 google / android 源码是同步不下来的。
```shell
git config --global http.proxy 'socks5://127.0.0.1:1080' 
git config --global https.proxy 'socks5://127.0.0.1:1080'
```

&#160; &#160; &#160; &#160; 配置 Shadowsocks privoxy 自启动。先创建软连接：

```shell
sudo ln -fs /lib/systemd/system/rc-local.service /etc/systemd/system/rc-local.service
```
&#160; &#160; &#160; &#160; 该脚本内容为：
```shell
#  SPDX-License-Identifier: LGPL-2.1+
#
#  This file is part of systemd.
#
#  systemd is free software; you can redistribute it and/or modify it
#  under the terms of the GNU Lesser General Public License as published by
#  the Free Software Foundation; either version 2.1 of the License, or
#  (at your option) any later version.
# This unit gets pulled automatically into multi-user.target by
# systemd-rc-local-generator if /etc/rc.local is executable.
[Unit]
Description=/etc/rc.local Compatibility
Documentation=man:systemd-rc-local-generator(8)
ConditionFileIsExecutable=/etc/rc.local
After=network.target
[Service]
Type=forking
ExecStart=/etc/rc.local start
TimeoutSec=0
RemainAfterExit=yes
GuessMainPID=no
```

&#160; &#160; &#160; &#160; 在该文件中加上：
```shell
[Install]
WantedBy=multi-user.target
Alias=rc-local.service
```
&#160; &#160; &#160; &#160; 然后创建/etc/rc.local文件：
```shell
sudo touch /etc/rc.local
sudo chmod 755 /etc/rc.local
```
&#160; &#160; &#160; &#160; 编辑该文件：

```shell
sudo vim /etc/rc.local
```
&#160; &#160; &#160; &#160; 加入以下内容:

```shell
#!/bin/bash
sudo sslocal -c /etc/shadowsocks.json -d start
sudo /etc/init.d/privoxy start
```
&#160; &#160; &#160; &#160; 保存退出，完事儿！


--------

&#160; &#160; &#160; &#160; 告辞。
