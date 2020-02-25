---
layout: post
title:  "在Quartus Prime 17.1以上版本中添加Frame Reader IP核"
date:   2019-1-2 18:57:10 +0700
tags:
  - SoC
  - FPGA
---


-------
### 1.前言

&#160; &#160; &#160; &#160; 想在硬核上挂载一块VGA协议的TFT屏幕（5寸800*480），需要在Platform Designer中添加图像帧缓存读取控制器（Frame Reader）和VGA控制器（Clocked Video Output Intel FPGA IP）的IP核。但是17.1版本之后图像帧缓存读取控制器被整合到Frame Buffer Ⅱ (4K) Ready Intel FPGA IP中，使用这个IP核时需要修改参数，但是最后综合完之后会发现这个IP核需要另外的License，否则生成的 *.sof 文件无法使用。早说啊，真坑。


&#160; &#160; &#160; &#160; 明明旧版本的Frame Reader是不需要License的啊。看来只能从早期版本的Quartus中把这个Frame Reader IP抠出来添加到新版本里了。找了半天发现其实新版本Quartus的安装路径下就有Frame Reader的IP核文件。路径为"..\intelFPGA\18.1\ip\altera\frame_reader\full_ip"。这里边会有一个“Frame Reader”的文件夹，就是这个IP核所需的文件。接下来就要将他添加到Platform Designer中去。

* 开发环境：Quartus Prime Standard Edition 18.1
* 系统版本：Windows 10 Pro x64 1809

-------

### 2.添加Frame Reader IP核到Platform Designer


&#160; &#160; &#160; &#160; 其实看过我另一篇文章[《自定义数码管IP核，并让NiosⅡ SBT for Eclipse自动抓取驱动文件》](http://verdvana.top/sopc/nios%20%E2%85%B1/ip/fpga/2018/12/19/creat-a-digital-tube-controller-IP.html)基本就知道怎么添加了。



&#160; &#160; &#160; &#160; 打开Quartus Prime，打开Platform Designer，直接点击IP核目录下Project里的“New Component...”。

![1](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/create-a-digital-tube-controller-IP/1.jpg)

&#160; &#160; &#160; &#160; 打开文件。

![1](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E6%B7%BB%E5%8A%A0Frame%20Reader%20IP%E6%A0%B8/1.jpg)

&#160; &#160; &#160; &#160; 找到刚才提到的Frame Reader IP路径下的*.tcl文件，打开它。

<details>
  <summary>不用返回去看路径了，这儿也有</summary>
"..\intelFPGA\18.1\ip\altera\frame_reader\full_ip"
</details>


&nbsp;


![2](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E6%B7%BB%E5%8A%A0Frame%20Reader%20IP%E6%A0%B8/2.jpg)

&#160; &#160; &#160; &#160; 将“alt_vipvfr131_vfr.v”设置成顶层文件，然后分析。

![3](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E6%B7%BB%E5%8A%A0Frame%20Reader%20IP%E6%A0%B8/3.jpg)

&#160; &#160; &#160; &#160; 将信号修改成下图的模式，并且为总线添加时钟和复位信号。遇到错误时按照Message中的提示修改就行。最后“Finish”。

![4](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E6%B7%BB%E5%8A%A0Frame%20Reader%20IP%E6%A0%B8/4.jpg)

&#160; &#160; &#160; &#160; 这样就将旧版中的Frame Read IP添加到新版本的Platform Designer中了。在IP核列表中可以看到它。

![5](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E6%B7%BB%E5%8A%A0Frame%20Reader%20IP%E6%A0%B8/5.jpg)

&#160; &#160; &#160; &#160; 至于如何使用Frame Reader IP，可以参考小梅哥的SoC教程。


-----

&#160; &#160; &#160; &#160; 告辞。
