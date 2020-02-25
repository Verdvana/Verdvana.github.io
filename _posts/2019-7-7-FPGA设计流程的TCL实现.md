---
layout: post
title:  "FPGA设计流程的TCL实现"
date:   2019-7-7 17:23:10 +0700
tags:
  - Tcl
---

-------
### 1 前言

&#160; &#160; &#160; &#160; 最一开始接触TCL文件是FPGA分配引脚，比图形化界面分配引脚更快捷。TCL（Tool Command Language）是一种脚本语言，类似DOS下的批处理文件。发明TCL语言的初衷是：

> &#160; &#160; &#160; &#160; 传统的软件操作通常都是基于图形界面的，完成完整的功能必须经过多个步骤，而这些工作必须通过人工操作才能完成，并且容易出错。当新手开始学习此类基于图形界面的操作时，往往要经过很长时间的操作才能保证不会出错。此外，由于在人机交互中，如果机器执行命令的时间很长，人就处于空闲状态，效率很低，而且还需要随时等待本步骤的执行完成。


&#160; &#160; &#160; &#160; 如果将这类操作过程用文件记录下来，既能随时回放操作，又能支持编辑修改，还可以通过单步执行反复调试，从而能够极大地提高工作效率，降低工作强度，并能对以前的操作形成知识积累。TCL就是基于上述思想设计的工具操作语言。目前的EDA软件均支持TCL操作，无须人工在图形界面上单击菜单即可完成全部软件功能。例如Synopsys从仿真验证与综合到最终的GDS II流片，所有的操作文件都可以归结为一套TCL包，通过运行几个简单的TCL命令完成。

----------

### 2 Quartus对TCL的支持

&#160; &#160; &#160; &#160; Quartus支持TCL脚本运行（Xilinx的TCL功能类似）。目前有两种运行方式，一种是直接在命令行启动命令：quartus_sh -s；另外一种是在Quartus图形界面下，直接按Alt+2键，启动TCL控制台。

----

### 3 FPGA实现流程的TCL版本

&#160; &#160; &#160; &#160; 在FPGA中，完成一次综合的流程大致如下：

* 建立缺省工程，设定目标器件；
* 添加各种文件和库；
* 添加各类约束，例如关键I/O约束和时钟约束；
* 运行综合与布局布线。

&#160; &#160; &#160; &#160; 而这些过程都可以通过TCL脚本一次性完成。

#### 3.1 工程建立

&#160; &#160; &#160; &#160; 对于建立一个标准工程，可以按照如下的脚本函数完成：
```tcl
proc create_project {}{  
    global project_name　  #建立工程名称  
    global work_root       #进入工作目录的根目录下  
    cd${work_root}  
        if\[project_exists $project_name\]{  
　          project_open $project_name  #打开工程  
        }else{  
　          project_new $project_name   #新建工程  
        }  
} 
```
&#160; &#160; &#160; &#160; 设定当前的目标器件，可通过如下的语句完成：

```tcl
set_global_assignment-name FAMILY "Cyclone III"  
set_global_assignment-name DEVICE EP3C80F484C8  
set_global_assignment-name TOP_LEVEL_ENTITY smbus_3c80 
```

&#160; &#160; &#160; &#160; 设定文件库和搜索路径，可以通过如下语句完成：
```tcl
set_global_assignment-name SEARCH_PATH ../../lib 
```

&#160; &#160; &#160; &#160; 而添加文件，只需要下面简单的一句：

```tcl
set_global_assignment-name VERILOG_FILE COREUART.v 
```

&#160; &#160; &#160; &#160; 设定I/O引脚定义，则通过如下命令完成：

```tcl
set_location_assignment PIN_A11-to clk_in  
set_location_assignment PIN_N21-to RESET_N 
```

&#160; &#160; &#160; &#160; 其他的约束文件以及在线调试文件可以通过如下命令完成：

```tcl
set_global_assignment-name ENABLE_SIGNALTAP ON  
set_global_assignment-name SIGNALTAP_FILE stp2.stp  
set_global_assignment-name SDC_FILE smbus.sdc 
```


#### 3.2 运行综合命令

&#160; &#160; &#160; &#160; 对于Quartus而言，设定好工程后，所有的实现命令可以浓缩为如下的命令：

```tcl
execute_flow-compile 
```

&#160; &#160; &#160; &#160; 而综合后的时序结果可以通过如下TCL函数完成，执行的命令为get_fmax_from_report：

```tcl
proc get_fmax_from_report {}{  
global project_name  
　load_report$project_name  
set fmax_panel_name "Timing Analyzer Summary"  
for each panel_name \[get_report_panel_names\]{  
if{\[string match "*$fmax_panel_name*""$panel_name"\]}{  
set fmax_row \[get_report_panel_row "$panel_name"-row1\]  
}  
}  
set actual_fmax \[lindex$fmax_row3\]  
　unload_report$project_name  
return$actual_fmax  
} 
```

&#160; &#160; &#160; &#160; 如果时序不满足，则可以执行::quartus::timing时序验证包命令，获得完整的时序报告，具体包括如下命令：

```tcl
#估算仿真并且报告时序验证，只能在quartus_tan中执行  
　create_timing_netlist  
　report_timing  
　delete_timing_netlist 
```
&#160; &#160; &#160; &#160; 可以发现，通过TCL代码能够非常快捷地实现FPGA软件操作，极大地提高效率。

----
&#160; &#160; &#160; &#160; 告辞。

