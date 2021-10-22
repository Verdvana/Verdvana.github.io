---
layout: post
title:  "Design Compiler综合操作"
date:   2020-3-15 21:36:10 +0700
tags:
  - Digital IC Design
  - Synthesis
  - Tcl
---

-------

## 1 前言 

&#160; &#160; &#160; &#160; 以综合AXI4_Interconnect为例，记录综合全过程。

* 开发环境：
	* Design Compiler 2016
* 操作系统：
	* Ubuntu 18.04 LTS

----

## 2 前期准备

&#160; &#160; &#160; &#160; Ubuntu的安装与使用、工艺库的下载、Design Compiler安装等必要准备在这就不说了。

### 2.1 工程目录

&#160; &#160; &#160; &#160; 首先建立工程目录，以AXI4_Interconnect为例：
* AXI4_Interconnect
    * config：配置文件；
    * library：工艺库；
    * mapped：map过的网表文件；
    * report：综合后的报告；
    * rtl：RTL代码；
    * script：tcl约束指令；
    * unmapped：未map的网表文件；
    * work：DC启动文件等。

&#160; &#160; &#160; &#160; 将下载好的工艺库放入“library”文件夹；将功能仿真之后的RTL代码放入“RTL”文件夹。

&#160; &#160; &#160; &#160; 在“work”文件夹下新建“.synopsys_dc.setup”文件。从此路径启动DC的话会优先从该配置文件读取配置信息，而不是使用默认配置。

&#160; &#160; &#160; &#160; 编辑配置信息：

```tcl
echo "***********************************************************"
echo "************** Start load .synopsys_dc.setup **************"
echo "***********************************************************"

set SYN_ROOT_PATH       /media/verdvana/Project/IC_Synthesis/AXI4_Interconnect
set RTL_PATH            $SYN_ROOT_PATH/rtl
set CONFIG_PATH         $SYN_ROOT_PATH/config
set SCRIPT_PATH         $SYN_ROOT_PATH/scirpt
set MAPPED_PATH         $SYN_ROOT_PATH/mapped
set REPORT_PATH         $SYN_ROOT_PATH/report
set UNMAPPED_PATH       $SYN_ROOT_PATH/unmapped


# 设置工作路径

set WORK_PATH           /media/verdvana/Project/IC_Synthesis/AXI4_Interconnect/work
set DC_PATH             /usr/synopsys/dc2016

set SYMBOL_PATH         /media/verdvana/Project/IC_Synthesis/AXI4_Interconnect/library/symbols
set LIB_PATH            /media/verdvana/Project/IC_Synthesis/AXI4_Interconnect/library/synopsys

# 设置工艺库

set_app_var search_path     [list . $search_path    $LIB_PATH   \
                                    $SYMBOL_PATH    $RTL_PATH   \
                                    $SCRIPT_PATH                \
                                    ${DC_PATH}/libraries/syn]
set_app_var target_library  [list   typical.db fast.db slow.db]
set_app_var link_library    [list   * typical.db fast.db slow.db]
set_app_var symbol_library  [list   smic18.sdb]
set_app_var synthetic_library []

echo "***********************************************************"
echo "************* End of load .synopsys_dc.setup **************"
echo "***********************************************************"

echo "***********************************************************"
echo "************** Start source hs_name_rules.v ***************"
echo "***********************************************************"

source -v -e    ./hs_name_rules.tcl

echo "***********************************************************"
echo "************* End of source hs_name_rules.v ***************"
echo "***********************************************************"
```

&#160; &#160; &#160; &#160; 主要包括设置工作路径和设置工艺库。Tcl很好懂，不同工程不同路径做一些修改就行。

### 2.2 DC启动脚本

&#160; &#160; &#160; &#160; DC启动之前需要启动SCL，并且需要进入工程目录，虽说这总共就三行指令，那我也记不住，所以写了一个脚本自动完成：

```tcl
#！ /bin/bash
cd /media/verdvana/Project/IC_Synthesis/AXI4_Interconnect/work
lmstat -c /usr/synopsys/license/synopsys.dat
lmgrd -c /usr/synopsys/license/synopsys.dat
echo "START"
dc_shell | tee dc_start.log
```

&#160; &#160; &#160; &#160; 除了注释以外的第一行是工程路径，不同工程作相应修改；后面两行全宇宙通用。最后两行是打印启动信息和启动DC。

&#160; &#160; &#160; &#160; 保存成“*.sh”文件即可，每次打开终端后先进入管理员模式：

```sh
sudo -i
```

&#160; &#160; &#160; &#160; 然后进入脚本所在路径，通过“source”指令运行脚本：

```sh
source      ./Synopsys.sh
```
&#160; &#160; &#160; &#160; 不出意外，DC会启动并加载之前设定好的配置文件：

