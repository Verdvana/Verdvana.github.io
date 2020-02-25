---
layout: post
title:  "Verilog HDL的一些不常见语法"
date:   2019-2-26 20:02:10 +0700
tags:
  - Verilog HDL
---

-------
### 1.前言

&#160; &#160; &#160; &#160; 记录一下看到的奇奇怪怪的写法，**我** 觉得不常见的。

-------
### 2.&

```verilog
reg [7:0] 	counter;
wire		counter_max;

assign	counter_max = &counter;
```

-----------

### 3.for

&#160; &#160; &#160; &#160; for循环语法为：
```verilog
for(循环变量赋初值;循环结束条件;循环变量增值)
    执行语句
```

&#160; &#160; &#160; &#160; 八位乘法器实现：
```verilog
parameter size = 8;
reg[size-1 : 0] opa,opb;
reg[size*2-1 : 0] result;
integer bindex;
result = 0;
for(bindex = 0;bindex <= size-1;bindex = bindex+1)
    if(opa[bindex])
        result = result + (opa<<(bindex));
end
```

&#160; &#160; &#160; &#160; **这是一个并行完全展开语句，而不是串行多周期执行。**

&#160; &#160; &#160; &#160; 该代码实践的是一个全并行的加法器。for语句等效于将以下语句完全展开：
```verilog
if(opa[bindex])
    result = result + (opa<<(bindex));
```
------------
### 4.缩减运算符
```verilog
wire    [3:0]   A;
wire            B;
assign B = &A;
```
&#160; &#160; &#160; &#160;等效于： 
```verilog
assign  B = ((A[0]&A[1])&A[2])&A[3];
```
----------
### 5. 定义存储器模型（RAM）

```verilog
(* ramstyle = "MLAB"*)reg[31:0] RegFile[15:0];
```
&#160; &#160; &#160; &#160; RegFile对象在Altera FPGA中将被识别为16个32位位宽的RAM，且指定为MLAB类型。在ASIC设计中，这种描述方式只会被识别为一系列的寄存器堆，并不会识别为RAM。在ASIC中应当利用RAM单元库（IP）梨花的方法描述RAM。

-------------
### 6.function
&#160; &#160; &#160; &#160; function语法为：
```verilog
funtion <返回值的类型或范围> (函数名)   
    <端口说明语句>              //input XXX
    <变量类型说明语句>          //reg   YYY
begin
    <语句>
    ……
    函数名 = zzz;               //函数名就相当于输出变量
end
endfuntion
```
&#160; &#160; &#160; &#160; 计算有符号数绝对值的例子：
```verilog
function [width-1:0] DWF_absval;
input [width-1:0] A;
begin
    DWF_absval = ((^(A^A)!==1'b0))?{width{1'bx}} : (A[width-1] == 1'b0) ? A : -A;
end
endfunction
```

---------------------
### 7.generate
#### 7.1 for循环
&#160; &#160; &#160; &#160; 8位加法器例化过程：
```verilog
generate
genvar i;
for(i=0;i<=7;i=i+1)
begin:for_name
    adder U_add(a[8*i+7:8*i],b[8*i+7:8*i],ci[i],sum_for[8*i+7:8*i],c0_or[i+i]);
end
endgenerate
```
&#160; &#160; &#160; &#160; 在for循环里使用always语句：
```verilog
generate
genvar i;
for(i=0;i<11;i=i+1)
begin:iq_data_gen
    always@(*)begin
        iq[i*2]=i_in[i];
        iq[i*2+1]=q_in[i];
    end
endgenerate

```
#### 7.2 if-else例化

&#160; &#160; &#160; &#160; 数据宽度不同乘法器的例化过程：
```verilog
generate
if(IF_WIDTH<10)
begin:if_name
    multiplier_imp1#(IF_WIDTH) u1 (a,b,sum_if);
end
else
begin:else_name
    multiplier_imp2#(IF_WIDTH) u2 (a,b,sum_if);
end
endgenerate
```
#### 7.3 generate-case例化
&#160; &#160; &#160; &#160; 数据宽度不同乘法器的例化过程：
```verilog
generate
case(WIDTH)
1:begin:case1_name
    adder#(WIDTH*8) x1 (a,b,ci,sum_case,c0_case);
end

2:begin:case2_name
    adder#(WIDTH*8) x2 (a,b,ci,sum_case,c0_case);
end

default:begin:d_case_name
    adder# x3 (a,b,ci,sum_case,c0_case);
end
endcase
endgenerate
```

----

### 8 宽度定义

```verilog
wire [A+:B] X ;
wire [C-:D] Y ;
```
&#160; &#160; &#160; &#160; X的宽度为B，高位为（A+B），低位为B。

&#160; &#160; &#160; &#160; Y的宽度为D，高位为C，低位为（C-D）。

--------

&#160; &#160; &#160; &#160; 告辞。

