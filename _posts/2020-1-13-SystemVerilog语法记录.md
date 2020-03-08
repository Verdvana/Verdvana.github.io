---
layout: post
title:  "SystemVerilog语法总结"
date:   2020-1-13 22:19:10 +0700
tags:
  - SystemVerilog
---

-------

## 1 前言

&#160; &#160; &#160; &#160; SystemVerilog完全兼容Verilog HDL，还加入了类似C++的语法用于验证。总之一句话，用TMD！


----

## 2 特定逻辑过程

### 2.1 always_ff

&#160; &#160; &#160; &#160; 描述时序逻辑电路模块，如果过程内部写成组合逻辑，则会报错。

### 2.2 always_comb

&#160; &#160; &#160; &#160; 描述组合逻辑电路模块，如果过程内部写成锁存器，则会报错。

### 2.3 always_latch

&#160; &#160; &#160; &#160; 描述锁存器电路模块，如果写成其他电路，则会报错。

----

## 3 新添加的数据类型

&#160; &#160; &#160; &#160; 有四态，两态和实型三种数据类型，其中两态和实型不适合RTL设计。

### 3.1 Logic

&#160; &#160; &#160; &#160; 4态，0、1、X、Z，位宽可变，**可以代替所有其他类型，包括reg**。

&#160; &#160; &#160; &#160; Logic类型类似于VHDL的std_ulogic类型：

* 对应的具体元件待定；
* 只允许使用一个驱动源，或者来自于一个或者多个过程块的过程赋值（对同一变量既进行连续赋值（assign）又进行过程赋值是非法的）；
* 在SV中，logic和reg是一致的（类似于Verilog中wire和reg类型是一致的）。

&#160; &#160; &#160; &#160; wire数据类型仍旧有用，因为：

* 用于多驱动源总线：如多路总线交换器；
* 用于双向总线（两个驱动源）。

### 3.2 bit

&#160; &#160; &#160; &#160; 2态，1位0或1，位宽可变。

&#160; &#160; &#160; &#160; 相当于2态数据类型的变量或线网。

### 3.3 byte

&#160; &#160; &#160; &#160; 2态，8位有符号整型数。

### 3.4 shortint

&#160; &#160; &#160; &#160; 2态，16位有符号整型数。

### 3.5 int

&#160; &#160; &#160; &#160; 2态，32位有符号整型数。

### 3.6 longint

&#160; &#160; &#160; &#160; 2态，64位有符号整型数。

### 3.7 real

&#160; &#160; &#160; &#160; 64位有符号数，等价于C中的double。

### 3.8 shortreal

&#160; &#160; &#160; &#160; 32位有符号数，等价于C中的float。

### 3.9 用户定义的类型——typedef

&#160; &#160; &#160; &#160; 允许生成用户定义的或者容易改变的类型定义，通常命名用“_t”做后缀：

```verilog
`ifdef STATE2
    typedef bit bit_t;  //2态
`else
    typedef logic bit_t;//4态
endif
```

&#160; &#160; &#160; &#160; 只要用typedef就能很容易的在4态和2态逻辑仿真之间切换以加快仿真速度。

### 3.10 枚举——enum

&#160; &#160; &#160; &#160; 缺省状态下为2态整型（int）变量：

```verilog
enum {red,yellow,green} lignt1,lignt2;  //red = 0, yellow = 1, green = 2
enum {bronze=3,silver,gold} medal;      //silver = 4, gold = 5 
enum {bronze=4'h3,silver,gold} medal;   //silver = 4'h4, gold = 4'h5 
```

&#160; &#160; &#160; &#160; 常用于状态机设计中状态的声明。

&#160; &#160; &#160; &#160; 整型：

```verilog
module fsm_1;
......  
    enum {              //类型缺省，为整型
        IDLE = 3'b000,  //对枚举名赋值
        READ,           //3'b001
        DLY,            //3'b010
        DONE,           //3'b011
        XX = 3'b111
    } state,next;

....

endmodule
```

&#160; &#160; &#160; &#160; 四状态：

```verilog
module fsm_2;
......  
    enum reg [1:0]{     //指定四状态数据类型
        IDLE = 2'b00,   //对枚举名赋值
        READ,           //2'b01
        DLY,            //2'b10
        DONE,           //2'b11
        XX = 'x         //x赋值在仿真无关项优化综合和调试时非常有用
    } state,next;

....
endmodule
```

