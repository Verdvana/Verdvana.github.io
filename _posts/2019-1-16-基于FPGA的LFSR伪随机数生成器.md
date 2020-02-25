---
layout: post
title:  "基于FPGA的LFSR伪随机数生成器"
date:   2019-1-16 15:58:10 +0700
tags:
  - FPGA
---

-------
### 1.前言

&#160; &#160; &#160; &#160; 有些场景下需要用到随机数。Verilog HDL有随机数函数$random，但并不能被综合，所以就要用LFSR产生伪随机数。

* 开发环境：
	* Quartus Prime Standard 18.1
* 操作系统：
	* Windows 10 Pro 1903

-------
### 2.LFSR

&#160; &#160; &#160; &#160; 线性反馈移位寄存器（LFSR）是由n个**D触发器**和若干个**异或门**组成。结构如图：

![2](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9F%BA%E4%BA%8EFPGA%E7%9A%84LFSR%E4%BC%AA%E9%9A%8F%E6%9C%BA%E6%95%B0%E7%94%9F%E6%88%90%E5%99%A8/2.jpg)

&#160; &#160; &#160; &#160; 设定一个随机种子，就是一串二进制数，每个时钟沿都会往右移一位，其中有几位还需要跟最高位异或一下再移位。哪些位需要异或可以自己设定，这样就完成了伪随机数的生成。

-----
### 3.代码

```verilog
module random(
		input             clk_50m,  	//50MHz时钟
		input             rst_n,    	//复位，低电平有效
		input             load,  		//seed加载信号，高电平有效
		input      [15:0]	seed,     	//随机种子
		output reg [15:0]	rand_num  	//16位随机数
);


//反馈系数为g0g1g2g3g4g5g6g7g8g9g10g11g12g13g14g15g16=101110000_001110001

always@(posedge clk_50m or negedge rst_n)
begin
    if(!rst_n)
        rand_num    <=16'b0;
		  
    else if(load)
        rand_num <=seed;   
    else
        begin
            rand_num[0] <= rand_num[15];
            rand_num[1] <= rand_num[0];
            rand_num[2] <= rand_num[1];
            rand_num[3] <= rand_num[2];
            rand_num[4] <= rand_num[3] ^~rand_num[15];
            rand_num[5] <= rand_num[4] ^~rand_num[15];
            rand_num[6] <= rand_num[5] ^~rand_num[15];
            rand_num[7] <= rand_num[6];
			rand_num[8] <= rand_num[7];
			rand_num[9] <= rand_num[8];
			rand_num[10]<= rand_num[9];
			rand_num[11]<= rand_num[10];
			rand_num[12]<= rand_num[11]^~rand_num[15];
			rand_num[13]<= rand_num[12]^~rand_num[15];
			rand_num[14]<= rand_num[13]^~rand_num[15];
			rand_num[15]<= rand_num[14];
        end
            
end
endmodule
```
------

### 4.仿真

&#160; &#160; &#160; &#160; 用Modelsim仿真一下。

![1](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E5%9F%BA%E4%BA%8EFPGA%E7%9A%84LFSR%E4%BC%AA%E9%9A%8F%E6%9C%BA%E6%95%B0%E7%94%9F%E6%88%90%E5%99%A8/1.jpg)

&#160; &#160; &#160; &#160; emmmmmm，凑合能看。

--------

&#160; &#160; &#160; &#160; 告辞。