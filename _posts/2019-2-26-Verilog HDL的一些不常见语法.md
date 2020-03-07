---
layout: post
title:  "Verilog HDL的一些不常见语法"
date:   2019-2-26 20:02:10 +0700
tags:
  - Verilog HDL
---

-------
## 1 前言

&#160; &#160; &#160; &#160; 记录一下看到的奇奇怪怪的写法，**我** 觉得不常见的。


-----------

## 2 for

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

## 3 缩减运算符
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
## 4 定义存储器模型（RAM）

```verilog
(* ramstyle = "MLAB"*)reg[31:0] RegFile[15:0];
```
&#160; &#160; &#160; &#160; RegFile对象在Altera FPGA中将被识别为16个32位位宽的RAM，且指定为MLAB类型。在ASIC设计中，这种描述方式只会被识别为一系列的寄存器堆，并不会识别为RAM。在ASIC中应当利用RAM单元库（IP）梨花的方法描述RAM。


----

## 5 task和function

### 5.1 task

&#160; &#160; &#160; &#160; task概述：
* 含有input、output、inout语句；
* 可以调用function；
* 消耗仿真时间：
    * 延迟：
        ```verilog
            #20;
        ```
    * 时钟周期：
        ```verilog
            @(posedge clock)
        ```
    * 事件：
        ```verilog
            event
        ```

&#160; &#160; &#160; &#160; 举例：

```verilog
task task_name
    parameter
    input
    output
    reg

    …text body…
endtask
```


### 5.2 function

&#160; &#160; &#160; &#160; function概述：
* 执行时不消耗仿真时间；
* 不能有控制仿真时间的语句，例如task中的延时等；
* 不能调用task；
* void function没有返回值；


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

----

## 6 并发操作

&#160; &#160; &#160; &#160; 并发性是指对于所有并发线程，在仿真工具的当前仿真时间内，安排好的时间在仿真步进到下一個仿真时间之前都会执行完成。

&#160; &#160; &#160; &#160; 当一个线程执行时，只有遇到wait语句才会停止，例如：

```verilog
wait(var_a == 1);

@(router.cb);

#1;

join_any;

join;
```

### 6.1 initial

&#160; &#160; &#160; &#160; 在整个仿真时间内只执行一次，各个initial语句并发执行。

### 6.2 always

&#160; &#160; &#160; &#160; 对组合和时序电路建模，always语句并发执行。

### 6.3 assign

&#160; &#160; &#160; &#160; 对组合电路建模，并发执行。


### 6.4 begin end

&#160; &#160; &#160; &#160; 内部语句从上往下顺序执行。

### 6.5 fork join

&#160; &#160; &#160; &#160; 内部语句并行执行，与顺序无关。例如：

```verilog
initial begin
    Statement1;             //*1
    #10 Statement2;         //*2

    fork
        Statement3;         //*3
        #50 Statement4;     //*7
        #10 Statement5;     //*4

        begin
            #20 Statement6; //*5
            #10 Statement7; //*6
        end

    join

    #30 Statement8;         //*8
    Statement9;             //*9
end
```





---------------------

## 7 generate

### 7.1 for循环

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
### 7.2 if-else例化

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
### 7.3 generate-case例化
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

## 8 宽度定义

```verilog
wire [A+:B] X ;
wire [C-:D] Y ;
```
&#160; &#160; &#160; &#160; X的宽度为B，高位为（A+B），低位为B。

&#160; &#160; &#160; &#160; Y的宽度为D，高位为C，低位为（C-D）。

----

## 9 运算符

&#160; &#160; &#160; &#160; 这个不少见，只是总结一下：



| 符号 | 含义 | 备注 |
| --- | --- | --- |
| ~ | 按位取反 | 将多位操作数按位取反：a=4'b1001，~a=4'b0110 |
| ~ | 逻辑取反 | 将操作数逻辑取反：操作数为0，取反结果为1；操作数不为0，取反结果为0 |
| & | 按位与 | 两个多位操作数按位进行与运算：a=4'b1001，b=4'b0011，a&b=4'b0001 |
| && | 逻辑与 | 对两个操作数进行逻辑与：两者相同结果为1，否则为0 |
| \| | 按位或 | 两个多位操作数按位进行或运算：a=4'b1001，b=4'b0011，a\|b=4'b1011 |  
| \|\| | 逻辑或 | 对两个操作数进行逻辑或：二者其中至少有一个不为0，则结果为1；否则为0 |
| ^ | 按位异或 | 两个多位操作数按位进行异或操作：a=4'b1001，b=4'b0011，a^b=4'b1010 |
| ^~或~^ | 按位同或 | 两个多位操作数按位进行同或操作：a=4'b1001，b=4'b0011，a^b=4'b0101 |


----

## 10 系统函数

### 10.1 随机

&#160; &#160; &#160; &#160; 返回一个32位的有符号的随机数：

```verilog
$random(seed);  //seed：传递参数
```

&#160; &#160; &#160; &#160; 返回一个32位的无符号的随机数：

```verilog
$urandom(seed);  //seed：传递参数
```

&#160; &#160; &#160; &#160; 生成有一定范围的无符号的随机数：

```verilog
$urandom_range(min,max);  
```

&#160; &#160; &#160; &#160; 随机选择有权重的可执行语句：

```verilog
randcase
    10:f10;                 //10%概率执行
    20:f20;                 //20%概率执行
    40:x=100;               //40%概率执行
    30:randcase …… endcase; //30%概率执行，嵌套
endcase
```

### 10.2 停止

&#160; &#160; &#160; &#160; 停止运行：

```verilog
$stop;  
```



--------

&#160; &#160; &#160; &#160; 告辞。



