---
title:  "自定义数码管IP核，并让NiosⅡ SBT for Eclipse自动抓取驱动文件"
tags:
  - Nios Ⅱ
  - FPGA
  - SOPC
  - Verilog
---

### 1.前言

&#160; &#160; &#160; &#160; 在Platform Designer（原Qsys）中创建自定义六位七段独立数码管IP核并让NiosⅡ SBT for Eclipse自动抓取驱动文件。

* 开发环境：Quartus Prime Standard Edition 18.1
* 系统版本：Windows 10 Pro x64 1809

------
### 2.框架
&#160; &#160; &#160; &#160; 编写IP核首先需要编写HDL形成硬件电路将数码管与NiosⅡ处理器连接起来并通信，然后还需要编写基于C语言的类似STM32中的板级支持包的驱动库函数，可以在SOPC开发中直接应用库函数。不然只能用IO口模拟的方式编程，这样就失去了自定义IP核的意义。

#### 2.1.硬件框架

&#160; &#160; &#160; &#160; 先上一个RTL图看下。

![RTL](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/create-a-digital-tube-controller-IP/RTL.jpg)

&#160; &#160; &#160; &#160; 可以看到硬件电路由三部分组成。

&#160; &#160; &#160; &#160; 首先是“digital_tube_avalon_slaver”，NiosⅡ处理器直接与这个模块相连并通过[Avalon总线](http://www.eepw.com.cn/article/201703/345268.htm)通信。所以这里需要添加符合Avalon总线协议的接口，如下表：


| 名称 | 宽度 | 方向 | 说明 |
| ----- | ----- | ----- |  ----- |
| address | 2 &#160;| input| 地址总线 |
| chipselect | 1 &#160;| input| 片选 |
| write_n | 1 &#160;| input | 读/写使能 |
| writedata &#160;&#160;| 32 &#160;&#160;&#160;&#160;&#160;&#160;| input| 要写入数码管的数据 |
| readdata &#160;&#160;| 32 &#160;&#160;&#160;&#160;&#160;&#160;| output&#160; &#160;| 要读进Nios系统中的数据（这里用不到） |

&nbsp;

&#160; &#160; &#160; &#160; 这里边省略了时钟和复位信号。

* address：宽度不一定是2位，一般是用于选择writedata信号写出去的是什么含义。因为写数据总线（writedata）只有一个，但有时候想写命令有时候想写数据等等，这时通过address的变化就可以区分出writedata到底要往外设写命令还是数据还是别的什么。例如address为0时writedata上要写给外设命令；address为1时writedata上要写给外设数据。

* chipselect：使能信号，高电平选中。

* write_n：用来控制这个模块是往出写还是往进读。由于这是个数码管IP，只可能往出写，所以在这跟片选信号几乎一样。

* writedata：这个信号的宽度是固定的：32bit，用不到的位置零就好；不够用的话......我也不知道咋办。它负责把数码管要显示的数字输出出去。

* readdata：这个信号的宽度是固定的：32bit，读数据，这里用不到。

&#160; &#160; &#160; &#160;这里需要计算一下：要显示六位的数字，那最大就是999999，转换为二进制就是‭1111_0100_0010_0011_1111，可以看到是20位宽度，所以writedata只用到了低20位。‬

&#160; &#160; &#160; &#160;  然后就是自定义的接口：

| 名称 | 宽度 | 方向 | 说明 |
| ----- | ----- | ----- |  ----- |
| display_enble &#160;&#160;| 1 &#160;| output| 显示使能 |
| display_num | 20 &#160;&#160;&#160;&#160;&#160;&#160;| output&#160; &#160;| 需要数码管显示的数（二进制） |

&nbsp;

&#160; &#160; &#160; &#160; 很好理解，不说。

&#160; &#160; &#160; &#160; 然后是二进制转BCD码模块。因为我们希望代码里给的是十进制（二进制）数，数码管直接就能把对应的十进制数字打印出来，但是数码管是一位一位的，只认BCD码。所以这里要用到一个二进制转BCD码模块。输入为20位二进制码，输出为24位的BCD码。这里为了便于查看六位数码管各自的通道所以把24位拆成六个4位，本质上一样。

