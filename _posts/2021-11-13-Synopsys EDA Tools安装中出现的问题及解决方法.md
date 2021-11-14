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

### 3.2 缺少库文件（Ubuntu/WSL2）

&#160; &#160; &#160; &#160; 在Ubuntu、WSL2中可能缺失的库：
* libjpeg.so.62： 
  ```sh
  sudo apt-get install libjpeg62
  ```
* libtiff.so.3：
  ```sh
  cd /usr/lib/x86_64-linux-gnu/
  sudo cp libtiff.so.5 /usr/lib/
  cd /usr/lib
  sudo ln -s libtiff.so.5 libtiff.so.3
  ```
* libmng.so.1：
  ```sh
  sudo apt-get install libmng2
  cd /usr/lib/x86_64-linux-gnu
  sudo cp libmng.so.2 /usr/lib/
  cd /usr/lib
  sudo ln -s libmng.so.2 libmng.so.1
  ```
* libpng12.so.0：
  * 下载一个复制到`/usr/lib`：[libpng12.so.0](https://github.com/Verdvana/Verdvana.github.io/blob/master/_posts/Synopsys%20EDA%20Tools%E5%AE%89%E8%A3%85%E4%B8%AD%E5%87%BA%E7%8E%B0%E7%9A%84%E9%97%AE%E9%A2%98%E5%8F%8A%E8%A7%A3%E5%86%B3%E6%96%B9%E6%B3%95/libpng12.so.0)
* libstdc++.so.6：
  ```sh
  sudo apt-get install lib32stdc++6
  ```

### 3.3 缺少库文件（SLES/OpenSUSE）

&#160; &#160; &#160; &#160; 在SLES、OpenSUSE中可能确实的库：
* libncurses.so.5：
  ```sh
  sudo zypper install libncurses5
  ```

### 3.4 库版本未找到（SLES/OpenSUSE）

&#160; &#160; &#160; &#160; 在SLES、OpenSUSE中打开PrimeTime的时候会出现以下错误：

```sh
/usr/software/synopsys/.../pt/shlib/libz.so.1: version `ZLIB_1.2.9' not found (required by /usr/lib64/...
```

&#160; &#160; &#160; &#160; 首先去[zlib](https://www.zlib.net/fossils/)下载对应版本的zlib，我这里下载了1.2.9版本的zlib。然后把下载好的zlib-1.2.9.tar.gz放到某个路径下，在terminal里进入这个路径，执行以下命令：

```sh
tar -zxvf zlib-1.2.9.tar.gz
cd zlib-1.2.9
./configure
make #可能需要安装make：sudo zypper install make
make install
```

&#160; &#160; &#160; &#160; 安装好之后看下打印出来的信息，找到libz.so.1.2.9这个文件install到哪里，比如我的安装在`/usr/local/lib/`下。然后去error信息中的software安装路径下libz.so.1所在的路径，把安装好的libz.so.1.2.9文件link到这里：
```sh
ln -s /usr/local/lib/libz.so.1.2.9   /usr/software/synopsys/.../pt/shlib/libz.so.1
```

### 3.5 TCP端口被占用


&#160; &#160; &#160; &#160; 错误信息：

```sh
(lmgrd) Failed to open the TCP port number in the license.
```

&#160; &#160; &#160; &#160; License文件中通常使用27000端口，如果这个端口被占用，使用如下命令查看占用进程的PID：


```sh
sudo lsof -i:27000
```

&#160; &#160; &#160; &#160; 然后用如下命令杀死进程：

```sh
sudo kill -9 <PID>
```

### 3.6 启动了多个snpslmd（OpenSUSE）

&#160; &#160; &#160; &#160; 在OpenSUSE中，启动lmgrd的时候会提示：

```sh
13:48:56 (lmgrd) Started snpslmd (internet tcp_port 59331 pid 2024)
13:48:56 (snpslmd) FlexNet Licensing version v11.14.1.3 build 212549 x64_lsb
13:48:56 (snpslmd) Cannot open daemon lock file
13:48:56 (snpslmd) EXITING DUE TO SIGNAL 41 Exit reason 9
13:48:56 (lmgrd) snpslmd exited with status 41 (Exited because another server was running)
13:48:56 (lmgrd) MULTIPLE "snpslmd" license server systems running.
13:48:56 (lmgrd) Please kill, and run lmreread
13:48:56 (lmgrd) 
13:48:56 (lmgrd) This error probably results from either:
13:48:56 (lmgrd)   1. Another copy of the license server manager (lmgrd) is running.
13:48:56 (lmgrd)   2. A prior license server manager (lmgrd) was killed with "kill -9"
13:48:56 (lmgrd)       (which would leave the vendor daemon running).
13:48:56 (lmgrd) To correct this, do a "ps -ax | grep snpslmd"
13:48:56 (lmgrd)   (or equivalent "ps" command)
13:48:56 (lmgrd) and kill the "snpslmd" process.
```


&#160; &#160; &#160; &#160; 说启动了多个snpslmd，但是又kill不掉。

&#160; &#160; &#160; &#160; 首先去snpslmd所在目录`scl/amd64/bin/`下新建文件“[gen-snpslmd-hack.c](https://github.com/Verdvana/Verdvana.github.io/blob/master/_posts/Synopsys%20EDA%20Tools%E5%AE%89%E8%A3%85%E4%B8%AD%E5%87%BA%E7%8E%B0%E7%9A%84%E9%97%AE%E9%A2%98%E5%8F%8A%E8%A7%A3%E5%86%B3%E6%96%B9%E6%B3%95/gen-snpslmd-hack.c)”，文件内容为：
```c
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <dirent.h>
#include <dlfcn.h>
#include <string.h>

static int is_root = 0;
static int d_ino = -1;

static DIR *(*orig_opendir)(const char *name);
static int (*orig_closedir)(DIR *dirp);
static struct dirent *(*orig_readdir)(DIR *dirp);

DIR *opendir(const char *name)
{
	if (strcmp(name, "/") == 0)
		is_root = 1;
	return orig_opendir(name);
}

int closedir(DIR *dirp)
{
	is_root = 0;
	return orig_closedir(dirp);
}

struct dirent *readdir(DIR *dirp)
{
	struct dirent *r = orig_readdir(dirp);
	if (is_root && r)
	{
		if (strcmp(r->d_name, ".") == 0)
			r->d_ino = d_ino;
		else if (strcmp(r->d_name, "..") == 0)
			r->d_ino = d_ino;
	}
	return r;
}

static __attribute__((constructor)) void init_methods()
{
	orig_opendir = dlsym(RTLD_NEXT, "opendir");
	orig_closedir = dlsym(RTLD_NEXT, "closedir");
	orig_readdir = dlsym(RTLD_NEXT, "readdir");
	DIR *d = orig_opendir("/");
	struct dirent *e = orig_readdir(d);
	while (e)
	{
		if (strcmp(e->d_name, ".") == 0)
		{
			d_ino = e->d_ino;
			break;
		}
		e = orig_readdir(d);
	}
	orig_closedir(d);
	if (d_ino == -1)
	{
		puts("Failed to determine root directory inode number");
		exit(EXIT_FAILURE);
	}
}
```

&#160; &#160; &#160; &#160; 然后使用如下命令编译：
```sh
gcc -ldl -shared -fPIC gen-snpslmd-hack.c -o snpslmd-hack.so
```

&#160; &#160; &#160; &#160; 这里可能要安装gcc：

```sh
sudo zypper install gcc
```

&#160; &#160; &#160; &#160; 接着关闭lmgrd：
```sh
lmdown
```

&#160; &#160; &#160; &#160; 在lmgrd所在路径下执行如下命令激活证书：
```sh
LD_PRELOAD=./snpslmd-hack.so ./lmgrd -c /usr/software/synopsys/license/Synopsys.dat
```

&#160; &#160; &#160; &#160; 如果激活成功，可以把环境变量里激活的指令换成：
```sh
alisa crack='LD_PRELOAD=/usr/software/synopsys/scl/scl/2018.06/linux64/bin/snpslmd-hack.so lmgrd -c /usr/software/synopsys/license/Synopsys.dat'
```


&#160; &#160; &#160; &#160; 但这样激活成功后，verdi会打不开，启动verdi时terminal返回：
```sh
Segmentation fault (core dumped)
```


&#160; &#160; &#160; &#160; 后来我发现出现这种情况是因为之前设定的`LD_PRELOAD`环境变量影响了verdi的启动，所以在每次激活后再加一句如下指令即可：
```sh
unsetenv LD_PRELOAD
```

### 3.7 无法启动GUI（OpenSUSE）

&#160; &#160; &#160; &#160; 在OpenSUSE中可能会无法启动PrimeTime的GUI，terminal返回：

```sh
The connection to X-server '0.0' is broken or refused.
```


&#160; &#160; &#160; &#160; 这种情况需要设置`DISPLAY`这个环境变量的内容。在环境变量里添加：
```sh
setenv  DISPLAY :0    #tcsh\csh
```

&#160; &#160; &#160; &#160; 或

```sh
export DISPLAY=:0     #bash
```
----

## 4 EDA Tools使用过程中遇到的问题

### 4.1 

----
&#160; &#160; &#160; &#160; 告辞。