![1](./Design%20Compiler%E7%BB%BC%E5%90%88%E6%93%8D%E4%BD%9C/1.png)

----

## 3 设计约束

&#160; &#160; &#160; &#160; 这一部分其实也需要提前准备，但是太多了，就搁这儿了。

### 3.1 添加设计文件

&#160; &#160; &#160; &#160; 综合首先要读取RTL文件。读取文件有两种方式，一种是用read指令来读入，一种是同时使用analyze和elaborate指令，两者区别见[Design Compiler入门](https://verdvana.cn/_posts/2020-01-26-Design-Compiler%E5%85%A5%E9%97%A8/)一文。我习惯用read指令：

```tcl
# 宏定义
set TOP_MODULE	    AXI4_Interconnect;        # 定义顶层文件名
# 读文件
read_sverilog	-rtl    [list    AXI_Arbiter_R.sv  \
                                                   AXI_Arbiter_W.sv   \
                                                   AXI_Arbiter.sv  \
                                                   AXI_Master_Mux.sv  \ AXI_Slave_Mux.sv  \
                                                   AXI4_Interconnect.sv]
#设置顶层文件
current_design  $TOP_MODULE
```
&#160; &#160; &#160; &#160; 这样就把RTL代码全部读进去并且设置好了顶层文件。

### 3.2 检查与复位

&#160; &#160; &#160; &#160; 在配置信息那一步配置了工艺库的路径，现在可以检查一下是否成功；另外也可以检查一下RTL文件的语法错误：

```tcl
# 检查link
if {[link] == 0} {
    echo "Link Error!";
    exit;
}

# 检查语法
if {[check_design] == 0} {
    echo "Check Design Error!";
    exit;
}
```
&#160; &#160; &#160; &#160; 另外如果不是第一次约束该工程，又怕被之前的约束信息所影响，可以复位约束：

```tcl
reset_design
```

### 3.3 时序约束

&#160; &#160; &#160; &#160; 时序约束主要是告诉DC时钟的周期、SKEW等属性然后建立这个时钟：

```tcl
# 宏定义
set     CLK_NAME            ACLK
set     CLK_PERIOD          2
set     CLK_SKEW            [expr   $CLK_PERIOD*0.05]
set     CLK_TRAN            [expr   $CLK_PERIOD*0.01]
set     CLK_SRC_LATENCY     [expr   $CLK_PERIOD*0.1]
set     CLK_LATENCY         [expr   $CLK_PERIOD*0.1]

# 新建时钟
create_clock                -period $CLK_PERIOD         [get_ports  $CLK_NAME]
# 设置为理想时钟（默认的，不加也行）
set_ideal_network                                       [get_ports  $CLK_NAME]
set_dont_touch_network                                  [get_ports  $CLK_NAME]
# 设置驱动源
set_drive                           0                   [get_ports  $CLK_NAME]
# 建立时钟树模型
set_clock_uncertainty       -setup  $CLK_SKEW           [get_ports  $CLK_NAME]
set_clock_transition        -max    $CLK_TRAN           [get_ports  $CLK_NAME]
set_clock_latency -source   -max    $CLK_SRC_LATENCY    [get_ports  $CLK_NAME]
set_clock_latency           -max    $CLK_LATENCY        [get_ports  $CLK_NAME]
```


### 3.4 复位设置

&#160; &#160; &#160; &#160; 复位信号也需要建立：

```tcl
set     RST_NAME                ARESETn

# 设置
set_ideal_network                                       [get_ports  $RST_NAME]
set_dont_touch_network                                  [get_ports  $RST_NAME]
set_drive                           0                   [get_ports  $RST_NAME]
```

### 3.5 输入延迟设置

&#160; &#160; &#160; &#160; 然后是设定IC外部输入的延迟和驱动模型等：

```tcl
# 宏定义
set     LIB_NAME            typical
set     WIRE_LOAD_MODEL     smic18_wl10
set     DRIVE_CELL          DFFHQX1
set     DRIVE_PIN           Q
set     OPERA_CONDITION     typical
set     ALL_IN_EXCEPT_CLK   [remove_from_collection [all_inputs] [get_ports $CLK_NAME]]
set     INPUT_DELAY         [expr   $CLK_PERIOD*0.6]

# 设置延迟
set_input_delay     $INPUT_DELAY    -clock  $CLK_NAME   $ALL_IN_EXCEPT_CLK
#set_input_delay     -min    0       -clock  $CLK_NAME   $ALL_IN_EXCEPT_CLK
set_driving_cell    -lib_cell   ${DRIVE_CELL}   -pin    ${DRIVE_PIN}    $ALL_IN_EXCEPT_CLK
```

### 3.6 输出延迟设置

&#160; &#160; &#160; &#160; 输出的延迟和负载也需要设置：