&#160; &#160; &#160; &#160; 最后就是数码管显示模块。它会把BCD码转化为对应的数码管显示信号输出给数码管，完成六位十进制数字的显示。


&nbsp;

#### 2.2.软件框架

&#160; &#160; &#160; &#160; 上图：


![软件框架](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/create-a-digital-tube-controller-IP/softwaer_frame.jpg)




&#160; &#160; &#160; &#160; 可以看出驱动文件由寄存器头文件、函数头文件和函数源文件组成。熟悉单片机的应该对后面两个文件很熟悉了。这里只说寄存器头文件。

&#160; &#160; &#160; &#160; 寄存器头文件就是将直接操作寄存器的函数封装成操作数码管的函数，方便后续的调用。

------

### 3.硬件设计

&#160; &#160; &#160; &#160; 开始写代码了。按照之前介绍的三个模块分别设计。

&#160; &#160; &#160; &#160; 首先是Avalon总线通信模块：

```verilog
module digital_tube_avalon_slaver(
			input 				clk,	//时钟信号
			input 				rst_n,	//复位信号，低电平有效
			
				//Avalon-MM总线
			input 				chipselect,	//片选信号，高电平有效	
			input 				write_n,        //写选通，低电平有效
			input [1:0]			address,        //地址总线	
			input [31:0] 		writedata,	        //写数据总线			
			//output irq,	                        //中断请求信号，高电平有效
			output reg [31:0] readdata,	        //读数据总线,这里边用不到

			output reg   		display_enable, //数码管显示位使能信号，高电平有效
			output reg [19:0] 	display_num			
		);

//-------------------------------------------------
//参数设置

//寄存器定义
//	address = 00		数码管显示数据寄存器，bit31-20:保留；bit19-0:999999以内十进制数字
//	address = 01		数码管显示控制寄存器，bit31-1:保留；bit0:显示


//-------------------------------------------------
//寄存器写入操作

always @(posedge clk or negedge rst_n)
begin
	if (!rst_n) 
		begin
			display_num <= 20'h00000;
			display_enable <= 1'b0;
		end
		
	else if(chipselect && !write_n) 
		begin
			case(address)
				2'b00: display_num <= writedata[19:0];
				2'b01: display_enable <= 1'b1;
				default:display_num<=20'b0;
			endcase
		end	
end

//-------------------------------------------------
//寄存器读操作，写了也没用

always @(posedge clk or negedge rst_n)
begin
	if(!rst_n) 
		readdata <= 32'd0;
		
	else if(chipselect && write_n) 
		begin
			case(address)
				2'b00: readdata <= {12'd0,display_num[19:0]};
				2'b01: readdata <= {31'd0,display_enable};
				default: readdata <= 32'd0;
			endcase
		end
end	

endmodule


```

&#160; &#160; &#160; &#160; 这个模块通过Avalon总线把NiosⅡ发出的数据转换成了后面电路可以识别的20位的二进制码和使能信号。

&#160; &#160; &#160; &#160; 然后是二进制码转BCD码模块：

```
Emmmmmmmmmm
```

&#160; &#160; &#160; &#160; 太长了，去我GitHub看源码吧：[https://github.com/Verdvana/BIN2BCD](https://github.com/Verdvana/BIN2BCD)

&#160; &#160; &#160; &#160; 原理就是加3移位法：将20位二进制码向左移位20次，每次移位都要判断[43:40]，[39:36]，[35:32]，[31:28]，[27:24]，[23:10]这6个4位数是否大于等于0101，如果是则当场左移一位。这儿这个“当场”就要用到阻塞赋值了。完成之后这六个4位数就是要显示的六位数的BCD码。

&#160; &#160; &#160; &#160; 最后就是数码管显示模块：

```
module digital_tube_seg7(
			input 					clk,		
			input 					rst_n,	
			input  					display_enable,		
			input      [23:0]		display_num,	
			output reg [6:0] 		hex0,	
			output reg [6:0] 		hex1,
			output reg [6:0] 		hex2,
			output reg [6:0] 		hex3,
			output reg [6:0] 		hex4,
			output reg [6:0] 		hex5
		);

//-------------------------------------------------
//参数定义

parameter 	NUM0 	= 7'b1000000,//0,
				NUM1 	= 7'b1111001,//1,
				NUM2 	= 7'b0100100,//2,
				NUM3 	= 7'b0110000,//3,
				NUM4 	= 7'b0011001,//4,
				NUM5 	= 7'b0010010,//5,
				NUM6 	= 7'b0000010,//6,
				NUM7 	= 7'b1111000,//7,
				NUM8 	= 7'b0000000,//8,
				NUM9 	= 7'b0011000,//9,
				NULL  = 7'b1111111;






always @(posedge clk or negedge rst_n)
	if(!rst_n) 
		begin
			hex5 <= NUM0;
			hex4 <= NUM0;
			hex3 <= NUM0;
			hex2 <= NUM0;
			hex1 <= NUM0;
			hex0 <= NUM0;
		end
	else 
		begin
			case(display_num[23:20]) 
			4'h0: hex5 <= NUM0;
			4'h1: hex5 <= NUM1;
			4'h2: hex5 <= NUM2;
			4'h3: hex5 <= NUM3;
			4'h4: hex5 <= NUM4;
			4'h5: hex5 <= NUM5;
			4'h6: hex5 <= NUM6;
			4'h7: hex5 <= NUM7;
			4'h8: hex5 <= NUM8;
			4'h9: hex5 <= NUM9;
			default:hex5 <= NULL ;
			endcase
			
			case(display_num[19:16]) 
			4'h0: hex4 <= NUM0;
			4'h1: hex4 <= NUM1;
			4'h2: hex4 <= NUM2;
			4'h3: hex4 <= NUM3;
			4'h4: hex4 <= NUM4;
			4'h5: hex4 <= NUM5;
			4'h6: hex4 <= NUM6;
			4'h7: hex4 <= NUM7;
			4'h8: hex4 <= NUM8;
			4'h9: hex4 <= NUM9;
			default: hex4 <= NULL;
			endcase
			
			case(display_num[15:12]) 
			4'h0: hex3 <= NUM0;
			4'h1: hex3 <= NUM1;
			4'h2: hex3 <= NUM2;
			4'h3: hex3 <= NUM3;
			4'h4: hex3 <= NUM4;
			4'h5: hex3 <= NUM5;
			4'h6: hex3 <= NUM6;
			4'h7: hex3 <= NUM7;
			4'h8: hex3 <= NUM8;
			4'h9: hex3 <= NUM9;
			default: hex3 <= NULL;
			endcase
			
			case(display_num[11:8]) 
			4'h0: hex2 <= NUM0;
			4'h1: hex2 <= NUM1;
			4'h2: hex2 <= NUM2;
			4'h3: hex2 <= NUM3;
			4'h4: hex2 <= NUM4;
			4'h5: hex2 <= NUM5;
			4'h6: hex2 <= NUM6;
			4'h7: hex2 <= NUM7;
			4'h8: hex2 <= NUM8;
			4'h9: hex2 <= NUM9;
			default: hex2 <= NULL;
			endcase
			
			case(display_num[7:4]) 
			4'h0: hex1 <= NUM0;
			4'h1: hex1 <= NUM1;
			4'h2: hex1 <= NUM2;
			4'h3: hex1 <= NUM3;
			4'h4: hex1 <= NUM4;
			4'h5: hex1 <= NUM5;
			4'h6: hex1 <= NUM6;
			4'h7: hex1 <= NUM7;
			4'h8: hex1 <= NUM8;
			4'h9: hex1 <= NUM9;
			default: hex1 <= NULL;
			endcase
			
			case(display_num[3:0]) 
			4'h0: hex0 <= NUM0;
			4'h1: hex0 <= NUM1;
			4'h2: hex0 <= NUM2;
			4'h3: hex0 <= NUM3;
			4'h4: hex0 <= NUM4;
			4'h5: hex0 <= NUM5;
			4'h6: hex0 <= NUM6;
			4'h7: hex0 <= NUM7;
			4'h8: hex0 <= NUM8;
			4'h9: hex0 <= NUM9;
			default: hex0 <= NULL;
			

		endcase
	end



endmodule
```

