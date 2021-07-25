---
layout: post
title:  "VS Code环境下克隆GiHub仓库"
date:   2021-7-25 12:36:10 +0700
tags:
  - Others
---

-------

## 1 前言

&#160; &#160; &#160; &#160; 

* 开发环境：
	* Visula Studio Code
* 操作系统：
	* Windows 11 Pro 21H2

&#160; &#160; &#160; &#160; 需要安装：

* [Visula Studio Code](https://code.visualstudio.com/#alt-downloads)；
* [Git](https://git-scm.com/download/win)。

----

## 2 安装

&#160; &#160; &#160; &#160; So easy。

----

## 3 Clone

### 3.1 登录GitHub

&#160; &#160; &#160; &#160; 组合键“Ctrl+`”打开终端，输入如下指令：

```sh
git config --global user.name "<用户名>"
git config --global user.email "<邮箱>"
```

### 3.2 Clone

&#160; &#160; &#160; &#160; 可以直接在终端里输入如下指令clone：

```sh
git clone <仓库地址>
```

&#160; &#160; &#160; &#160; 但有时候通过这种方式clone下来的仓库在同步时会出现“Time out”之类的错误。采用图形化界面lone好像可以解决。在VSCode左侧的“源代码管理”标签里打开“更多操作”：





### 3.3 同步

&#160; &#160; &#160; &#160; 可能会出现如下错误：

![img1][img1]

&#160; &#160; &#160; &#160; 这有可能是代理设置问题，可以在终端输入如下指令取消代理设置：

```sh
git config --global --unset http.proxy
git config --global --unset https.proxy
```


----
&#160; &#160; &#160; &#160; 告辞。

[img1]: