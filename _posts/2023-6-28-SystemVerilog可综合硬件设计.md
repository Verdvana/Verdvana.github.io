---
layout: post
title:  "SystemVerilog可综合硬件设计"
date:   2023-6-28 22:19:10 +0700
tags:
  - SystemVerilog
---

-------

## 1 前言

&#160; &#160; &#160; &#160; SystemVerilog完全兼容Verilog HDL，还加入了类似C++的语法用于验证。

&#160; &#160; &#160; &#160; SystemVerilog在硬件设计中有助于编写可综合硬件模型，对Verilog HDL的增强部分如下：
* 设计内部的封装通信和协议检查的接口；
* 类似于C语言的数据类型；
* 用户自定义类型；
* 枚举类型；
* 类型转换；
* 结构体和联合体；
* 可被多个设计快共享的定义包（package）；
* 外部编译单元区域（scope）声明；
* ++，--，+=以及其他赋值操作；
* 显式过程块；
* 优先级（priority）和唯一（unique）修饰符；
* 编程语句增强。

----

## 2 特定逻辑过程

### 2.1 always_ff

&#160; &#160; &#160; &#160; 描述时序逻辑电路模块，使用非阻塞赋值，如果过程内部写成组合逻辑，则会报错。

### 2.2 always_comb

&#160; &#160; &#160; &#160; 描述组合逻辑电路模块，使用阻塞赋值，如果过程内部写成锁存器，则会报错。

### 2.3 always_latch

&#160; &#160; &#160; &#160; 描述锁存器电路模块，使用非阻塞赋值，如果写成其他电路，则会报错。

----

## 3 新添加的数据类型

&#160; &#160; &#160; &#160; Verilog HDL的reg、integer和time变量的每一位都有四种逻辑；wire、wor、wand和其他线网（net）类型的每一位有120种值（四态逻辑加上多个强度级）及专用线逻辑决断函数。

&#160; &#160; &#160; &#160; Systemverilog有四态，两态和实型三种数据类型，其中**两态和实型不适合RTL设计**。

| 数据类型| 数据类型 | 位宽 | 标准 |
| --- | --- | --- | --- |
| reg | 4态 | 位宽可变 | Verilog-2001 |
| integer | 4态有符号 | 32 | Verilog-2001 |
| logic | 4态0，1，X，Z | 位宽可变 | SystemVerilog |
| bit | 2态0或1 | 位宽可变 | SystemVerilog |
| byte | 2态有符号整型 | 8 | SystemVerilog |
| shortint | 2态有符号整型 | 16 | SystemVerilog |
| int | 2态有符号整型 | 32 | SystemVerilog |
| longint | 2态有符号整型 | 64 | SystemVerilog |


### 3.1 Logic

&#160; &#160; &#160; &#160; 4态，0、1、X、Z，位宽可变，**可以代替所有其他类型，包括reg**。

&#160; &#160; &#160; &#160; `logic`类型类似于VHDL的`std_ulogic`类型：

* 对应的具体元件待定；
* 只允许使用一个驱动源，或者来自于一个或者多个过程块的过程赋值（对同一变量既进行连续赋值（`assign`）又进行过程赋值是非法的）；
* 在SV中，`logic`和`reg`是一致的（类似于Verilog中`wire`和`reg`类型是一致的）。

&#160; &#160; &#160; &#160; `wire`数据类型仍旧有用，因为：

* 用于多驱动源总线：如多路总线交换器；
* 用于双向总线（两个驱动源）。

&#160; &#160; &#160; &#160; 输入和输出：
* 当端口方向被声明为`input`或`inout`时：
    * 如果指定了`wire`，但没有指定数据类型，则默认为`logic`；
    * 如果指定了数据类型为没有关键字`wire`的`logic`，则数据类型仍为默认的`net`；
    * 如果整个数据类型未定义，则默认数据类型为`wire logic`；
* 当端口方向被声明为`output`：
    * 如果指定了`wire`，但没有指定数据类型，则默认为`logic`；
    * 如果整个数据类型未定义，则默认数据类型为`wire logic`；
    * 如果指定了数据类型为没有关键字`wire`的`logic`，则数据类型仍为默认的`var`。


&#160; &#160; &#160; &#160; 例如：
```verilog
module my_module (
    input   wire logic          clk,
    input   wire logic          en,
    input   wire logic [7:0]    din,
    inout   wire logic [7:0]    bus,
    output  var  logic [7:0]    dout,
    output  var  logic [7:0]    bus
);
```


### 3.2 real

&#160; &#160; &#160; &#160; 64位有符号数，等价于C中的`double`。

### 3.3 shortreal

&#160; &#160; &#160; &#160; 32位有符号数，等价于C中的`float`。

### 3.4 用户定义的类型——typedef

&#160; &#160; &#160; &#160; 允许生成用户定义的或者容易改变的类型定义，通常命名用“_t”做后缀：

```verilog
`ifdef STATE2
    typedef bit bit_t;  //2态
`else
    typedef logic bit_t;//4态
`endif
```

&#160; &#160; &#160; &#160; 用户自定义类型可以在局部定义，也可以在编译单元域进行外部定义。局部定义的类型声明写在`module`内，外部定义的类型声明写在`package`内。


&#160; &#160; &#160; &#160; 只要用`typedef`就能很容易的在4态和2态逻辑仿真之间切换以加快仿真速度。

&#160; &#160; &#160; &#160; 可以直接从`package`中引用自定义类型：

```verilog
package chip_types;
    `ifdef TWO_STATE
        typedef bit dtype_t;
    `else
        typedef logic dtype_t;
    `endif
endpackage

module counter(
    output  chip_types::dtype_t[15:0]   count,
    input   chip_types::dtype_t         clock,resetN
);
always_ff@(posedge clock, negedge resetN)begin
    if(!resetN) count <= 0;
    else        count <= count + 1;
end
endmodule
```

&#160; &#160; &#160; &#160; 如果觉得这样每个端口都需要引用包名很繁琐，也可以将包定义导入到`$unit`编译单元域中：

```verilog
package chip_types;
    `ifdef TWO_STATE
        typedef bit dtype_t;
    `else
        typedef logic dtype_t;
    `endif
endpackage

import chip_types::dtype_t;

module counter(
    output dtype_t [15:0]   count,
    input  dtype_t          clock,resetN 
);
always_ff@(posedge clock, negedge resetN)begin
    if(!resetN) count <= 0;
    else        count <= count + 1;
end
endmodule
```




### 3.5 枚举——enum

&#160; &#160; &#160; &#160; 缺省状态下为2态整型（`int`）变量：

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


&#160; &#160; &#160; &#160; 当枚举类型从包中导入时，**只有类型名被导入，枚举列表中的数值标签不会被导入**，因此不会在枚举类型名导入的命名范围中可见。下面的代码将不会正确工作：

```verilog
package chip_types;
    typedef enum {WAITE,LOAD,READY} states_t;
endpackage

module chip(...);
    import  chip_types::states_t;   //只导入typedef名
    states_t state,next_state;

    always_ff@(posedge clk, negedge resetN)begin
        if(!resetN)
            state   <= WAITE;       //错误，“WAITE”还未导入
        else
            state   <= next_state;
    end
...
endmodule
```

&#160; &#160; &#160; &#160; 为了使枚举类型标签可见，可以显式导入每个标签，或用通配符导入整个包。通配符导入将使枚举类型名和枚举值标签在`import`语句作用域内都可见。

### 3.6 有符号/无符号声明

&#160; &#160; &#160; &#160; SystemVerilog在声明变量时能够指定变量是否有符号：

```verilog
<size> '[s|S] b|d|o|h : [01...xXzZ]
```


&#160; &#160; &#160; &#160; 例如：

```verilog
logic [7:0] a,b,c,d;
assign a = 1'b1;        //8'b0000_0001
assign b = 8'b1;        //8'b0000_0001
assign c = 1'sb1;       //8'b1111_1111
assign d = 8'sb1;       //8'b0000_0001
```

### 3.7 Net与Var

* `net`数据类型：
    * 代表物理连接；
    * 通常用于模块接口列表
    * 使用`wire`创建：
        ```verilog
        wire logic [15:0]   dout;
        ```
    * 只能由连续赋值语句驱动，不能被`always`块驱动。
* `var`数据类型：
    * 代表数据存储单元；
    * 通常用于模块内部值的本地存储；
    * 使用`var`创建：
        ```verilog
        var logic [15:0]    bus;
        ```
    * 能被`always`块或连续赋值语句驱动。


----

## 4 数组与队列

### 4.1 固定数组

&#160; &#160; &#160; &#160; 固定数组的定义举例：

```verilog
integer numbers [5];                            //二维数组（5×32），未赋初值
int     b[2]        = '{ 3,7 };                 //一维数组，赋初值3，7
int     c[2][3]     = '{ { 3,7,1 },{ 5,1,9 } }; //二维数组赋初值
byte    d[7][2]     = '{default:-1};            //所有数据赋值为“-1”
bit [31:0] a[2][3]  = c;                        //把矩阵c复制给a
```

&#160; &#160; &#160; &#160; 以下定义仅在仿真时可用：
```verilog
bit [7:0]   d [];           //动态数组
bit [7:0]   d [$];          //队列数组
bit [7:0]   d [data_type];  //联合数组
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

![img1][img1]

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

&#160; &#160; &#160; &#160; `function`概述：
* 执行时不消耗仿真时间；
* 不能有控制仿真时间的语句，例如`task`中的延时等；
* 不能调用`task`；
* `void function`没有返回值；


&#160; &#160; &#160; &#160; `function`语法为：
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

&#160; &#160; &#160; &#160; SystemVerilog中增加了`return`语句。`return`用于退出`task`和`function`，执行时返回表达式的值，否则最后的返回数值赋值给函数名。

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
* 增加了`input`、`output`传输参数
* 每一个形式参数都有一个默认的类型，调用`task`和`function`时，不必给就具有默认参数值的参数传递数值，如果不传递参数值，就会使用默认值。如上一节的例子。 

&#160; &#160; &#160; &#160; 使用引用（reference）代替复制的方式传递参数：
* 常见的向`task`和`function`传递参数值的方式是复制；
* 使用reference的方式显式地向`task`和`function`传递参数：
    * 关键字`ref`取代了`input`、`output`、`inout`；
    * 只有`automatic`任务和函数才可以使用`re`f参数。

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

&#160; &#160; &#160; &#160; SystemVerilog中除了`fork join`之外还增加了`fork join_any`和`fork join_none`。

### 8.1 fork join

&#160; &#160; &#160; &#160; 当`fork join`中的子线程都执行完之后才会跳出`fork`继续执行父线程语句，例如：


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

&#160; &#160; &#160; &#160; 当`fork join_any`中的子线程有一条执行完，则会跳出fork继续执行父线程的语句，在父线程中遇到延时等语句后又会继续执行`fork`，此时变为`fork join`，但执行的时长为父线程中遇到的延时语句的时长，如果父线程中没有延时语句，则不会再进入`fork`，例如：


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

&#160; &#160; &#160; &#160; 先执行父线程的语句，如果父线程中有延时语句，才会进入`fork`执行子线程：

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

&#160; &#160; &#160; &#160; 如果在`fork join_any`或`fork join_none`语句的后面没有延迟语句，可以使用`wait fork`语句等待所有的`fork`并发进程执行完成：

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

&#160; &#160; &#160; &#160; 与`wait fork`相反，停止`fork`所有并发子线程的执行：

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

&#160; &#160; &#160; &#160; SystemVerilog还增加了数组循环方式：
```verilog
logic value [5];
foreach (value[i]) begin
    value[i] = ...;
end
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

&#160; &#160; &#160; &#160; `case`表达式的值是按位匹配，可以处理x和z：

```verilog
case(select[1:0])
    2'b00:  result = 0;
    2'b01:  result = 1;
    2'b0x,
    2'b0z:  result = flag;
    default:result = 'x;
endcase
```


&#160; &#160; &#160; &#160; `case`语句支持通过`inside`关键字设置成员关系，支持通配符和范围：
```verilog
logic [2:0] status;
always_comb begin
    case(status) inside
        1，3            : task1();  //match 'b001 and 'b011
        3'b0?0,[4:7]    : task2();  //match 'b000 'b010 'b0x0 'b0z0
                                    //      'b100 'b101 'b110 'b111
    endcase
end
```

### 12.2 casez

&#160; &#160; &#160; &#160; `case`且不关心z和通配符?：

```verilog
casez(select[3:0])
    4'b000?:result = 0;
    4'b01??:result = 1;
    default:result = 'x;
endcase
```

&#160; &#160; &#160; &#160; **综合不支持expression里有通配符的情况：**
```verilog
//Supported by synthesis
casez(status)
    3'b?0?  :task();        //match 'b000 'b010 'b0z0
endcase

//Not supported by synthesis
casez(3'b?0?)
```

### 12.3 casex

&#160; &#160; &#160; &#160; `case`且不关心x、z和通配符?：

```verilog
casex(select[3:0])
    4'b000x:result = 0;
    4'b01xx:result = 1;
    default:result = 'x;
endcase
```

&#160; &#160; &#160; &#160; **综合不支持expression里有通配符的情况：**
```verilog
//Supported by synthesis
casex(status)
    3'b?0?  :task();        //match 'b000 'b010 'b0z0 'b0x0
endcase

//Not supported by synthesis
casex(3'b?0?)
```

### 12.4 修饰符

&#160; &#160; &#160; &#160; SystemVerilog针对以上三个语句增加了两个修饰符，分别是`unique`和`priority`，语法如下：

```verilog
unique case (<expression>)
    ...
endcase

priority case (<expression>)
    ...
endcase
```

* `unique`：
    * expression同时只能匹配一个selection；
    * 一个selection必须存在与之对应的expression；
    * 修饰case语句是完整且并行的，各case分支之间相互排斥没有交叠；
* `unique0`：
    * 在SystemVerilog 2012版本之后增加了`unique0`；
    * 当所有的selection不能与expression匹配，此时不会产生Warning，输出保持上一次匹配时的输出；
* `priority`：
    * 至少有一个selection需要匹配expression；
    * 如果存在多个selection匹配expression，则第一个匹配的分支会被执行。

&#160; &#160; &#160; &#160; 在综合时，需要考虑[full_case和parallel_case属性](https://blog.csdn.net/main_michael/article/details/108395142)。



----

## 13 void函数

&#160; &#160; &#160; &#160; `void`用于定义没有返回值的函数。    

&#160; &#160; &#160; &#160; 与Verilog中的任务的异同：
* 相同点：
    * 不必从Verilog表达式中被调用，可以像Verilog的任务一样，被独立调用。
* 不同点：
    * 不能等待；
    * 不能包括延迟；
    * 不能包括事件触发；
    * 被`always_comb`搜寻到的信号自动加入敏感列表。

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

## 14 包（package）

### 14.1 定义

&#160; &#160; &#160; &#160; 为了使多个模块共享用户定义类型的定义，SystemVerilog语言增加了包，与VHDL类似，包在`package`和`endpackage`之间定义。

&#160; &#160; &#160; &#160; 包中可以包含的可综合的结构有：
* `parameter`和`localparam`常量定义（这俩在`package`里是一样的）；
* `const`变量定义；
* `typedef`用户定义类型；
* 全自动`task`和`function`定义；
* 从其他包中`import`语句；
* 操作符重载定义。


&#160; &#160; &#160; &#160; 在包中还可以进行全局变量声明、静态任务定义和静态函数定义，但这些是**不可综合的**。

&#160; &#160; &#160; &#160; 包是一个独立的声明空间，不需要包含在Verilog模块中。举例：

```verilog
package definitions;
    parameter   VERSION = "1.1";

    typedef emnum {ADD,SUB,MUL} opcodes_t;

    typedef struct{
        logic [31:0]    a,b;
        opcodes_t       opcode;
    }instruction_t;

    function automatic [31:0] multiplier (input [31:0] a,b);
        //用户定义的32位乘法代码从这开始
        return a*b；
    endfunction
endpackage
```

&#160; &#160; &#160; &#160; 包中可能包含`parameter`、`localparam`和`const`等常量定义。在Verilog中，`module`的每个实例可以对`parameter`常量重新定义，但不能对`localparam`直接重定义，但包中的`parameter`不能被重定义，因为它不是模块实例的一部分，**在包中，`parameter`和`localparam`是相同的**。

### 14.2 引用包的内容

&#160; &#160; &#160; &#160; 模块和接口可以用四种方式引用包中的定义和声明：
* 用范围解析操作符直接引用；
* 将包中特定子项导入到模块或接口中；
* 用通配符导入包中的子项到模块或接口中；
* 将包中子项导入到`$unit`声明域中。

&#160; &#160; &#160; &#160; 相对于Verilog，SystemVerilog增加了**作用域解析操作符**“：：”。这一操作符允许通过包的名称直接引用包，然后选择包中特定的定义或声明。包名和包中子项名用双冒号“：：”隔开。例如，SystemVerilog的端口可定义为instruction_t类型（之前的例子），举例：

```verilog
module ALU(
    input   definitions::instruction_t  IW,
    input   logic                       clock,
    output  logic [31:0]                result
);

    always_ff@(posedge clock)begin
        case(IW.opcode)
            definitions::ADD :  result  <= IW.a + IW.b;
            definitions::SUB :  result  <= IW.a - IW.b;
            definitions::MUL :  result  <= definitions::multiplier(IW.a, IW.b);
        endcase
    end
endmodule
```

&#160; &#160; &#160; &#160; 显式地引用包中的内容有助于提高设计的源代码的可读性，但是当包中的一项或多项需要在模块中多次引用时，每次显示地引用包的名称则太过麻烦，所以希望将包中子项导入到设计块中。


&#160; &#160; &#160; &#160; SystemVerilog中允许用`import`语句**将包中特定子项导入到模块中**。当包定义或声明导入到模块或接口中时，该子项在模块或接口内是可见的，就好像它是该模块或接口中的一个局部定义名一样，这样就不需要每次引用包中子项时都显式引用包名。将上面的例子修改为以下代码，使用导入语句使枚举类型的元素成为模块内的局部名称，然后`case`语句就可以引用这些名称而不用每次都显式的使用包名：

```verilog
module ALU(
    input   definitions::instruction_t  IW,
    input   logic                       clock,
    output  logic [31:0]                result
);

    import  definitions::ADD;
    import  definitions::SUB;
    import  definitions::MUL;
    import  definitions::multiplier;

    always_comb begin
        case(IW.opcode)
            ADD :  result  <= IW.a + IW.b;
            SUB :  result  <= IW.a - IW.b;
            MUL :  result  <= multiplier(IW.a, IW.b);
        endcase
    end
endmodule
```

&#160; &#160; &#160; &#160; 导入枚举类型定义并不导入那个定义使用的元素，在上面的例子中，下面的导入语句不会起作用：

```verilog
    import  definations::opcode_t;
```

&#160; &#160; &#160; &#160; 这个导入语句会使用户定义的类型opcode_t在模块中可见，但它不会使opcode_t中使用的枚举元素可见。为使元素在模块内成为可见的局部名称，每个枚举元素必须显式导入，当有许多子项需要从包中导入时，使用通配符导入更实用。

&#160; &#160; &#160; &#160; SystemVerilog允许包中子项**使用通配符导入**，而不用指定包中子项名称。通配符记号是一个星号（*），例如：

```verilog
    import  definations::*;
```

&#160; &#160; &#160; &#160; 通配符导入并不能自动导入包中的所有内容，只有在模块或接口中实际使用的子项才会被真正导入，没被引用的包中的定义和声明不会被导入。

&#160; &#160; &#160; &#160; 模块或接口内的局部定义和声明优先于通配符导入。包中指定子项名称的导入也优选于通配符导入。从设计者的角度来看，通配符导入只是简单地将包添加到标识符（identifier）搜索规则中。EDA软件将先搜索局部声明（遵循Verilog在模块内的搜索规则），然后在通配符导入的包中搜索，最后将在&unit声明域中搜索。

&#160; &#160; &#160; &#160; 下面的例子中使用通配符导入语句，实际上是把包添加到标识符搜索路径中。当`case`语句引用ADD、SUB和MUL及函数multiplier等枚举元素时，就会在dufinitions包中查找这些名称的定义：

```verilog
module ALU(
    input   definitions::instruction_t  IW,
    input   logic                       clock,
    output  logic [31:0]                result
);

    import  definitions::*;     //通配符导入

    always_comb begin
        case(IW.opcode)
            ADD :  result  <= IW.a + IW.b;
            SUB :  result  <= IW.a - IW.b;
            MUL :  result  <= multiplier(IW.a, IW.b);
        endcase
    end    
endmodule
```

&#160; &#160; &#160; &#160; 在以上例子中，对于模块端口IW，包名仍需显式引用，因为不能在关键字module和模块端口定义之间加入一个`import`语句。但是使用`$unit`声明域可以避免在端口列表中显式引用包名称。


### 14.3 可综合性

&#160; &#160; &#160; &#160; 当模块引用一个包中定义的任务或函数时，综合会复制该任务或函数的功能并把它看作是已经在模块中定义了的。

&#160; &#160; &#160; &#160; 为了能够综合，**包中定义的任务和函数必须声明为automatic，并且不能包含静态变量**。因为自动任务或函数的存储区在每次调用时才会分配。这就保证了综合前对包中任务或函数引用的仿真行为与综合后的行为相同。综合后，这些任务或函数的功能就在引用的一个或多个模块中实现。

&#160; &#160; &#160; &#160; 由于类似的原因，综合不支持包中的变量声明。仿真时，包中的变量会被导入该变量的所有模块共享。一个模块向变量写值，另一个模块看到的就将是新值。这类不通过模块端口传递数据的模块间通信是不可综合的。

----

## 15 $unit编译单元声明

### 15.1 定义

&#160; &#160; &#160; &#160; 相比Verilog，SystemVerilog增加了编译单元的概念。编译单元是同时编译所有源文件。编译单元为软件工具提供了一种对于整个设计的各个子块单独编译的方法。一个子块可能包含一个或多个`module`，这些`module`可能包含在一个或多个文件中。设计的子块还可能包含接口块和测试程序块。

&#160; &#160; &#160; &#160; SystemVerilog允许在包、模块、接口和程序块的外部进行声明，这些外部声明在“编译单元域”中都是可见的，并且对所有同时编译的模块都是可见的。

&#160; &#160; &#160; &#160; 编译单元域可以包含：
* 时间单位和精度声明；
* 变量声明；
* net声明；
* 常量声明；
* 用户定义数据类型，使用`typedef`、`enu`m或`class`；
* 任务和函数定义。

&#160; &#160; &#160; &#160; 举例：

```verilog
/****************************外部声明****************************/
parameter   VERSION = "1.2a"    //外部常量
reg         resetN  = 1;        //外部变量，低有效
typedef     struct  packed{
    reg [31:0]  address;
    reg [31:0]  data;
    reg [31:0]  opcode;
}instruction_word_t;

function automatic int log2(input int n);   //外部函数
    if(n<=1)return(1);
    log2    = 0;
    while(n>1)begin
        n   = n/2;
        log2++;
    end
    return(log2)
endfunction

/****************************模块声明****************************/
//用外部声明定义端口类型
module register (
    output  instruction_word_t  q,
    input   instruction_word_t  d,
    input   wire                clock
);

    always_ff@(posedge clock, negedge resetN)
        if(!resetN) q <= 0;
        else        q <= d;

endmodule
```

&#160; &#160; &#160; &#160; **外部编译单元域声明不是全局的，只作用于同时编译的源文件，每次编译源文件，就创建一个唯一仅针对此次变异的编译单元域。**

### 15.2 编码指导

* 不要在`$unit`空间进行任何声明，所有的声明都要在命名包内进行；
* 必要时可以将包导入到`$unit`中。这在模块或接口的多个端口使用用户自定义类型，而这个类型定义又在包中时非常有用。

### 15.3 SystemVerilog标识符搜索规则

&#160; &#160; &#160; &#160; 编译单元域中的任何声明可以再组成编译单元的模块的任何层次引用。

&#160; &#160; &#160; &#160; SystemVerilog定义了简单直观的搜索规则来引用标识符：
* 搜索那些按IEEE 1364 Verilog标准定义的局部声明；
* 搜索通配符导入到当前作用域的包中的声明；
* 搜索编译单元域中的声明；
* 搜索设计层次中的声明，遵循IEEE 1364 Verilog搜索规则。


&#160; &#160; &#160; &#160; SystemVerilog搜索规则保证了SystemVerilog完全向后兼容。

### 15.4 源代码顺序

&#160; &#160; &#160; &#160; 数据标识符和类型标识符必须在引用前声明。未声明的标识符假定为net类型（通常为`wire`类型）。EDA工具必须在标识符引用之前找到外部声明，否则，这个名称将被看做未声明的标识符并遵守Verilog隐式类型的规则。举例：

```verilog
module parity_gen (
    input   wire [63:0] data
);
    assign  parity  = ^data;    //parity是一个隐式局部net
endmodule

reg parity;                     //因为声明在被parity_gen引用之后出现
                                //因此外部声明没被模块parity_gen使用
module parity_check(
    input   wire [63:0] data,
    output  logic       err
);
    assign  err = (^data != parity);    //parity是$unit变量
endmodule
```

### 15.5 将包导入$unit的编码规则

&#160; &#160; &#160; &#160; SystemVerilog允许将模块端口声明为用户定义类型。如之前的例子：
```verilog
module ALU(
    input   definitions::instruction_t  IW,
    input   logic                       clock,
    output  logic [31:0]                result
);
```

&#160; &#160; &#160; &#160; 当许多模块端口都是用户自定义类型时，像上面那样显式的引用包就会显得繁琐。一种可选择的风格是在模块声明之前将包导入到`$unit`编译单元域中。这样用户定义类型的定义在SystemVerilog搜索序列中可见，例如：

```verilog
//将包中特定子项导入到$unit中
import  definitions::instruction_t;

module ALU(
    input   instruction_t   IW,
    input   logic           clock,
    output  logic [31:0]    result
);
endmodule
```

&#160; &#160; &#160; &#160; 包还可以通过通配符导入到`$unit`域中，注意通配符导入实际上不能导入包中所有子项。它只能将包加到SystemVerilog源路径中：

```verilog
//将包中特定子项导入到$unit中
import  definitions::*;

module ALU(
    input   instruction_t   IW,
    input   logic           clock,
    output  logic [31:0]    result
);
endmodule
```

&#160; &#160; &#160; &#160; 每个需要保重定义的设计或测试平台都应该将`package`文件包含在文件的开始：

```verilog
`include "xxx.pkg"
```

&#160; &#160; &#160; &#160; 如果包已经编译并导入到当前`$unit`域中，该文件的编译将被忽略。

----

## 16 仿真时间单位和精度

### 16.1 包含时间单位的时间值

&#160; &#160; &#160; &#160; Verilog HDL不在时间值中指定时间的单位，SystemVerilog可以给时间值指定时间单位。允许的时间单位如下表：

| 单位 | 描述 |
| --- | --- |
| s | 秒 |
| ms | 毫秒 |
| us | 微秒 |
| ns | 纳秒 |
| ps | 皮秒 |
| fs | 飞秒 |
| step | 软件工具使用的最小时间单位 |


&#160; &#160; &#160; &#160; **时间值和单位值之间不允许有空格**。

### 16.2 范围级（scope-level）时间单位和精度

&#160; &#160; &#160; &#160; SystemVerilog允许指定局部性的时间单位和精度，作为模块、接口或程序块的一部分，而不是作为软件工具的指令。

&#160; &#160; &#160; &#160; 在SystemVerilog中，通过使用关键字``timeunit`和`timeprecision`进一步增强了时间单位的说明，这些关键字作为模块定义的一部分，用来指定模块内的时间单位和精度信息，且必须在其他任何声明或语句之前、紧随模块、接口或程序的声明之后指定。例如：

```verilog
module adder(
    input   wire [63:0] a,b,
    output  reg  [63:0] sum,
    output  reg         carry
);
    timeunit        1ns;  
    timeprecision   10ps;

endmodule
```

### 16.3 编译单元的时间单位和精度

&#160; &#160; &#160; &#160; SystemVerilog中，时间单位和精度值可以在很多地方指定。SystemVerilog定义了一个搜索法则来确定时间值的单位和精度：
* 如果时间值带单位，则使用指定的单位；
* 否则，使用在模块、接口和程序块内部指定的时间单位和精度；
* 否则，如果模块或接口声明嵌入到其他的模块和接口内，使用父模块接口或接口指定的时间单位和精度。
* 否则，使用模块编译时，有效的`timeacale时间单位和精度；
* 否则，使用在编译单元域中定义的时间单位和精度；
* 否则，使用仿真器默认的时间单位和精度。

&#160; &#160; &#160; &#160; 举例说明：

```verilog
timeunit        1ns;        //外部声明的时间单位和精度
timeprecision   1ns;

module my_chip(...);

    timeprecision   1ps;    //局部精度（优先于外部精度）

    always@(posedge data_request)begin
        #2.5    send_packet;//使用外部单位和局部精度
        #3.7ns  check_crc;  //使用指定的单位
    end

    task send_packet();
        ...
    endtask

    task check_crc();
        ...
    endtask

endmodule



`timescale  1ps/1ps         //`timescale指令指定的单位和精度，优于外部声明

module FSM(...)
    timeunit    1ns;        //局部声明优于`timescale的指定

    always@(state)begin
        #1.2    case(state) //使用局部声明的单位和`timescale指定的精度
            WAITE:  #20ps;  //使用此处指定的单位
            ...
        endcase
    end
endmodule
```

----

## 17 `define增强

### 17.1 字符串内的宏变量替换

&#160; &#160; &#160; &#160; Verilog HDL的\`define宏中使用的双引号内的文本变成了文本串，不能在字符串中嵌入宏变量的文本替换宏创建字符串。而SystemVerilog可以进行宏文本字符串内的变量替换，这是通过在形成字符串的引号前加重音号“\`”来实现。例如：

```verilog
`define print(v)    $display(`"variable v = %h`" ,v);

`print(data);
```

### 17.2 通过宏建立标识符名

&#160; &#160; &#160; &#160; Verilog HDL的\`define宏不能通过连接两个或多个文本宏来建立一个新标识符，SystemVerilog提供了一个不引入空格的方法，使用两个连接的重音符号“`”，使两个或多个文本宏连接成一个新名字。

&#160; &#160; &#160; &#160; 在无文本替换的源文件中，是这样声明：

```verilog
bit d00_bit;    wand d00_net = d00_bit;
bit d01_bit;    wand d01_net = d01_bit;
... //对每一位都重复60多次
bit d62_bit;    wand d62_net = d62_bit;
bit d63_bit;    wand d63_net = d63_bit;
```

&#160; &#160; &#160; &#160; 使用SystemVerilog对`define的增强，代码可简化为：

```verilog
`define TWO_STATE_NET(name) bit name``_bit;  wand name``_net  = name``_bit;

`TWO_STATE_NET(dOO);
`TWO_STATE_NET(dO1);
...
`TWO_STATE_NET(d62);
`TWO_STATE_NET(d63);
```

----

## 18 通配符和三态逻辑

### 18.1 比较操作符

&#160; &#160; &#160; &#160; 在SystemVerilog中，比较操作符支持通配符：
* 新加入的比较操作符是`==?`和`!=?`；
* 允许屏蔽掉比较数中不关心的bit；
* 右操作数中的`x`、`z`、`?`可以作为通配符不与左操作数进行比较；
* 不能将左操作数中的`x`、`z`视为通配符；

### 18.2 case语句支持的通配符

&#160; &#160; &#160; &#160; 这部分在12章说过了。

### 18.3 三态门的综合

&#160; &#160; &#160; &#160; 三态信号必须是net（wire）类型，必须在连续赋值语句中被驱动：
```verilog
wire    D_out;
assign  D_out = (x) ? A : 'z;   //'z的条件复制意味着综合为一个三态门
```




<div style='display: none'>

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

#### 14.3 类的封装

&#160; &#160; &#160; &#160; 如果只是将结构体和函数集合在一起，那么类的优势并不明显，面向对象编程也不会如此流行。让面向对象编程流行的原因是类还是额外具有一些特征。这些特征是面向对象的精髓。通常来说，类有三大特征：封装、继承和多态。

&#160; &#160; &#160; &#160; 在上面的例子中，animal中有的成员变量对于外部来说都可见的，所以在initial语句中可以直接使用直接引用的方式对其进行赋值。这种直接引用的方式在某种情况下是危险的。当不小心将它们改变后，那么可能会因为会引起致命的问题，者有点类似于全局变量。由于对全局变量是可见的，所有全局变量的值可能被程序的任意部分改变，从而导致一系列的问题。

 
</div>








----
&#160; &#160; &#160; &#160; 告辞

[img1]:data:image/png;base64,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1svr/sWq/zbt1wQAABhEAjUAAIAexei09pSNMd1iryJU+7OVq+pWKV//4um16l5ML9mLeM0/PfEv61Yp1/y/360VAAAAGYEaAABAj6747v+oVSlHvPOYdLrFzB/98btqNTRiLNY661aMTptsesnx/NHbRl7z6ssuqRUAAAAZgRoAAECP/vVfrqpVKYcc/se16l0EcQcfdmTdKuWOW2+s1eT2f/2batWbCOG223GXujU02g4AAICcQA0AAKBHMZqsseMuu9dqanZfvl+tSnn80Z/WanI777ZXrXq3fStQW/fYI7UCAABgIgI1AACAHoydlnEq0y62bbX1glqVctdt/1aryb3ilVvVqndTDfEAAAAGlUANAACgBz9//Ge1mnnPPfN0rSa3615716p37RAPAACAyQnUAAAAAAAAICFQAwAA6ME2r31drWZeL9NHjp16shc/e/jBWgEAANANgRoAAEAPxoZe0wm2Qjvcet32O9ZqctOZerL9nnfefVmtAAAAmIhADQAAoEd77r1/rUp58Cd312pq7rz1plr1Fm7df88dterdHbfcWKtSFr12Sa0AAACYiEANAACgRwe+8YhalXLt1f9Uq97FSLE7fzQSqO24y+61mtxN1/2gVr25944flWfWP9Wpt16wsOy6196dGgAAgIkJ1AAAAHp0+FHvqVUpV3334rL+qSfrVm++//98p1alHHzYkT2toXb1ZZdM6XWvvvxbtSrliHceUysAAAAyAjUAAGBgbfPa19WqNzGqKwKwEKO9vrj6/+zUvYjRaX9/7l/XrVLe99GTa9W9i877Sq26E6/5f//91+tWKX/yv32gVgAAAGQEagAAwMAaOyKslxFfH/7U52o1NFrsqksvrluTi9f5v1auGJ568fC3H132PvCQTt2LC7+2puvXHfua7/rTD5nuEQAAoEsCNQAAYKDFOmKN7//TyBSMk4kw6tSz/3vdKuW0T/1ZJ7CKUWCZCMD+jz8+aHjttD333r/8xar/1ql7cfxHVna+xut+c+05aRj4oxuuLZ/58LGjXvODJ/1VpwYAAGByW7y0Qa372pEr19aqlFNPtA4AAADQnQijzj1rZLRZjNx63fY71q1Sfvbwg2Xfgw4tR7xj/HZGBGQRarXFdJD7H/JHdWtIPM+//stV5ZEHf1LvGQq2zvzbi8qCha+p9+TesmzkcVfc/mT5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AABAwpSPMIYpHwHmLlNUAADMXdrTAHOX9jSbmikfAQAAAAAAYMAJ1AAAAAAAACAhUAMAAAAAAICEQA0AAAAAAAASAjUAAAAAAABICNQAAAAAAAAgIVADAAAAAACAhEANAAAAAAAAEgI1AAAAAAAASAjUAAAAAAAAICFQAwAAAAAAgIRADQAAAAAAABICNQAAAAAAAEgI1AAAAAAAACAhUAMAAAAAAICEQA0AAAAAAAASAjUAAAAAAABICNQAAAAAAAAgIVADAAAAAACAhEANAAAAAAAAEgI1AAAAAAAASAjUAAAAAAAAICFQAwAAAAAAgIRADQAAAAAAABICNQAAAAAAAEgI1AAAAAAAACAhUAMAAAAAAICEQA0AAAAAAAASAjUAAAAAAABICNQAAAAAAAAgIVADAAAAAACAhEANAAAAAAAAEgI1AAAAAAAASAjUAAAAAAAAICFQAwAAAAAAgIRADQAAAAAAABICNQAAAAAAAEgI1AAAAAAAACAhUAMAAAAAAICEQA0AAAAAAAASAjUAAAAAAABICNQAAAAAAAAgIVADAAAAAACAhEANAAAAAAAAEgI1AAAAAAAASAjUAAAAAAAAICFQAwAAAAAAgIRADQAAAAAAABICNQAAAAAAAEgI1AAAAAAAACAhUAMAAAAAAICEQA0AAAAAAAASAjUAAAAAAABICNQAAAAAAAAgIVADAAAAAACAhEANAAAAAAAAEgI1AAAAAAAASAjUAAAAAAAAICFQAwAAAAAAgIRADQAAAAAAABICNQAAAAAAAEgI1AAAAAAAACAhUAMAAAAAAICEQA0AAAAAAAASAjUAAAAAAABICNQAAAAAAAAgIVADAAAAAACAhEANAAAAAAAAEgI1AAAAAAAASAjUAAAAAAAAICFQAwAAAAAAgIRADQAAAAAAABICNQAAAAAAAEgI1AAAAAAAACAhUAMAAAAAAICEQA0AAAAAAAASAjUAAAAAAABICNQAAAAAAAAgIVADAAAAAACAhEANAAAAAAAAEgI1AAAAAAAASAjUAAAAAAAAICFQAwAAAAAAgIRADQAAAAAAABICNQAAAAAAAEgI1AAAAAAAACAhUAMAAAAAAICEQA0AAAAAAAASAjUAAAAAAABICNQAAAAAAAAgIVADAAAAAACAhEANAAAAAAAAEgI1AAAAAAAASAjUAAAAAAAAICFQ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