&#160; &#160; &#160; &#160; 和其他所有数码管显示模块原理都一样，就是个数字转换。这里是共阳极七段数码管。

&#160; &#160; &#160; &#160; 最后用顶层文件把他们组合在一起：

```verilog
module digital_tube_controller(
			input clk,						//时钟信号，25MHz
			input rst_n,					//复位信号，低电平有效
			
				//Avalon-MM总线
			input chipselect,				//片选信号，高电平有效	
			input write_n,					//写选通，低电平有效
			input address,					//地址总线	
			input[31:0] writedata,			//写数据总线			
			//output irq,					//中断请求信号，高电平有效
			output[31:0] readdata,			//读数据总线
			
				//数码管接口
			output  [6:0] 		hex0,	
			output  [6:0] 		hex1,
			output  [6:0] 		hex2,
			output  [6:0] 		hex3,
			output  [6:0] 		hex4,
			output  [6:0] 		hex5
		);

	
		
//-------------------------------------------------
//Avalon-MM总线接口模块
wire  			display_enable;	
wire [19:0] 	display_num;

wire [3:0] 		one;
wire [3:0] 		ten;
wire [3:0] 		hun;
wire [3:0] 		tho;
wire [3:0] 		tth;
wire [3:0] 		trl;	   	

digital_tube_avalon_slaver 	uut_digital_tube_avalon_slaver(
	.clk(clk),						//时钟信号
	.rst_n(rst_n),					//复位信号，低电平有效
							
		//Avalon-MM总线
	.chipselect(chipselect),		//片选信号，高电平有效	
	.write_n(write_n),				//写选通，低电平有效
	.address(address),				//地址总线	
	.writedata(writedata),			//写数据总线			
	//output irq,					//中断请求信号，高电平有效
	.readdata(readdata),			//读数据总线
							
	  //数码管控制信号
	.display_enable(display_enable),//数码管显示位使能信号，高电平有效
	.display_num(display_num)		//数码管显示数据，[15:12]--数码管千位，[11:8]--数码管百位，[7:4]--数码管十位，[3:0]--数码管个位			
);

//-------------------------------------------------
//数码管显示驱动模块
					
digital_tube_seg7		uut_seg7(
	.clk(clk),								//时钟信号
	.rst_n(rst_n),							//复位信号，低电平有效
					
			//数码管控制信号
	.display_enable(display_enable),		//数码管显示位使能信号，高电平有效
	.display_num({trl,tth,tho,hun,ten,one}),				//数码管显示数据，[15:12]--数码管千位，[11:8]--数码管百位，[7:4]--数码管十位，[3:0]--数码管个位	
					
			//数码接口
	.hex5 (hex5),	
	.hex4 (hex4),
	.hex3 (hex3),
	.hex2 (hex2),
	.hex1 (hex1),
	.hex0 (hex0)
  );		


			
bintobcd       uut_bin2bcd(
	.clk(clk),
	.rst_n(rst_n),
	.bin(display_num),  //20位二进制码
						
	.one(one),  //个位
	.ten(ten),  //十位
	.hun(hun),  //百位
	.tho(tho),  //千位
	.tth(tth),  //万位
	.trl(trl)   //兆位

);
	

endmodule
```

&#160; &#160; &#160; &#160; 到此整个电路就搭建好了，综合之后会形成图1那个RTL图。


------

### 4.IP核制作

&#160; &#160; &#160; &#160; 打开Quartus Prime，打开Platform Designer，直接点击IP核目录下Project里的“New Component...”。

![1](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/create-a-digital-tube-controller-IP/1.jpg)

&#160; &#160; &#160; &#160; 在Component Type选项卡里填写IP核信息。

![2](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/create-a-digital-tube-controller-IP/2.jpg)