```tcl
# 宏定义
set     OUTPUT_DELAY        [expr   $CLK_PERIOD*0.6]
set     MAX_LOAD            [expr   [load_of  $LIB_NAME/DFFHQX1/D] *1]

# 设置延迟
set_output_delay    $OUTPUT_DELAY   -clock  $CLK_NAME   [all_outputs]
set_load                    [expr   $MAX_LOAD*1]        [all_outputs]
# 输出端口插入隔离单元，这里是插入缓存单
set_isolate_ports   -type   buffer                      [all_outputs] 
```

### 3.7 操作条件和线负载模型

&#160; &#160; &#160; &#160; 设置线负载模型：

```tcl
# 設置操作条件
set_operating_condition -max            $OPERA_CONDITION    \
                        -max_library    $LIB_NAME
# 关闭自动选择线负载模型
set     auto_wire_load_selection        false
# 设置线负载模式
set_wire_load_mode      top 
# 设置线负载模型
set_wire_load_model     -name           $WIRE_LOAD_MODEL \
                        -library        $LIB_NAME
```

### 3.8 面积约束

&#160; &#160; &#160; &#160; 对面积大小没啥概念，都是瞎逼设置的。要让DC综合后的面积尽量小，可以设为0，只不过违例报告中肯定会有面积违例这一条：

```tcl
set_max_area            0
```


### 3.9 设置分组

&#160; &#160; &#160; &#160; 可以对不同类型的路径设置分组，让DC分别优化：

```tcl
# 時鐘分組
group_path      -name       $CLK_NAME   -weight	5               			-critical_range [expr $CLK_PERIOD *0.1]
# 輸入路徑（包含輸入路徑中的組合電路）分組
group_path      -name       INPUTS      -from	[all_inputs]    			-critical_range [expr $CLK_PERIOD *0.1]
# 輸出路徑（包含輸出路徑中的組合電路）分組
group_path      -name       OUTPUTS     -to	[all_outputs]   			-critical_range [expr $CLK_PERIOD *0.1]
# 輸入與輸出路徑上的組合電路分組
group_path      -name       COMB        -from	[all_inputs]    -to	[all_outputs]	-critical_range [expr $CLK_PERIOD *0.1]
# 報告分組情況
#report_path_group
```

&#160; &#160; &#160; &#160; 最后报告最差路径等，也会分组报告。

### 3.10 消除多端口互联

&#160; &#160; &#160; &#160; 一些其他约束：

```tcl
set_app_var     verilogout_no_tri                       ture
set_app_var     verilogout_show_unconnected_pins        ture        ;# 显示寄存器未用到的Q非端口
set_app_var     bus_naming_style                        { %s[%d] }

simplify_constants          -boundary_optimization                  ;# 边界优化
# 相同net插buffer
set_fix_multiple_port_nets  -all                        -buffer_constants
```

### 3.11 綜合

&#160; &#160; &#160; &#160; 综合命令就一条，但是有很多不同的附加指令：

```tcl
#compile
compile     -map_effort high    -area_effort    high 
#compile     -map_effort high    -area_effort    medium
#compile     -map_effort hign    -area_effort    high    -boundary_optimization
#compile     -map_effort hign    -area_effort    high    -scan 
```

### 3.12 生成报告文件

&#160; &#160; &#160; &#160; 报告约束信息并写到“report”文件夹里：

```tcl
report_constraint -all_violators

report_timing -delay_type   max

redirect    -tee    -file   ${REPORT_PATH}/check_design.txt         {check_design}
redirect    -tee    -file   ${REPORT_PATH}/check_timing.txt         {check_timing}
redirect    -tee    -file   ${REPORT_PATH}/report_constraint.txt    {report_constraint  -all_violators}
redirect    -tee    -file   ${REPORT_PATH}/check_setup.txt          {report_timing      -delay_type     max}
redirect    -tee    -file   ${REPORT_PATH}/check_hold.txt           {report_timing      -delay_type     min}
redirect    -tee    -file   ${REPORT_PATH}/report_area.txt          {report_area}
```

----

## 4 运行约束

&#160; &#160; &#160; &#160; 回到刚刚打开DC的终端。现在DC的路径是工程路径中的“work”文件夹。而需要运行的约束在“script”文件夹中，所以运行指令：

```sh
source  ../script/AXI4_Interconnect.tcl
```

&#160; &#160; &#160; &#160; 之前写好的约束指令便会一条一条排队执行，最后生成报告：

![2](./Design%20Compiler%E7%BB%BC%E5%90%88%E6%93%8D%E4%BD%9C/2.png)


&#160; &#160; &#160; &#160; 要启动图形界面的话在dc_shell里输入：
```sh
gui_start
```

----
&#160; &#160; &#160; &#160; 告辞