---
layout: post
title:  "Verilog RTL代码风格介绍"
date:   2019-8-8 23:21:10 +0700
tags:
  - Verilog HDL
---

----

### 1 使用标准的DFF模块例化生成寄存器

&#160; &#160; &#160; &#160; 寄存器是数字同步电路中最基本的单元。使用Verilog进行数字电路设计时，最常见的方式是使用always块语法生成寄存器，要点如下：

* 对于寄存器避免直接使用always块编写，而是应该采用模块化的标准DFF模块进行例化。示例如下所示，一个名为flg_dfflr的寄存器，除了时钟（clk）和复位信号（rst_n）之外，还带有使能信号flg_ena和输入（flg_nxt）/输出信号（flg_r）。
	```verilog
	wire flg_r;
	wire flg_nxt = ~flg_r;
	wire flg_ena = (ptr_r == ('E203_OITF_DEPTH - 1)) & ptr_ena;
	//此处使用例化sirv_gnrl_dfflr的方式实现寄存器，而不是使用显示的always块sirv_gnrl_dfflr #(1) flg_dfflrs(flg_ena, flg_nxt, flg_r, clk, rst_n);
	```
* 使用标准的DFF模块例化的好处包括以下内容：
	* 便于全局替换寄存器类型；
	* 便于在寄存器中全局插入延迟；
	* 明确的load-enable使能信号(如下例的flg_ena)方便综合工具自动插入寄存器级别的门控时钟以降低动态功耗；
	* 便于规避Verilog语法if-else不能传播不定态的问题。

* 标准DFF模块是一系列不同的模块，结构如下：
	```t
		|----rtl							//存放RTL目录
			|----e203						//E203核和SoC的RTL目录
				|----general				//存放一些通用模块的RTL代码
					|----sirv_gnrl_dffs.v	//该文件中编写了一系列不同的DFF模块
	```
	例如：
	```verilog
	sirv_gnrl_dfflrs			//带有load-enable使能，带有异步reset，复为默认值为1的寄存器
	sirl_gnrl_dfflr				//带有load-enable使能，带有异步reset，复为默认值为0的寄存器
	sirl_gnrl_dffl				//带有load-enable使能，不带有异步reset寄存器
	sirl_gnrl_dffrs				//不带有load-enable使能，带有异步reset，复为默认值为1的寄存器
	sirl_gnrl_dffr				//不带有load-enable使能，带有异步reset，复为默认值为0的寄存器
	sirl_gnrl_ltch				//latch锁存器模块
	```

* 标准DFF模块内部则使用Verilog语法的always块进行编写，以dfflr为例，如下所示。由于Verilog if-else语法不能传播不定态，对处于if条件中的lden信号为不定态的非法情况使用断言（assertion）进行捕捉。
	```verilog
	//标准DFF模块，以sirv_gnrl_dfflr为例，代码片段如下

	module sirv_gnrl_dfflr # (parameter DE = 32)(
		input			lden,
		input  [DW-1:0]	dnxt,
		output [DW-1:0] qout,

		input			clk,
		input			rst_n
	);

	reg [DW-1:0]	qout_r;

	//使用always块编写寄存器逻辑

	always@(posedge clk or negedge rst_n)
	begin:DFFLR_PROC
		if(rst_n == 1'b0)
			qout_r <= {DW{1'b0}};
		
		else if (lden == 1'b1)
			qout_r <= dnxt;
	ens

	assign qout = qout_r;

	//使用assertion捕捉lden信号的不定态

	`ifndef FPGA_SOURCE//1{
		`ifndef SYNTHESIS//{
			sirv_gnrl_xchecker # ( //该模块内部是个SystemVerilog编写的断言
				.DW(1)
			) u_sirv_gnrl_xchecker(
				.i_dat(lden),
				.clk  (clk)
			);
		`endif//}
	`endif//}

	endmodule



	//sirv_gnrl_xchecker模块代码片段
	//此模块专门捕捉不定态，一旦输入的i_dat出现不定态，则会报错并终止仿真

	module sirv_gnrl_xchecker # (
		parameter DW = 32
	) (
		input [DW-1:0]	i_dat,
		input			clk
	);

	CHECK_THE_X_VALUE:
		assert property (@(posedge clk)
							((^(i_dat))!==1'bx)
		else $fatal ("\n Error:Oops,detected a X value! This should never happen. \n");
	
	endmodule
	```