&#160; &#160; &#160; &#160; 另外，枚举类型变量可以使用“.name”显示字符。

----

## 4 数组与队列

### 4.1 固定数组

&#160; &#160; &#160; &#160; 固定数组的定义举例：

```verilog
integer numbers [5];                        //二维数组（5×32），未赋初值
int     b[2]        = '{ 3,7 };               //一维数组，赋初值3，7
int     c[2][3]     = '{ { 3,7,1 },{ 5,1,9 } };   //二维数组赋初值
byte    d[7][2]     = '{default:-1};        //所有数据赋值为“-1”
bit [31:0] a[2][3]  = c;                    //把矩阵c复制给a
```

&#160; &#160; &#160; &#160; 超过边界值的写操作将被忽略，超过边界值的读操作：两值逻辑返回“0”，四值逻辑返回“x”。


### 4.2 动态数组

&#160; &#160; &#160; &#160; 动态数组的定义举例：

```verilog
reg [7:0] ID[],array1[] = new[16];      //使用new函数分配数组ID和array1，其中array1的大小为16
reg [7:0] data_array[];                 //分配动态数组data_array
ID = new[100];                          //ID的大小为100
ID.delete();                            //释放ID大小
```

&#160; &#160; &#160; &#160; 动态数组只有一维，在仿真运行时，使用构造函数分配数组大小，如果越界对动态数组进行读写操作，仿真出错。

### 4.3 队列

&#160; &#160; &#160; &#160; 队列的定义：

```verilog
int     array1[$] = {0,1,3,6};
int     array2[$] = {4,5};
int     j = 2;
array1.insert[2,j];             //{0,1,2,3,6}
array1.insert[4,array2];        //{0,1,2,3,4,5,6}
array1.delete[1];               //{0,2,3,4,5,6}
array1.push_front[7];           //{7,0,2,3,4,5,6}
j = array1.pop_back[];          //{7,0,2,3,4,5} j=6
```


&#160; &#160; &#160; &#160; 其中：
* 在仿真运行时，分配或者释放数组的内存空间：
    * 分配：push_back()、push_front()、insert();
    * 释放：pop_back()、pop_front()、delete(); 
* 不能使用“new[]”函数创建内存空间;
* 索引0指向队列最低的索引；
* 索引$指向队列最高的索引；
* 越界对队列进行读写操作会导致仿真错误；
* 队列操作的效果类似与FIFO或堆栈；
* 单一维度。

### 4.4 联合数组

&#160; &#160; &#160; &#160; 联合数组的定义：

```verilog
byte array[string],t[*],a[*];   //byte类型的数组，索引类型为string
int index;

array["byte0"] = -8;            //创建“byte0”索引，索引的数组值为-8

for(int i=0;i<10;i++)
    t[1<<i] = i;                //生成十个t数组元素

a = t;                          //数组复制
```

&#160; &#160; &#160; &#160; 其中：
* 索引的类型可以是数字、字符串或者类；
* 动态分配和动态释放内存空间：
    * 分配

* 数组的移动搜索：
    * first()、next()、prev()、last()；
* num()函数决定了数组元素的个数；
* exists()函数可以判断有效索引是否存在；
* 越界读操作时，两值逻辑返回“0”，四值逻辑返回“x”；
* 只支持一维。



### 4.5 未打包的数组

&#160; &#160; &#160; &#160; 未打包的四维数组：

```verilog
logic xdata [3:0][2:0][1:0][7:0];   //对于这个语句最大的可访问单元为1位
```

### 4.6 打包的数组

&#160; &#160; &#160; &#160; 打包的一维数组和未打包的三维数组：

```verilog
logic [7:0] xdata [3:0][2:0][1:0];  //对于这个语句最大的可访问单元为8位
```

&#160; &#160; &#160; &#160; 打包的二维数组和未打包的二维数组：

```verilog
logic [1:0][7:0] xdata [3:0][2:0];  //对于这个语句最大的可访问单元为16位
```

&#160; &#160; &#160; &#160; 打包的四维数组：

```verilog
logic [3:0][2:0][1:0][7:0] xdata;  //对于这个语句最大的可访问单元为192位
```

### 4.7 数组总结

