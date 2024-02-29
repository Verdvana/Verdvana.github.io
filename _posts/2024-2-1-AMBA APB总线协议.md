---
layout: post
title:  "AMBA APB总线协议"
date:   2024-2-1 10:10:10 +0700
tags: 
  - Digital IC Design
---

-------

## 1 前言

&#160; &#160; &#160; &#160; APB(Advanced Peripheral Bus)，高级外设总线，主要用于低带宽的周边外设之间的连接，例如UART、IIC等。它的总线架构如下图所示：

![img1][img1]

&#160; &#160; &#160; &#160; 可以看出APB Bridge是AMBA APB中的唯一总线主机，APB Bridge也是AMBA中的一个从机。

&#160; &#160; &#160; &#160; 特点：
* 低带宽；高性能；
* 不支持pipeline、Busrst、Outstanding传输，最快只能Back to back，至少需要两个时钟周期传输；
* 无需等待周期和回应信号；
* 不能读写同时传输，AHB也不行，AXI可以；
* 不支持仲裁，因为是单主多从。

&#160; &#160; &#160; &#160; 版本：
* [AMBA2 APB Specification](https://developer.arm.com/documentation/ihi0011/a/)（APB2）
* [AMBA3 APB Protocol Specification v1.0](https://developer.arm.com/documentation/ihi0024/b)（APB3）
* [AMBA APB Protocol Specification v2.0/Issue C](https://developer.arm.com/documentation/ihi0024/c)（APB4）
* [AMBA APB Protocol Specification Issue D/E](https://developer.arm.com/documentation/ihi0024/latest/)（APB5）

----

## 2 APB interface

<table>
  <tr>
    <th>Source</th>
    <th>Version</th>
    <th>Signal</th>
    <th>Width</th>
    <th>Attribute</th>
    <th>Description</th>
  </tr>
  <tr>
    <td rowspan=2>Global</td>
    <td rowspan=2>APB2</td>
    <td>PCLK</td>
    <td>1</td>
    <td>Clock</td>
    <td>APB的所有传输在PCLK的上升沿有效</td>
  </tr>
  <tr>
    <td>PRESETn</td>
    <td>1</td>
    <td>Reset</td>
    <td>低电平有效，通常直接连接到系统总线的复位信号</td>
  </tr>
  <tr>
    <td rowspan=7>APB bridge</td>
    <td rowspan=5>APB2</td>
    <td>PADDR</td>
    <td>8/16/32</td>
    <td>Address</td>
    <td>最多32bit</td>
  </tr>
  <tr>
    <td>PSELx</td>
    <td>1</td>
    <td>Select</td>
    <td>每个APB Slave都有一个PSELx信号，由ABP Bridge产生</td>
  </tr>
  <tr>
    <td>PENABLE</td>
    <td>1</td>
    <td>Enable</td>
    <td>指示APB传输的第二及后续周期</td>
  </tr>
  <tr>
    <td>PWRITE</td>
    <td>1</td>
    <td>Direction</td>
    <td>1'b1: 写<br>1'b0: 读</td>
  </tr>
  <tr>
    <td>PWDATA</td>
    <td>8/16/32</td>
    <td>Write data</td>
    <td>最多32bit，PWRITE为1时由Master产生</td>
  </tr>
  <tr>
    <td rowspan=2>APB4</td>
    <td>PPROT</td>
    <td>3</td>
    <td>Protection type</td>
    <td>PPROT[2]: 1=Instruction; 0=Data<br>PPROT[1]: 1=Nonsecure; 0=Secure<br>PPROT[0]: 1=Privileged; 0=Normal<b</td>
  </tr>
  <tr>
    <td>PSTRB</td>
    <td>1/2/4</td>
    <td>Write strobes</td>
    <td>指示在写传输期间，要更新哪个字节通道<br>写数据总线的每8bit对应1bitPSTRB<br>在读传输期间，PSTRB不能跳变</td>
  </tr>
  <tr>
    <td rowspan=3>Slave interface</td>
    <td>APB2</td>
    <td>PRDATA</td>
    <td>8/16/32</td>
    <td>Read data</td>
    <td>最多32bit，PWRITE为0时由Slave产生</td>
  </tr>
  <tr>
    <td rowspan=2>APB3</td>
    <td>PREADY</td>
    <td>1</td>
    <td>Ready</td>
    <td>表示APB传输完成</td>
  </tr>
  <tr>
    <td>PSLVERR</td>
    <td>1</td>
    <td>Transfer error</td>
    <td>传输失败的错误信号</td>
  </tr>
</table>

----

## 3 状态转换

&#160; &#160; &#160; &#160; APB协议总共只有三种状态，分别是IDLE，SETUP和ACCESS。

* IDLE：默认空闲状态；
* SETUP：当主机需要传输数据的时候，会把从机对应的PSEL拉高，PENABLE拉低，此时进入SETUP，且只持续一拍，下一拍必进入ACCESS；
* ACCESS：驱动PENBALE拉高，之后会采样从机的PREADY信号，如果为低则持续状态，如果为高则回到IDLE或回到SETUP，这取决于是否还有数据传输。SETUP进入ACCESS时需要以下信号保持不变：
  * PADDR；
  * PPROT；
  * PWRITE；
  * PWDATA；
  * PSTRB；
  * PAUSER；
  * PWUSER；

&#160; &#160; &#160; &#160; 从APB从机角度，状态转换如下图所示：

```mermaid
graph LR
    IDLE -->|PSEL = 1; PENABLE = 0| SETUP;
    SETUP --> ACCESS;
    ACCESS -->|PSEL = 1; PENABLE = 0| SETUP;
    ACCESS -->|PREADY = 0| ACCESS;
    ACCESS -->|PREADY = 1| IDLE;
```

----

## 4 APB Timing

### 4.1 写传输

&#160; &#160; &#160; &#160; 没有等待状态：

```wavedrom
{ signal: [
  { name: "PCLK",  wave: "p....." },
  { name: "PADDR", wave: "x.6...", data:"Addr1"},
  { name: "PWRITE", wave: "x.1..." },
  { name: "PSEL", wave: "0.1.0." },
  { name: "PENABLE", wave: "0..10." },
  { name: "PWDATA", wave: "x.6.x.", data:"Data1"},
  { name: "PREADY", wave: "x..1xx" },
  { name: "STATUS", wave: "3.453.", data:"IDLE S A IDLE" },
]}
```

&#160; &#160; &#160; &#160; 第一阶段为IDLE状态。


&#160; &#160; &#160; &#160; 第二阶段为SETUP，此时主机把PSEL和PWRITE拉高；PADDR和PWDATA准备好地址和数据；把PENABLE拉低表示下一拍实施写入。


&#160; &#160; &#160; &#160; 第三阶段为ACCESS，主机把PENABLE拉高，表示该数据有效；从机采样到PSEL拉高，会把PREADY拉高表示接收数据；

&#160; &#160; &#160; &#160; 第四阶段退出ACCESS，如果PREADY为高，代表从机接收到信号，主机则拉低PSEL和PENABLE信号，进入IDLE状态。

&#160; &#160; &#160; &#160; 没有等待状态的连续写时序：

```wavedrom
{ signal: [
  { name: "PCLK",  wave: "p..........." },
  { name: "PADDR", wave: "x.3.4.5.6.x.", data:"Addr1 Addr2 Addr3 Addr4"},
  { name: "PWRITE", wave: "x.1.1.1.1.1." },
  { name: "PSEL", wave: "0.1.1.1.1.0." },
  { name: "PENABLE", wave: "0..10101010." },
  { name: "PWDATA", wave: "x.3.4.5.6.x.", data:"Data1 Data2 Data3 Data4"},
  { name: "PREADY", wave: "x..1010101xx" },
  { name: "STATUS", wave: "3.454545453.", data:"IDLE S A S A S A S A IDLE" },
]}
```



&#160; &#160; &#160; &#160; 具有等待状态：

```wavedrom
{ signal: [
  { name: "PCLK",  wave: "p........" },
  { name: "PADDR", wave: "x.6......", data:"Addr1"},
  { name: "PWRITE", wave: "x.1......" },
  { name: "PSEL", wave: "0.1....0." },
  { name: "PENABLE", wave: "0..1...0." },
  { name: "PWDATA", wave: "x.6....x.", data:"Data1"},
  { name: "PREADY", wave: "x..0..1x." },
  { name: "STATUS", wave: "3..4..53.", data:"IDLE S A IDLE" },
]}
```

&#160; &#160; &#160; &#160; ACCESS可能不止一个周期，取决于从机什么时候回复PREADY信号，因此数据写入完成要大于两个时钟周期。

### 4.2 读传输
 

&#160; &#160; &#160; &#160; 没有等待状态，类似写传输：

```wavedrom
{ signal: [
  { name: "PCLK",  wave: "p....." },
  { name: "PADDR", wave: "x.6...", data:"Addr1"},
  { name: "PWRITE", wave: "x.0..." },
  { name: "PSEL", wave: "0.1.0." },
  { name: "PENABLE", wave: "0..10." },
  { name: "PRDATA", wave: "x..6x.", data:"Data1"},
  { name: "PREADY", wave: "x..1xx" },
  { name: "STATUS", wave: "3..453", data:"IDLE S A IDLE" },
]}
```

&#160; &#160; &#160; &#160; 具有等待状态，类似写传输：

```wavedrom
{ signal: [
  { name: "PCLK",  wave: "p........" },
  { name: "PADDR", wave: "x.6......", data:"Addr1"},
  { name: "PWRITE", wave: "x.1......" },
  { name: "PSEL", wave: "0.1....0." },
  { name: "PENABLE", wave: "0..1...0." },
  { name: "PRDATA", wave: "x.6....x.", data:"Data1"},
  { name: "PREADY", wave: "x..0..1x." },
  { name: "STATUS", wave: "3..4..53.", data:"IDLE S A IDLE" },
]}
```

----

## 5 其他信号

### 5.1 PSTRB


&#160; &#160; &#160; &#160; PSTRB可以理解为写入选通，1bit控制PWDATA的8bit是否能写入：

| PSTRB | 3 | 2 | 1 | 0 |
| --- | --- | --- | --- | --- |
| PWDATA | 31:24 | 23:16 | 15:8 | 7:0 |

&#160; &#160; &#160; &#160; **读传输时，PSTRB必须全位拉低。**

### 5.2 PSLVERR


&#160; &#160; &#160; &#160; PSLVERR表示从机认为写传输有错误。时序图如下：

```wavedrom
{ signal: [
  { name: "PCLK",  wave: "p........" },
  { name: "PADDR", wave: "x.6......", data:"Addr1"},
  { name: "PWRITE", wave: "x.1......" },
  { name: "PSEL", wave: "0.1....0." },
  { name: "PENABLE", wave: "0..1...0." },
  { name: "PWDATA", wave: "x.6....x.", data:"Data1"},
  { name: "PREADY", wave: "x..0..1x." },
  { name: "PSLVERR", wave: "x.....1x." },
  { name: "STATUS", wave: "3..4..53.", data:"IDLE S A IDLE" },
]}
```

&#160; &#160; &#160; &#160; 写传输时，当从机任务可以接受数据时，把PREADY拉高。同时如果之前采集PADDR、PWDATA等信号有问题，则认为写传输有误，所以在此时把PSLVERR也拉高。主机会在下一个上升沿采集到此错误信号，得知写入错误。

&#160; &#160; &#160; &#160; 读传输也可能出现错误，表示无可读数据。

----

## 6 APB SRAM RTL设计

&#160; &#160; &#160; &#160; 设计一个16bit数据位宽、512字节（9bit地址位宽）的APB协议的SRAM。

### 6.1 Interface & Architecture

&#160; &#160; &#160; &#160; 接口符合APB4协议。

| Signal | Width | Direction |
| --- | --- | --- |
| pclk | 1 | I |
| preset_n | 1 | I |
| paddr | ADDR_WIDTH | I |
| psel | 1 | I |
| penable | 1 | I |
| pwrite | 1 | I |
| pwdata | DATA_WIDTH | I |
| pprot | 3 | I |
| pstrb | DATA_WIDTH/8 | I |
| prdata | DATA_WIDTH | O |
| pready | 1 | O |
| pslverr | 1 | O |


&#160; &#160; &#160; &#160; 文件结构：
* APB_SRAM
  * SRAM
    * SRAM_IP

### 6.2 SRAM

&#160; &#160; &#160; &#160; 采用ARM Artisan Physical IP来生成一个8*512的单口SRAM，然后例化：

```verilog
module SPRAM #(
	parameter  DATA_WIDTH = 8,
                   ADDR_WIDTH = 9
)(
	// Clock
        input	wire						clk,			// Clock
        input	wire						cs_n,			// Chip select
        input   wire                                            we_n,
        input   wire    [ADDR_WIDTH-1:0]                        addr,
        input   wire    [DATA_WIDTH-1:0]                        din,
        output  logic   [DATA_WIDTH-1:0]                        dout
);


    SRAM_SP_512_8 u_SRAM_SP_512_8(
        .CLK(clk),
        .CEN(cs_n),
        .WEN(we_n),
        .A(addr),
        .D(din),
        .Q(dout),
        .EMA(3'b000)
    );

endmodule
```


### 6.3 APB_SRAM

&#160; &#160; &#160; &#160; 根据APB协议，把APB读写操作转化为SRAM的读写操作。

```verilog
module APB_SPRAM#(
	parameter		DATA_WIDTH	= 8,
					ADDR_WIDTH  = 9

)(
	// Clock and reset
	input	wire											pclk,			// Clock
	input	wire											preset_n,		// Async reset
	// APB bus signal
	input	wire	[ADDR_WIDTH-1:0]						paddr,			// Address
	input	wire											psel,			// Select
	input	wire											penable,		// Enable
	input	wire											pwrite,			// Write/Read
	input	wire	[DATA_WIDTH-1:0]						pwdata,			// Write data
	input	wire	[2:0]									pprot,			// Protection type
	input	wire	[(DATA_WIDTH/8)-1:0]					pstrb,			// Write storbes

	output	logic	[DATA_WIDTH-1:0]						prdata,			// Read data
	output	logic											pready,			// Read ready
	output	logic											pslverr			// Transfer error
);

	//=========================================================================
	// The time unit and precision of the internal declaration
	timeunit		1ns;
	timeprecision	1ps;


	//=========================================================================
	// Parameter
	localparam		TCO			= 1.6;										// Simulate the delay of the register

	//=========================================================================
	// Signal
	logic	[(DATA_WIDTH/8)-1:0] [7:0]	wr_mask;
	logic	[DATA_WIDTH-1:0]	wr_data;
	logic						sram_clk;
	logic						sram_cs_n;
	logic						sram_we_n;
	logic	[ADDR_WIDTH-1:0]	sram_addr;
	logic	[DATA_WIDTH-1:0]	sram_din;
	logic	[DATA_WIDTH-1:0]	sram_dout;

	//=========================================================================
	// 
	enum {
		IDLE,
		SETUP,
		ACCESS
	} curr_state,next_state;

	always_ff@(posedge pclk, negedge preset_n)begin
		if(!preset_n)
			curr_state	<= #TCO IDLE;
		else
			curr_state	<= #TCO next_state;
	end

	always_comb begin
		case(curr_state)
			IDLE:	begin
				if(psel && !penable)
					next_state	= SETUP;
				else
					next_state	= IDLE;
			end
			SETUP:	begin
				next_state	= ACCESS;
			end
			ACCESS: begin
				if(!psel && !penable)
					next_state	= IDLE;
				else if(psel && !penable)
					next_state	= SETUP;
				else
					next_state	= ACCESS;
			end
			default:next_state	= IDLE;
		endcase
	end

	assign	sram_clk	= pclk;
	assign	sram_cs_n	= !psel || penable;
	assign	sram_we_n	= psel?~pwrite:sram_we_n;
	assign	sram_addr	= (next_state == SETUP) ? paddr:sram_addr;
	assign	wr_data	= (next_state == SETUP) ? pwdata:wr_data;
	assign	prdata		= sram_dout;
	assign	pready		= penable;

	always_comb begin
		for(int i=0;i<(DATA_WIDTH/8);i++)begin
			if(pstrb[i])
				wr_mask[i]	= wr_data[8*i+:8];
			else
				wr_mask[i]	= '0;
		end
	end

	assign	sram_din	= wr_mask;

	genvar k;
	generate for(k=0;k<(DATA_WIDTH/8);k++)begin:inst
		SPRAM #(
			.DATA_WIDTH(8),
			.ADDR_WIDTH(9)
		) u_SPRAM_0(
			.clk(sram_clk),		//input,	Clock
			.cs_n(sram_cs_n),	//input,	Chip select
			.we_n(sram_we_n),	//input,	1:read;0:write
			.addr(sram_addr),	//input,	Address
			.din(sram_din[k*8+:8]),		//input,	Write data
			.dout(sram_dout[k*8+:8])	//output,	Read data
		);
	end
	endgenerate

endmodule
```



----

[img1]:data:image/png;base64,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