&#160; &#160; &#160; &#160; 里边的英文单词很简单，也都是字面意思，连我这个六级还没过的渣渣都能看懂（啥时候侥幸过了我就回来删掉这句），所以直接按自己的设定修改就行。

&#160; &#160; &#160; &#160; 在Files选项卡里点击“Add File...”，将刚写的四个*.v文件塞进去，然后将顶层文件设置为“Top-level File”。点击“Analyze Synthesis Files”编译，然后会发现有错误（我这儿是改好的所以没有），后面会修改。

![3](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/create-a-digital-tube-controller-IP/3.jpg)

&#160; &#160; &#160; &#160; 错误发生在Signal&Interfaces选项卡里。里面缺少复位（reset）和管道（conduit）信号。在左边一栏的“add signal”中添加这两个类，然后把相应的信号拖进对应的类里。并且修改“Signal Tpye”值（图片里灰色斜体）。

![5](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/create-a-digital-tube-controller-IP/5.jpg)

&#160; &#160; &#160; &#160; 这里说一下管道信号，管道信号可以理解为NiosⅡ系统中需要作为IO口引到外面的信号。这里需要注意的是，因为有多个管道信号，他们的“Signal Tpye”必须各不相同，否则当前不会报错但是在后续整个系统编译的时候会报错。

&#160; &#160; &#160; &#160; 然后需要将“Avalon slave”和“couduit”这两个类的“Associated Reset”改为复位信号，我这里的复位信号叫“reset”。

![4](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/create-a-digital-tube-controller-IP/4.jpg)

&#160; &#160; &#160; &#160; 理论上没Error了，点击“Finish”保存，默认保存路径为“D:\intelFPGA\18.1\ip”，保存完之后会看到一个*.tcl文件。这时，你的IP核就做好了。想要以后IP目录自动显示出你的IP，需要在的你的Quartus Prime安装路径下面的“ip”文件夹中新建一个文件夹，然后把刚刚的四个*.v文件和*.tcl文件一起放进去，例如我这样：

![6](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/create-a-digital-tube-controller-IP/6.jpg)

&#160; &#160; &#160; &#160; 这样IP目录就可以自动显示自定义的IP核了。

![7](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/create-a-digital-tube-controller-IP/7.jpg)

-------

### 5.驱动文件设计

&#160; &#160; &#160; &#160; 都是仿照Altera的HAL库写的。

&#160; &#160; &#160; &#160; 首先是寄存器头文件：
```c
#ifndef __VERDVANA_AVALON_DIGITAL_TUBE_REGS_H__
#define __VERDVANA_AVALON_DIGITAL_TUBE_REGS_H__

#include <io.h>

#define IOWR_VERDVANA_AVALON_DIGITAL_TUBE_DATA(base,data)       IOWR(base,0,data)

#endif
```
&#160; &#160; &#160; &#160; 很简单，就是把写io的句子定义成写数码管的句子，参数为地址（base）和需要写入的数据（data）。

&#160; &#160; &#160; &#160; 然后是驱动函数头文件：
```c
#ifndef __DIGITAL_TUBE_CONTROLLER_H__
#define __DIGITAL_TUBE_CONTROLLER_H__

#include "system.h" 
#include "alt_types.h"
#include "verdvana_avalon_digital_tube_register.h"

#ifdef __cplusplus

extern "C"
{

#endif /* __cplusplus*/

void verdvana_digital_tube_allclose();
void verdvana_digital_tube_display(alt_u32 hex);

#define DIGITAL_TUBE_CONTROLLER_INSTANCE(name,dev) alt_u32 digital_tube_controller_addr = name##_BASE
#define DIGITAL_TUBE_CONTROLLER_INIT(name,dev) while(0)

#ifdef __cplusplus

}

#endif /*__cplusplus*/

#endif  /*__DIGITAL_TUBE_CONTROLLER_H__*/
```
&#160; &#160; &#160; &#160; 好像也很简单，定义了两个函数：数码管关闭函数和数码管显示函数。其中的参数为显示的内容。

