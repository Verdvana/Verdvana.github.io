---
layout: post
title:  "Synopsys TCL"
date:   2020-2-3 19:29:10 +0700
tags:
  - Tcl
  - Synthesis
--- 

-------

### 1 前言 

&#160; &#160; &#160; &#160; 根据邸志雄老师的[芯动力——硬件加速设计方法
](https://www.icourse163.org/learn/SWJTU-1207492806?tid=1207824209#/learn/announce)课程中“掌握Synopsys TCL语言”一节记录。


----

### 2 TCL組成

&#160; &#160; &#160; &#160; 对于IC设计来讲，TCL语言分为三个部分：
* TCL本身的内建指令；
* Synopsys公司EDA工具自定义的指令；
* 用户自定义指令。

----

### 3 object

&#160; &#160; &#160; &#160; 和SystemVerilog类似。

&#160; &#160; &#160; &#160; object分为以下六类：
* design；
* cell；
* ports；
* pins；
* nets；
* clocks。

&#160; &#160; &#160; &#160; 各含义见[Design Compiler入门](https://verdvana.top/digital%20ic%20design/2020/01/26/Design-Compiler%E5%85%A5%E9%97%A8.html)的第二节。

----

### 4 attributes

&#160; &#160; &#160; &#160; attributes是objects的属性。各个object有以下属性：
* ports：
    * diretion；
    * driving_cell_rise；
    * load；
    * max_capacitance；
    * 等等；
* cell：
    * dont_touch；
    * is_hierarchical；
    * is_mapped；
    * is_sequential；
    * 等等。 

&#160; &#160; &#160; &#160; 下面举例说明。


#### 4.1 port

&#160; &#160; &#160; &#160; 查看design中有没有port叫做CLK：

```shell
shell> get_port CLK
```

&#160; &#160; &#160; &#160; 查看design中所有的port：

```shell
shell> get_port *
```

&#160; &#160; &#160; &#160; 查看design中C开头的port：

```shell
shell> get_port C*
```

&#160; &#160; &#160; &#160; 属性direction：用来保存port的方向：

```shell
shell> get_attribute [get_port A] direction
```

&#160; &#160; &#160; &#160; 得到所有方向是input的port：

```shell
shell> get_port *-f "direction==in"
```


#### 4.2 cell

&#160; &#160; &#160; &#160; 和PORT类似。

&#160; &#160; &#160; &#160; 属性ref_name用来保存起map到的refence cell名称：

```shell
shell> get_attribute [get_cells -h U3] ref_name
```

&#160; &#160; &#160; &#160; 得到所有ref_name是INV的cell：

```shell
shell> get_cells *-f "ref_name==INV"
```


#### 4.3 nets

&#160; &#160; &#160; &#160; 查看design当中有多少个net（TCL本身指令）

```shell
shell> llength [get_object_name[get_nets *]] 
```

&#160; &#160; &#160; &#160; 或（Synopsys TCL指令）：

```shell
shell> sizeof_collection [get_nets *]
```

&#160; &#160; &#160; &#160; 属性owner_net：用来保存与之相连的net的名称：

```shell
shell> get_arrtibute [get_pins U2/A] owner_net 
```

&#160; &#160; &#160; &#160; 属性full_name：用来保存net的名称：

```shell
shell> get_attribute [get_nets INV0] full_name
```

&#160; &#160; &#160; &#160; NET和PORT之间的联系：

```shell
shell> get_nets -of [get_port A]
```

&#160; &#160; &#160; &#160; 其他和PORT类似。



#### 4.4 pins

&#160; &#160; &#160; &#160; 查看design当中有哪些pin的名字叫Z：

```shell
shell> get_pins */Z
```

&#160; &#160; &#160; &#160; 查看design当中有哪些pin的名字以Q开头：

```shell
shell> get_pins */Q*
```




----
&#160; &#160; &#160; &#160; 告辞