| 数组类型 | 物理内存 | 索引 |
| --- | --- | --- |
| 固定数组 | 编译时创建，之后不能修改 | 数字 |
| 动态数组 | 创建时仿真，仿真期间可以改变 | 数字 |
| 队列 | 仿真时可以改变队列大小 | 数字 |
| 联合数组 | 仿真时分配内存 | 数字、字符串、类 |
----

## 5 接口

### 5.1 隐含的端口连接

&#160; &#160; &#160; &#160; Verilog和VHDL都能用按端口名连接或按顺序连接的方式引用实例模块。SystemVerilog用了两个新的隐含端口连接解决了顶层代码编写时表示端口连接代码的冗长：

* .name：端口连接；
* .*：隐含的端口连接。

&#160; &#160; &#160; &#160; 隐含.name和.*端口连接的规则：    

* 在同一个实例引用中禁止混用.*和.name端口；
* 允许在同一个实例引用中使用.name和.name(signal)连接；
* 允许在同一个实例中引用中使用.*和.name(signal)连接；
* 必须用.name(signal)连接的情况：
    * 位宽不匹配；
    * 名称不匹配；
    * 没有连接的端口。


### 5.2 SystemVerilog中的接口


&#160; &#160; &#160; &#160; 隐藏的端口连接的缺点之一是不容易发现错误，所以出现了接口。

&#160; &#160; &#160; &#160; 接口提供了新的层次结构，把内部连接和通信封装起来，把模块的通信功能从其他功能中分离出来，并且消除了接线引起的错误，让RTL级别的抽象成为可能。

&#160; &#160; &#160; &#160; 有关接口的说明：

* 接口能传递穿越端口的记录数据类型；
* 有两种类型的接口元素：
    * 声明的；
    * 作为参数可以直接传递进入模块。
* 接口可以是：
    * 参数，常数和变量；
    * 函数和任务；
    * 断言。

&#160; &#160; &#160; &#160; 接口的引用：

* 接口变量可以用接口实例名加“.”变量名引用；
* 接口函数可以用接口实例名加“.”变量名引用；
* 通过接口的模块连接：
    * 能调用接口任务和函数的成员来驱动通信；
    * 抽象级和通信协议能容易地加以修改，用一个包含相同成员的新接口来替换原来的接口。

&#160; &#160; &#160; &#160; 接口的使用：

```verilog
interface intf;         //接口类型声明
    logic a,b;
    logic c,d;
    logic e,f;
endinterface

module top;
    intf w();           //接口实例引用
    mod_a m1(.i1(w));   //具体化的接口实例w在mod_a中被称为i1
    mod_b m2(.i2(w));   //具体化的接口实例w在mod_b中被称为i2
endmodule

module mod_a(intf i1);  //括号内：引用定义的接口类型 / 被引用接口的本地访问名
endmodule

module mod_b(intf i2);  //括号内：引用定义的接口类型 / 被引用接口的本地访问名
endmodule
```

&#160; &#160; &#160; &#160; 如图：

![1](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/SystemVerilog%E8%AF%AD%E6%B3%95%E4%BB%8B%E7%BB%8D/1.jpg)

&#160; &#160; &#160; &#160; **接口不要都用线网类型**。一般情况下，接口将把模块的输出连接到另一模块的输入，输出可能是过程性的或者连续性驱动的，输入是连续性驱动的。既然接口是把输出与输入连接起来，而输出常由过程性语句赋值，即使输出是由连续赋值语句指定的，当它们被连接到不同模块时，它也往往被转变成过程性赋值。**而双向和多驱动线网在接口定义中必须声明为线网类型**。

----

## 6 task和function

### 6.1 task

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


### 6.2 function

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

### 6.3 return语句

&#160; &#160; &#160; &#160; SystemVerilog中增加了return语句。return用于退出task和function，执行时返回表达式的值，否则最后的返回数值赋值给函数名。

```verilog
function int divide (input int numerator,denominator);
    if(denominator==0)
        return 0;
    else
        return numerator/denominator;
endfunction

always_ff@(posedge clock)
    result <= divide(b,a);
//or
always_ff@(posedge clock)
    result <= divide(   .denominator(b),
                        .numerator(a) );

```

### 6.4 传递参数

&#160; &#160; &#160; &#160; SystemVerilog增强了函数形式参数：
* 增加了input、output传输参数
* 每一个形式参数都有一个默认的类型，调用task和function时，不必给就具有默认参数值的参数传递数值，如果不传递参数值，就会使用默认值。如上一节的例子。 

