---
layout: post
title:  "WSL2环境下安装使用Synopsys工具时出现的问题及解决办法"
date:   2021-8-1 17:27:10 +0700
tags:
  - Linux
---


----

## 1 前言

&#160; &#160; &#160; &#160; 由双系统装Ubuntu转战到WSL了，之前在Ubuntu中安装和使用Synopsys的EDA工具的方法在WSL下会出现一些新的问题。

* 操作系统：
	* Windows 11 Pro 21H2
	* WSL2 (Ubuntu 20.04 LTS)

----


## 2 固定虚拟网卡MAC地址

&#160; &#160; &#160; &#160; 每次开启WSL，都会产生一个新的虚拟网卡MAC地址，导致lisence无法使用，因此可以在开启WSL后修改MAC地址为固定值：

```sh
sudo ifconfig eth0 down
sudo ifconfig eth0 hw ether XX:XX:XX:XX:XX:XX
sudo ifconfig eth0 up
```

&#160; &#160; &#160; &#160; 但是，修改完之后会无法联网。



----

## 3 root用户模式下无法打开GUI


&#160; &#160; &#160; &#160; 远程登陆WSL的图形化界面后，在普通用户模式下能够打开Gvim等软件的图形化界面，但是Synopsys的EDA工具在root用户模式下启动就会报错：

```sh
No protocol specified E233: cannot open display
```

&#160; &#160; &#160; &#160; 这是因为Xserver默认情况下不允许别的用户的图形程序的图形显示在当前屏幕上，所以需要在切换到root用户之前输入如下命令:

```sh
xhost +
```

&#160; &#160; &#160; &#160; 这需要在开启xrdp服务之后再运行。

## 4 dc命令找不到

&#160; &#160; &#160; &#160; 跑VCS编译的时候会报错：

```sh
/bin/vcs: line 2402: dc: command not found
```

&#160; &#160; &#160; &#160; 虽然编译还是能完成，但是看着很不爽。所以用以下命令安装bc来解决：

```sh
sudo apt-get install bc
```

&#160; &#160; &#160; &#160; 然后在root用户模式下的环境变量（Ubuntu为：“/root/.bashrc”）中添加如下内容：

```sh
export PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/root/bin:"$PATH
```

----

## 5 sh连接到dash


&#160; &#160; &#160; &#160; Ubuntu环境中sh时默认连接到dash的，所以会在运行VCS编译时报错：

```sh
/bin/sh illegal option -h
```

&#160; &#160; &#160; &#160; 可以取消他们之间的连接来解决：

```sh
sudo rm -f /bin/sh
sudo ln -s /bin/bash /bin/sh
```

----

## 6 python的安装和版本

&#160; &#160; &#160; &#160; 在VCS仿真阶段会遇到如下错误：

```sh
/usr/bin/env: 'python': No such file or directory
```

&#160; &#160; &#160; &#160; 这是由于没有安装python，它需要的时python2.3版本，如果安装的是比如3.8版本，则会报错：

```sh
profrpt requires 2.3.0 <= Python version < 3.0.0 to run
```

&#160; &#160; &#160; &#160; 所以要安装python2.x版本：

```sh
sudo apt install python
```

----

## 7 gcc++-4.8命令找不到

&#160; &#160; &#160; &#160; 错误提示：

```sh
make[1]: g++-4.8: Command not found
```


&#160; &#160; &#160; &#160; 安装gcc4.8和g++4.8，并提高4.8版本的优先级：

```sh
sudo apt-get install gcc-4.8 g++-4.8										# 安装
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-4.8 100	# 提升优先级
```

&#160; &#160; &#160; &#160; 之后可以用如下命令查看gcc默认版本：

```sh
sudo update-alternatives --config gcc
```

----
&#160; &#160; &#160; &#160; 告辞。