----

### 2 推荐使用assign语法代替if-else和case语法

&#160; &#160; &#160; &#160; Verilog中的if-else和case语法存在两大缺点：
* 不能传播不定态；
* 会产生优先级的选择电路而非并行选择电路，从而不利于时序和面积。

&#160; &#160; &#160; &#160; 为了规避这两大缺点，推荐使用assign语法进行代码编写，本原则来自于严谨的工业级开发标准：

* Verilog的if-else不能传播不定态，以如下代码片段为例。**假设a的值为X不定态，按照Veriolg语法会将其等效于a==0**，从而让out输出值等于in2最终没有将X不定态传播出去。这种情况可能会在仿真阶段掩盖某些致命的bug，造成芯片功能性错误。
	```verilog
	if(a)
		out = in1;
	else
		out = in2;
	```
	而使用功能等效的assign语法如下所示，假设a的值为X不定态，按照Verilog语法，则会将X不定态传播出去，从而让out输出值也等于X。通过X不定态的传播，可以在仿真阶段将bug彻底暴露出来：
	```verilog
	assign out = a?in1:in2;
	```
	虽然现在有的EDA工具提供专有选项（例如Synopsys VCS提供xprop选项）可以使用Verilog原始语法中定义的“不传播不定态”的情形强行传播出来，但是一方面不是所有的EDA工具均支持此功能；另一方面在操作中此选项也时常被忽视，从而造成疏漏。
* Verilog的case语法也不能传播不定态，与上一部分中的if-else同理。而使用等效的assign语法即可规避此缺陷。
* Verilog的if-else语法会被综合为优先级选择的电路，面积和时序不够优化，如下所示：
	```verilog
	if(sell)
		out = in1[3:0];
	else if(sel2)
		out = in2[3:0];
	else if(sel3)
		out = in3[3:0];
	else
		out = 4'b0;
	```
	如果此处确实是希望生成一种优先级选择的逻辑，则推荐使用assign语法等效的编写成如下形式，以规避C不定态传播的问题：
	```verilog
	assign out = sel1 ? in1[3:0] :
				 sel2 ? in2[3:0] :
				 sel3 ? in3[3:0] :
				 4'b0;
	```
	而如果此处本来是希望生成一种并选择的逻辑，则推荐使用assign语法明确地使用“与”、“或”逻辑，编写如下：
	```verilog
	assign out = ({4{sel1}} & in1[3:0])
				|({4{sel2}} & in2[3:0])
				|({4{sel3}} & in3[3:0]);
	```
	使用明确的assign语法编写的“与”、“或”逻辑一定能够保证综合生成并行选择的电路。
* 与问题三同理，Verilog的case语法也会被综合成为优先级选择的电路，面积和时序均不够优化。有的EDA综合工具可以提供指引注释（例如Synopsys parallel_case和full_case）来使得综合工具能够综合处并行选择逻辑，但是这样可能会造成前后仿真不一致的严重问题，从而产生重大bug。因此，在实际的工程开发中：
	* 应该明令禁止使用EDA综合工具提供的指引注释（例如Synopsys parallel_case和full_case）
	* 应该使用等效assign语法编写电路。

----

### 3 其他

&#160; &#160; &#160; &#160; 其他编码风格中的若干要点如下：
* 由于带有reset的寄存器面积和时序会稍微差一点，因此在数据通路上可以使用不带reset的寄存器，而只在控制通路上使用呆reset的寄存器；
* 信号名定义应该避免使用拼音，注重使用英语缩写，信号名不可定义的过长，但是也不可以定义的过短。所谓代码即注释，应该尽量从信号名中能够看出此信号的功能作用；
* clock和reset信号应禁止被用于任何其他的逻辑功能，clock和reset信号只能接入DFF作为其时钟和复位信号之用。

----

### 4 小结

&#160; &#160; &#160; &#160; 上述推荐使用的asign语法和标准DFF例化方法能够使得任何不定态在前仿真阶段无处遁形，综合工具能够综合出很高质量的电路，综合出的电路门控时钟率也很高。

----
&#160; &#160; &#160; &#160; 告辞。