&#160; &#160; &#160; &#160; 使用引用（reference）代替复制的方式传递参数：
* 常见的向task和function传递参数值的方式是复制；
* 使用reference的方式显式地向task和function传递参数：
    * 关键字ref取代了input、output、inout；
    * 只有automatic任务和函数才可以使用ref参数。

```verilog
function automatic void fill_packet (   ref logic [7:0] data_in [7:0],
                                        ref pack_t      data_out);
    for(int i=0;i<=7;i++) begin
        data_out.data[(8*i)+:8]=data_in[i];
    end
endfunction

always_ff@(posedge clock) begin
    if(data_ready)
        fill_packet(.data_in(raw_data),.data_out(data_packet));
end
```

----

## 8 并发线程

&#160; &#160; &#160; &#160; SystemVerilog中除了fork join之外还增加了fork join_any和fork join_none。

### 8.1 fork join

&#160; &#160; &#160; &#160; 当fork join中的子线程都执行完之后才会跳出fork继续执行父线程语句，例如：


```verilog
initial begin
    Statement1;             //父线程，第1个执行
    #10 Statement2;         //父线程，第2个执行

    fork
        Statement3;         //子线程，第3个执行
        #50 Statement4;     //子线程，第7个执行
        #10 Statement5;     //子线程，第4个执行

        begin
            #20 Statement6; //子线程，第5个执行
            #10 Statement7; //子线程，第6个执行
        end

    join

    #30 Statement8;         //父线程，第8个执行
    Statement9;             //父线程，第9个执行
end
```

### 8.2 fork join_any

&#160; &#160; &#160; &#160; 当fork join_any中的子线程有一条执行完，则会跳出fork继续执行父线程的语句，在父线程中遇到延时等语句后又会继续执行fork，此时变为fork join，但执行的时长为父线程中遇到的延时语句的时长，如果父线程中没有延时语句，则不会再进入fork，例如：


```verilog
initial begin
    Statement1;             //父线程，第1个执行
    #10 Statement2;         //父线程，第2个执行

    fork
        Statement3;         //子线程，第3个执行
        #50 Statement4;     //子线程，第8个执行
        #10 Statement5;     //子线程，第5个执行

        begin
            #20 Statement6; //子线程，第6个执行
            #10 Statement7; //子线程，第7个执行
        end

    join_any

    Statement8;             //父线程，第4个执行
    #80 Statement9;         //父线程，第9个执行
end
```

&#160; &#160; &#160; &#160; 而如果Statement9的延时小于子线程内部的50个时间单位的延时，则子程序不会都执行完：

```verilog
initial begin
    Statement1;             //父线程，第1个执行
    #10 Statement2;         //父线程，第2个执行

    fork
        Statement3;         //子线程，第3个执行
        #50 Statement4;     //子线程，不执行
        #10 Statement5;     //子线程，第5个执行

        begin
            #20 Statement6; //子线程，第6个执行
            #10 Statement7; //子线程，不执行
        end

    join_any

    Statement8;             //父线程，第4个执行
    #30 Statement9;         //父线程，第7个执行；此时遇到延时，该线程挂起30个时间单位，回fork执行语句，30个时间单位后执行该线程
end
```

### 8.3 fork join_none

&#160; &#160; &#160; &#160; 先执行父线程的语句，如果父线程中有延时语句，才会进入fork执行子线程：

```verilog
initial begin
    Statement1;             //父线程，第1个执行
    #10 Statement2;         //父线程，第2个执行

    fork
        Statement3;         //子线程，第4个执行
        #50 Statement4;     //子线程，第8个执行
        #10 Statement5;     //子线程，第5个执行

        begin
            #20 Statement6; //子线程，第6个执行
            #10 Statement7; //子线程，第7个执行
        end

    join

    Statement8;             //父线程，第3个执行
    #80 Statement9;         //父线程，第9个执行
end
```

&#160; &#160; &#160; &#160; 如果Statement9的延时小于子线程内部的50个时间单位的延时：

