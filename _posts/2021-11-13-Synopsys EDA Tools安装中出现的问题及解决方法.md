---
layout: post
title:  "Synopsys EDA Tools安装中出现的问题及解决方法"
date:   2021-11-13 13:22:20 +0700
tags:
  - Linux
  - Digital IC Design
---


----

## 1 前言

&#160; &#160; &#160; &#160; 想找到一种最方便的IC开发调试环境，于是多次在虚拟机或物理机的Ubuntu、WSL2、SLES、OpenSUSE上安装了Synopsys 2016和2018两个版本的Tools，就积（chāo）累（xí）了很多遇到的错误和解决方法。安装过程网上已经有比较完善的文章了，但安装过程中问题的解决却零零散散还不好找，所以就整理记录一下。

* 操作系统：
  * Ubuntu 20.04.3 LTS
  * Windows Subsystem for Linux 2
  * SUSE Linux Enterprise Server 15 SP3
  * OpenSUSE Leap 15.3
* 开发环境：
  * ic_compiler_vO-2018.06-SP1
  * ppower_vO-2018.06-SP3
  * pt_vO-2018.06-SP1
  * syn_vO-2018.06-SP5-5
  * vcs_vO-2018.09-SP2
  * verdi_vO-2018.09-SP2-11

----


## 2 EDA Tools安装、破解过程中遇到的问题

### 2.1 缺少csh

&#160; &#160; &#160; &#160; 启动安装Tools的安装工具时，输入以下指令（2016版本）：

```sh
./installer =gui
```

&#160; &#160; &#160; &#160; 启动时会报错：

```sh
Explain Error：No such file or directory
```

&#160; &#160; &#160; &#160; 这个问题一般出现在Ubuntu，SUSE目前没遇到。这是由于缺少了csh，所以安装它来解决：

```sh
sudo apt-get install csh
```

---


### 2.2 运行lmstat时找不到文件或路径

&#160; &#160; &#160; &#160; 运行lmstat时会遇到如下错误：

```sh
bash: /usr/synopsys/scl/linux/bin/lmgrd: No such file or directory
```

&#160; &#160; &#160; &#160; 这个问题可能由以下两个原因造成：
* 没有lsb库；
* lmgrd路径错误。


&#160; &#160; &#160; &#160; 第一个问题我只在Ubuntu里见过，安装lsb就可以了：
```sh
sudo apt-get install lsb-core
```


&#160; &#160; &#160; &#160; 第二个问题是因为等工具在不同的操作系统、或者相同操作系统32bit和64bit下的安装路径都不太一样。Ubuntu 32bit的安装路径通常为：

```sh
<setup_directory>/scl/linux/bin/
```


&#160; &#160; &#160; &#160; 而ubuntu 64bit下路径为：
```sh
<setup_directory>/scl/amd64/bin/
```

&#160; &#160; &#160; &#160; 在OpenSUSE或SLES的64bit下lmstat的路径为：
```sh
<setup_directory>/scl/linux64/bin/
```


&#160; &#160; &#160; &#160; 同样的，License中第二行snpslmd的路径也要改为和lmstat下相同的路径。

----
## 3 EDA Tools启动过程中遇到的问题

### 3.1 找不到.flexlm文件

&#160; &#160; &#160; &#160; 启动EDA时遇到如下错误：

```sh
Can't make directory /usr/tmp/.flexlm, errno: 2(No such file or directory)
```

&#160; &#160; &#160; &#160; 这个问题各个系统都会遇到，新建这个文件就行了：

```sh
sudo mkdir -p /usr/tmp
sudo touch /usr/tmp/.flexlm
```

### 3.2 缺少库文件

&#160; &#160; &#160; &#160; 在Ubuntu、WSL2中可能缺失的库：
* libjpeg.so.62: 
  ```sh
  sudo apt-get install libjpeg62
  ```
* libtiff.so.3:
  ```sh
  cd /usr/lib/x86_64-linux-gnu/
  sudo cp libtiff.so.5 /usr/lib/
  cd /usr/lib
  sudo ln -s libtiff.so.5 libtiff.so.3
  ```
* libmng.so.1:
  ```sh
  sudo apt-get install libmng2
  cd /usr/lib/x86_64-linux-gnu
  sudo cp libmng.so.2 /usr/lib/
  cd /usr/lib
  sudo ln -s libmng.so.2 libmng.so.1
  ```
* libpng12.so.0:
  
  下载一个复制到`/usr/lib`：[libpng12.so.0]()
  



&#160; &#160; &#160; &#160; 


----
&#160; &#160; &#160; &#160; 告辞。