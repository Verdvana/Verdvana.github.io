---
layout: post
title:  "在DS-5中使用网口调试Linux应用程序（基于DE10-Nano）"
date:   2019-4-16 10:50:10 +0700
tags:
  - SoC
---

-------
### 1.前言

&#160; &#160; &#160; &#160; 有关使用DS-5调试Linux应用程序，先后参考了DE1-SoC培训手册和小梅哥的《基于SoC FPGA的嵌入式设计和开发教程》。发现都不行。

&#160; &#160; &#160; &#160; DE1-SoC培训手册中首先是裸机调试，不适用Linux应用程序。其次他是用USB-Blaster调试，需要DS-5的License。

&#160; &#160; &#160; &#160; 小梅哥的SoC教程里用了不需要License的网口调试，但可能是版本原因，我找不到“DS-5配置调试时候找不到gebserver选项”这个解决方法中的选项（真绕），所以也没法进行下去。


* 开发环境：
	* DS-5 Ultimate Edition v5.29.1
* 操作系统：
	* Windows 10 Pro 1809

------------------

### 2.新建工程

&#160; &#160; &#160; &#160; 打开DS-5，选好Workspace，新建C工程：

![1](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/1.jpg)

&#160; &#160; &#160; &#160; 新建C源文件，保存为*.c：

![2](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/2.jpg)

![3](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/3.jpg)


&#160; &#160; &#160; &#160; 编写打印“Hello World”代码：

```c
#include <stdio.h>

int main (int argc, char *argv[])
{
    printf("hello world\n" );
    return 0;
}

```

&#160; &#160; &#160; &#160; 保存，编译，会生成可执行文件：

![4](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/4.jpg)

-------------------

### 3.启动SoC，修改密码

&#160; &#160; &#160; &#160; 打开Putty，配置好串口参数，给DE10-Nano插上串口USB和网线，上电，启动Linux。
![5](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/5.jpg)

&#160; &#160; &#160; &#160; 输入用户名“root”登录，输入以下代码来设置密码：

```shell
passwd
```
&#160; &#160; &#160; &#160; 输入两次密码，修改密码成功：

![6](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/6.jpg)


&#160; &#160; &#160; &#160; 这一步在后面的连接中是必要的。

&#160; &#160; &#160; &#160; 输入以下代码查看开发板的IP地址：

```shell
ifconfig
```
&#160; &#160; &#160; &#160; 可以在如图位置查看开发板的IP地址，记住它：
![11](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/11.jpg)

-------------------------------------

### 4.建立SSH远程连接

&#160; &#160; &#160; &#160; 在DS-5中新建“Remote System Explorer”：

![7](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/7.jpg)

&#160; &#160; &#160; &#160; 选择“Connection”：

![8](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/8.jpg)

&#160; &#160; &#160; &#160; 选择“SSH Only”：

![9](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/9.jpg)

&#160; &#160; &#160; &#160; 在“Host Name”一栏填写刚才得到的IP地址，选择“Finish”完成建立：

![10](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/10.jpg)

&#160; &#160; &#160; &#160; 添加视图。点击Windows->Prespective->Open Prespective->Other:

![12](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/12.jpg)

&#160; &#160; &#160; &#160; 选择“Remote System Explorer”，点OK:

![13](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/13.jpg)

&#160; &#160; &#160; &#160; 在Remote System Explorer界面中右键单击连接名称，选择“Connect”：

![14](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/14.jpg)

&#160; &#160; &#160; &#160; 在弹出的界面中输入刚才登陆Linux的账号和密码，点“OK”：

![15](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/15.jpg)

&#160; &#160; &#160; &#160; 可以看到连接上出现了了蓝绿色图标，表明连接已建立：

![16](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/16.jpg)

----------

### 5.远程调试

&#160; &#160; &#160; &#160; 点击“Run”，选择“Debug Configurations...”：

![17](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/17.jpg)


&#160; &#160; &#160; &#160; 双击“DS-5 Debugger”新建调试项；修改调试名称；在“Connection”选项卡中设置“Select target”对应的调试对象；在“RSE connectior”选择之前的IP地址：

![18](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/18.jpg)


&#160; &#160; &#160; &#160; 在“Files”选项卡中，单击“Workspace...”选择编译生成的可执行文件“hello”；在“Target download directory”和“Target working directory”中输入如下地址：

```shell
/home/root
```
&#160; &#160; &#160; &#160; 点击“Debug”开始调试：

![19](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/19.jpg)



&#160; &#160; &#160; &#160; 随后会进入调试界面进行调试。点击绿色三角运行程序：

![20](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/20.jpg)

&#160; &#160; &#160; &#160; 可以看出在控制端中打印出“Hello World”：

![21](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9C%A8DS-5%E4%B8%AD%E4%BD%BF%E7%94%A8%E7%BD%91%E5%8F%A3%E8%B0%83%E8%AF%95Linux%E5%BA%94%E7%94%A8%E7%A8%8B%E5%BA%8F%EF%BC%88%E5%9F%BA%E4%BA%8EDE10-Nano%EF%BC%89/21.jpg)

&#160; &#160; &#160; &#160; 调试成功。


----------

&#160; &#160; &#160; &#160; 告辞。