```verilog
initial begin
    Statement1;             //父线程，第1个执行
    #10 Statement2;         //父线程，第2个执行

    fork
        Statement3;         //子线程，第4个执行
        #50 Statement4;     //子线程，第9个执行
        #10 Statement5;     //子线程，第5个执行

        begin
            #20 Statement6; //子线程，第6个执行
            #10 Statement7; //子线程，第7个执行
        end

    join

    Statement8;             //父线程，第3个执行
    #50 Statement9;         //父线程，第8个执行
end
```

### 8.4 wait fork

&#160; &#160; &#160; &#160; 如果在fork join_any或fork join_none语句的后面没有延迟语句，可以使用wait fork语句等待所有的fork并发进程执行完成：

```verilog
task do_test;
    fork
        exec1;
        exec2;
    join_any

    fork
        exec3;
        exec4;
    join_none

    wait fork;  //会等待exec1、exec2、exec3、exec4全部执行完成
endtask
```

### 8.5 disable fork

&#160; &#160; &#160; &#160; 与wait fork相反，停止fork所有并发子线程的执行：

```verilog
task do_test;
    fork
        exec1;
        exec2;
    join_any

    fork
        exec3;
        exec4;
    join_none

    disable fork;  //exec1、exec2、exec3、exec4只要有一个执行完则会跳出fork
endtask
```

----

## 9 不定长赋值

* '0：所有位赋0；
* '1：所有位赋1；
* 'z：等于Verilog中的'bz；
* 'x：等于Verilog中的'bx。

----


## 10 循环语句性能增强

&#160; &#160; &#160; &#160; 举例说明吧，在Verilog中：

```verilog
module for4a(
    input               s,
    input      [31:0]   a,
    output reg [31:0]   y
);

    integer i;                  //独立的迭代变量声明

    always@(a or s)
        for (i=0;i<32;i=i+1)    //显式递增
            if(!s)
                y[i] = a[i];
            else
                y[i] = a[31-i];

endmodule
```

&#160; &#160; &#160; &#160; 而在SystemVerilog中：

```verilog
module for4a(
    input               s,
    input      [31:0]   a,
    output reg [31:0]   y
);


    always_comb
        for (int i=0;i<32;i++)      //本地迭代变量声明，退出循环后不存在
            if(!s)                  //隐式自动递增
                y[i] = a[i];
            else
                y[i] = a[31-i];

endmodule
```

----

## 11 断言

&#160; &#160; &#160; &#160; 当断言内的语句为真时，系统工具会执行相应操作：

```verilog
assert(ture condition)
```
----

## 12 增强case语句

### 12.1 case

&#160; &#160; &#160; &#160; case表达式的值是按位匹配，可以处理x和z：

```verilog
case(select[1:0])
    2'b00:  result = 0;
    2'b01:  result = 1;
    2'b0x,
    2'b0z:  result = flag;
    default:result = 'x;
endcase
```

### 12.2 casez

&#160; &#160; &#160; &#160; case且不关心z：

```verilog
casez(select[3:0])
    4'b000?:result = 0;
    4'b01??:result = 1;
    default:result = 'x;
endcase
```

### 12.3 casex

&#160; &#160; &#160; &#160; case且不关心x和z：

```verilog
casex(select[3:0])
    4'b000x:result = 0;
    4'b01xx:result = 1;
    default:result = 'x;
endcase
```


----

## 13 void函数

&#160; &#160; &#160; &#160; void用于定义没有返回值的函数。    

&#160; &#160; &#160; &#160; 与Verilog中的任务的异同：
* 相同点：
    * 不必从Verilog表达式中被调用，可以像Verilog的任务一样，被独立调用。
* 不同点：
    * 不能等待；
    * 不能包括延迟；
    * 不能包括事件触发；
    * 被always_comb搜寻到的信号自动加入敏感列表。

&#160; &#160; &#160; &#160; 舉例說明：

```verilog
module comb1(
    input  bit_t        a,b,c,
    output bit_t [2:1]  y
);

    always_comb         //等价于always@(a,b,c)
        orf1(a);
    
    function void orf1; //void函数的行为类似于0延迟的任务
        input a;        //b和c是隐含的输入
        y[1] = a|b|c;
    endfunction

    always_comb         等价于always@(a)
        ort1(a);
    
    task ort1;          //Verilog任务
        input a;        //b和c是隐含的输入
        y[2] = a|b|c;
    endtask

endmodule
```

----

## 14 结构体

### 14.1 结构体的使用