&#160; &#160; &#160; &#160; 最后就是驱动源文件：

```c
#include "unistd.h"
#include "alt_types.h"
#include "stdlib.h"
#include "digital_tube_controller.h"

extern alt_u32 digital_tube_controller_addr;


void verdvana_digital_tube_allclose()
{
    IOWR_VERDVANA_AVALON_DIGITAL_TUBE_DATA(digital_tube_controller_addr,0xffffff);
    
}

void verdvana_digital_tube_display(alt_u32 hex)
{
    IOWR_VERDVANA_AVALON_DIGITAL_TUBE_DATA(digital_tube_controller_addr,hex);

}

```
&#160; &#160; &#160; &#160; 哎呀，更简单了，用寄存器头文件中定义的函数来填写驱动头文件中定义的函数。

&#160; &#160; &#160; &#160; 到此整个驱动文件就写完了，将他们也一并放入刚刚那个ip所在的文件夹里。

&#160; &#160; &#160; &#160; 这时NiosⅡ SBT for Eclipse并不能调用编写好的驱动文件，于是就需要编写一个*.tcl来让NiosⅡ SBT for Eclipse自动抓取驱动文件。

```tcl
#
#  digital_tube_controller.tcl
#

# Create a new driver
create_driver digital_tube_controller    

# Associate it with some hardware known as " digital_tube_controller"
set_sw_property hw_class_name digital_tube_controller

# The version of this driver
set_sw_property version 18.1

# This driver may be incompatible with versions of hardware less
# than specified below. Updates to hardware and device drivers
# rendering the driver incompatible with older versions of
# hardware are noted with this property assignment.
#
set_sw_property min_compatible_hw_version 1.0

# Initialize the driver in alt_sys_init()
set_sw_property auto_initialize true

# Interrupt properties:
# This peripheral has an IRQ output but the driver doesn't currently
# have any interrupt service routine. To ensure that the BSP tools
# do not otherwise limit the BSP functionality for users of the
# Nios II enhanced interrupt port, these settings advertise 
# compliance with both legacy and enhanced interrupt APIs, and to state
# that any driver ISR supports preemption. If an interrupt handler
# is added to this driver, these must be re-examined for validity.

#
# Source file listings...
#
add_sw_property c_source digital_tube_controller.c

# Include files
add_sw_property include_source digital_tube_controller.h
add_sw_property include_source verdvana_avalon_digital_tube_register.h

# This driver supports HAL & UCOSII BSP (OS) types
add_sw_property supported_bsp_type HAL
add_sw_property supported_bsp_type UCOSII


# End of file
```
&#160; &#160; &#160; &#160; 需要改的地方就是第6、9、36、39、40行（带文件名的几行），跟你的文件名对应上就行。编写完之后保存，这里需要注意的时候，之前的那个*.tcl文件名最后有个"hw",那么保存这个*.tcl文件的时候，文件名要写成和之前那个*.tcl一样，只不过把“hw”改成“sw”的名字。例如我的：“digital_tube_controller_sw.tcl”。保存完之后也放进那个文件夹里。最后是这个样子：

![8](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/create-a-digital-tube-controller-IP/8.jpg)

&#160; &#160; &#160; &#160; 注意文件名要保持一致，不然还是抓取不到。

-----

&#160; &#160; &#160; &#160; 一个能让NiosⅡ SBT for Eclipse自动抓取驱动文件的自定义六位七段独立数码管IP核就创建完成了。

&#160; &#160; &#160; &#160; 告辞。


<details>
  <summary>点击查看完整代码</summary>
不给看哈哈哈哈哈！！！
</details>

&nbsp;


 __参考资料：[《HELLO FPGA》- 软核演练篇 - V1.1版](http://bbs.fpga.gs/forum.php?mod=viewthread&tid=947&extra=page%3D1)__
 
 
 __感谢[skycity11](https://github.com/skycity11)对此文章质检。__
 
 
 
----------------

_源代码:_ [_https://github.com/Verdvana/IP_Digital_Tube_Controller_](https://github.com/Verdvana/IP_Digital_Tube_Controller)