&#160; &#160; &#160; &#160; 在非面向对象编程中，最经常使用的就是函数。要实现一个功能，那么就要实现相应的函数。当要实现的功能比较简单时，函数可以轻易的完成目标。但是，当要实现的功能比较复杂时，仅仅使用函数实现会显得比较笨拙。



&#160; &#160; &#160; &#160; 结构保留了逻辑分组，虽然引用成员需要用比较长的表达式但是代码的意义很容易理解:

```verilog
struct {
    addr_t src_adr;
    addr_t dst_adr;
    data_t data;
} pkt;

initial begin
    pkt.src_adr = src_adr;          //把src_adr的值赋给pkt结构中的src_adr
    if(pkt.scr_adr == node.adr);    //把node结构中的adr区与pkt结构中的dst_adr区做比较
    ...
end
```

&#160; &#160; &#160; &#160; 结构、联合的打包：

```verilog
typedef logic [7:0] byte_t;

typedef struct packed{
    logic [15:0] opcode;
    logic [7:0]  arg1;
    logic [7:0]  arg2;
} cmd_t;

typedef union packed{
    byte_t [3:0] bytes;
    cmd_t        fields;
} instruction_u;

instruction_u cmd;
```

&#160; &#160; &#160; &#160; 可以得出，cmd为32位，cmd_t的区域为：

cmd.fields.opcode[15:0],cmd.fields.arg1[7:0],cmd.fields.arg2[7:0] 

&#160; &#160; &#160; &#160; 也等于：

cmd.byte[3],cmd.byte[2],cmd.byte[1],cmd.byte[0]

&#160; &#160; &#160; &#160; 打包的联合使得我们能方便地用不同的名称引用同一个数据。

### 14.2 从结构体到类

&#160; &#160; &#160; &#160; 结构体简单地将不同类型的几个数据放在一起，使得它们的集合体具有某种特定的意义。与这个结构体相对应的是一些函数操作。对于这些操作来说，如果没有了结构体变量，他们就无法使用；对于结构体变量来说，如果没有这些函数，那么结构体也没有任何意义。

&#160; &#160; &#160; &#160; 对于二者之间如此亲密的关系，面向对象的开创者们开创出了类（class）的概念。类将结构体和它相应的函数集合在一起，成为一种新的数据组织形式。在这种新的数据组织形式中，有两种成分，一种是来自结构体的数据变量，在类中被称为**成员变量**；另外一种来自与结构体相对应的函数，被称为一个类的**接口**：

```verilog
class animal;
    string  name;
    int     birthday;
    string  category;
    int     food_weight;
    int     is_healthy;

    function void print();
        $display("My name is %s", name);
        $display("My birthday is %d", birthday);
        $display("I am a %d", category);
        $display("I could eat %d gram food one day", food_weight);
        $display("My healthy status is %d", is_healthy);
    endfuntion
endclass
```

&#160; &#160; &#160; &#160; 当一个类被定义好后，需要将其实例化才可以使用。当实例化完成后，可以调用其中的函数：

```verilog
initial begin
    animal members[20];
    members[0] = new();
    members[0].name = "parrot";
    members[0].birthday = 20091021;
    members[0].category = "bird";
    members[0].food_weight = 20;
    members[0].is_healthy = 1;
    members[0].print();
end
```

&#160; &#160; &#160; &#160; 这里使用了new函数。new是一个比较特殊的函数，在类的定义中，没有出现new的定义，但是却可以直接使用它。在面向对象的术语中，new被称为构造函数。编程语言会默认提供一个构造函数，所以这里可以不定义而直接使用它。

#### 11.3 类的封装

&#160; &#160; &#160; &#160; 如果只是将结构体和函数集合在一起，那么类的优势并不明显，面向对象编程也不会如此流行。让面向对象编程流行的原因是类还是额外具有一些特征。这些特征是面向对象的精髓。通常来说，类有三大特征：封装、继承和多态。

&#160; &#160; &#160; &#160; 在上面的例子中，animal中有的成员变量对于外部来说都可见的，所以在initial语句中可以直接使用直接引用的方式对其进行赋值。这种直接引用的方式在某种情况下是危险的。当不小心将它们改变后，那么可能会因为会引起致命的问题，者有点类似于全局变量。由于对全局变量是可见的，所有全局变量的值可能被程序的任意部分改变，从而导致一系列的问题。

 









----
&#160; &#160; &#160; &#160; 告辞

