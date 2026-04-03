---
layout: post
title:  "从零开始搭建SoC系统（基于DE1-SoC开发板）"
date:   2019-1-1 9:18:10 +0700
tags:
  - FPGA SoC
---

-------
### 1.前言

&#160; &#160; &#160; &#160; 参考小梅哥的SoC教程和友晶DE1-SoC开发板黄金硬件设计工程，从零开始搭建DE1-SoC开发板的SoC系统。需要一定SOPC开发基础。

* 开发环境：
    * Quartus Prime Standard 18.1
    * SoC EDS Command Shell
* 操作系统：
    * Windows 10 Pro 1809

------------------

### 2.搭建工程

#### 2.1 新建工程

&#160; &#160; &#160; &#160; 新建工程，我这里工程名为“DE1_SoC_GHRD”。

&#160; &#160; &#160; &#160; 打开Platform Designer。

#### 2.3 配置时钟
&#160; &#160; &#160; &#160; 默认50MHz。

#### 2.3 添加硬核IP
&#160; &#160; &#160; &#160; 在左边的IP Catalog中查找关键字：“hps”，选择“Arria V/Cyclone V Hard Processor System”，如图：

![1](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/1.jpg)

&#160; &#160; &#160; &#160; 然后修改硬核参数，按照下图修改参数：

&#160; &#160; &#160; &#160; 首先是FPGA接口：

![2](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/2.jpg)

&#160; &#160; &#160; &#160; 然后是外设引脚设置：

![3](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/3.jpg)

&#160; &#160; &#160; &#160; HPS时钟设置，包括输入时钟和输出时钟：

![4](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/4.jpg)

![5](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/5.jpg)

&#160; &#160; &#160; &#160; 最后是SDRAM设置：

![6](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/6.jpg)

![7](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/7.jpg)

![8](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/8.jpg)

![9](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/9.jpg)

&#160; &#160; &#160; &#160; 看不清图片可以右键在新窗口打开然后放大看🔍。

&#160; &#160; &#160; &#160; 修改名称为“hps_0”:

![12](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/12.jpg)


#### 2.4 添加System ID

&#160; &#160; &#160; &#160; 搭建过Nios Ⅱ就不用说了，一样的。

#### 2.5 添加串口

&#160; &#160; &#160; &#160; 在IP Catalog中查找关键字：“uart”，选择“UART(RS232 Serial Port)Intel FPGA IP”，如图：

![10](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/10.jpg)

&#160; &#160; &#160; &#160; 默认参数即可：

![11](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/11.jpg)

&#160; &#160; &#160; &#160; 修改名称为“uart_0”:

![13](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/13.jpg)

#### 2.6 添加SPI

&#160; &#160; &#160; &#160; 在IP Catalog中查找关键字：“spi”，选择“SPI(3 Wire Serial)Intel FPGA IP”，如图：

![14](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/14.jpg)

&#160; &#160; &#160; &#160; 修改参数：

![15](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/15.jpg)

&#160; &#160; &#160; &#160; 修改名称为“spi_0”:

![16](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/16.jpg)

#### 2.7 添加LED PIO

&#160; &#160; &#160; &#160; 在IP Catalog中查找关键字：“pio”，选择“PIO Intel FPGA IP”，如图：

![17](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/17.jpg)

&#160; &#160; &#160; &#160; 修改参数：

![18](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/18.jpg)

&#160; &#160; &#160; &#160; 修改名称为“led_pio”:

![19](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/19.jpg)

#### 2.8 添加BUTTON PIO

&#160; &#160; &#160; &#160; 在IP Catalog中选择“PIO Intel FPGA IP”。

&#160; &#160; &#160; &#160; 修改参数：

![20](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/20.jpg)

&#160; &#160; &#160; &#160; 修改名称为“button_pio”:

![21](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/21.jpg)

#### 2.9 连线并修改外设引脚

&#160; &#160; &#160; &#160; 按照下图连线和引出外设:

![22](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/22.jpg)

#### 2.10 分配地址

&#160; &#160; &#160; &#160; 选择分配地址:

![23](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/23.jpg)

#### 2.11 生成HDL

&#160; &#160; &#160; &#160; 选择生成HDL文件:

![24](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/24.jpg)

&#160; &#160; &#160; &#160; 保存Qsys文件，文件名为：soc_system.qsys 。

&#160; &#160; &#160; &#160; 保存完之后生成HDL:

![25](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/25.jpg)

#### 2.12 设计顶层文件

&#160; &#160; &#160; &#160; 关掉Platform Designer。在工程中添加刚才的Qsys文件：

![26](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/26.jpg)

&#160; &#160; &#160; &#160; 添加PLL，保存文件名为PLL.V,输入时钟为50MHz，输出时钟1为33.33MHz，输出时钟2为66.66Mhz：

![27](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/27.jpg)

&#160; &#160; &#160; &#160; 新建VerilogHDL，设计顶层文件，代码如下：

```verilog
module DE1_SoC_GHRD(

      input  wire        fpga_clk50m,                      	//      clk.clk
		input  wire [1:0]  fpga_button,                     	//      button_pio.export
		
		output wire        hps_eth1_TX_CLK,	//    				.hps_0_hps_io.hps_io_emac1_inst_TX_CLK
		output wire        hps_eth1_TXD0,   //                .hps_io_emac1_inst_TXD0
		output wire        hps_eth1_TXD1,   //                .hps_io_emac1_inst_TXD1
		output wire        hps_eth1_TXD2,   //                .hps_io_emac1_inst_TXD2
		output wire        hps_eth1_TXD3,   //                .hps_io_emac1_inst_TXD3
		input  wire        hps_eth1_RXD0,   //                .hps_io_emac1_inst_RXD0
		inout  wire        hps_eth1_MDIO,   //                .hps_io_emac1_inst_MDIO
		output wire        hps_eth1_MDC,    //                .hps_io_emac1_inst_MDC
		input  wire        hps_eth1_RX_CTL, //                .hps_io_emac1_inst_RX_CTL
		output wire        hps_eth1_TX_CTL, //                .hps_io_emac1_inst_TX_CTL
		input  wire        hps_eth1_RX_CLK, //                .hps_io_emac1_inst_RX_CLK
		input  wire        hps_eth1_RXD1,   //                .hps_io_emac1_inst_RXD1
		input  wire        hps_eth1_RXD2,   //                .hps_io_emac1_inst_RXD2
		input  wire        hps_eth1_RXD3,   //                .hps_io_emac1_inst_RXD3
		inout  wire        hps_eth1_INT_N,  //                .hps_io_emac1_inst_RXD3
		
		inout  wire        hps_sdio_CMD,     //                .hps_io_sdio_inst_CMD
		inout  wire        hps_sdio_D0,      //                .hps_io_sdio_inst_D0
		inout  wire        hps_sdio_D1,      //                .hps_io_sdio_inst_D1
		output wire        hps_sdio_CLK,     //                .hps_io_sdio_inst_CLK
		inout  wire        hps_sdio_D2,      //                .hps_io_sdio_inst_D2
		inout  wire        hps_sdio_D3,      //                .hps_io_sdio_inst_D3
		
		inout  wire        hps_usb1_CONV_N,  //                .hps_io_usb1_inst_D0		
		inout  wire        hps_usb1_D0,      //                .hps_io_usb1_inst_D0
		inout  wire        hps_usb1_D1,      //                .hps_io_usb1_inst_D1
		inout  wire        hps_usb1_D2,      //                .hps_io_usb1_inst_D2
		inout  wire        hps_usb1_D3,      //                .hps_io_usb1_inst_D3
		inout  wire        hps_usb1_D4,      //                .hps_io_usb1_inst_D4
		inout  wire        hps_usb1_D5,      //                .hps_io_usb1_inst_D5
		inout  wire        hps_usb1_D6,      //                .hps_io_usb1_inst_D6
		inout  wire        hps_usb1_D7,      //                .hps_io_usb1_inst_D7
		input  wire        hps_usb1_CLK,     //                .hps_io_usb1_inst_CLK
		output wire        hps_usb1_STP,     //                .hps_io_usb1_inst_STP
		input  wire        hps_usb1_DIR,     //                .hps_io_usb1_inst_DIR
		input  wire        hps_usb1_NXT,     //                .hps_io_usb1_inst_NXT
		
		output wire        hps_spim0_CLK,    //                .hps_io_spim0_inst_CLK
		output wire        hps_spim0_MOSI,   //                .hps_io_spim0_inst_MOSI
		input  wire        hps_spim0_MISO,   //                .hps_io_spim0_inst_MISO
		output wire        hps_spim0_SS0,    //                .hps_io_spim0_inst_SS0
		
		output wire        hps_spim1_CLK,    //                .hps_io_spim1_inst_CLK
		output wire        hps_spim1_MOSI,   //                .hps_io_spim1_inst_MOSI
		input  wire        hps_spim1_MISO,   //                .hps_io_spim1_inst_MISO
		output wire        hps_spim1_SS0,    //                .hps_io_spim1_inst_SS0
		
		input  wire        hps_uart0_RX,     //                .hps_io_uart0_inst_RX
		output wire        hps_uart0_TX,     //                .hps_io_uart0_inst_TX
		
		inout  wire        hps_i2c0_SDA,     //                .hps_io_i2c0_inst_SDA
		inout  wire        hps_i2c0_SCL,     //                .hps_io_i2c0_inst_SCL
		
		inout  wire        hps_i2c1_SDA,     //                .hps_io_i2c1_inst_SDA
		inout  wire        hps_i2c1_SCL,     //                .hps_io_i2c1_inst_SCL
		
		
		inout  wire        hps_gpio_GPIO00,  //                .hps_io_gpio_inst_GPIO00

		inout  wire        hps_gpio_GPIO37,  //                .hps_io_gpio_inst_GPIO37
		inout  wire        hps_gpio_GPIO44,  //                .hps_io_gpio_inst_GPIO44
		inout  wire        hps_gpio_GPIO48,  //                .hps_io_gpio_inst_GPIO48
		inout  wire        hps_gpio_GPIO61,  //                .hps_io_gpio_inst_GPIO61
		inout  wire        hps_gpio_GPIO62,  //                .hps_io_gpio_inst_GPIO62
		
		inout  wire        hps_key, 
		inout  wire        hps_led,                     

		output wire [9:0]  fpga_led,                        //         led_pio.export
		
		output wire [14:0] memory_mem_a,                          //          memory.mem_a
		output wire [2:0]  memory_mem_ba,                         //                .mem_ba
		output wire        memory_mem_ck,                         //                .mem_ck
		output wire        memory_mem_ck_n,                       //                .mem_ck_n
		output wire        memory_mem_cke,                        //                .mem_cke
		output wire        memory_mem_cs_n,                       //                .mem_cs_n
		output wire        memory_mem_ras_n,                      //                .mem_ras_n
		output wire        memory_mem_cas_n,                      //                .mem_cas_n
		output wire        memory_mem_we_n,                       //                .mem_we_n
		output wire        memory_mem_reset_n,                    //                .mem_reset_n
		inout  wire [31:0] memory_mem_dq,                         //                .mem_dq
		inout  wire [3:0]  memory_mem_dqs,                        //                .mem_dqs
		inout  wire [3:0]  memory_mem_dqs_n,                      //                .mem_dqs_n
		output wire        memory_mem_odt,                        //                .mem_odt
		output wire [3:0]  memory_mem_dm,                         //                .mem_dm
		input  wire        memory_oct_rzqin,                      //                .oct_rzqin
		
		input  wire        fpga_spi_0_MISO,                            //           spi_0.MISO
		output wire        fpga_spi_0_MOSI,                            //                .MOSI
		output wire        fpga_spi_0_SCLK,                            //                .SCLK
		output wire        fpga_spi_0_SS_n,                            //                .SS_n

		input  wire        fpga_uart_0_rxd,                            //          uart_0.rxd
		output wire        fpga_uart_0_txd,                            //                .txd
	
		      ///////// TFT /////////
      output      [15:0] tft_rgb,
      output             tft_blank_n,
      output             tft_clk,
      output             tft_hsync,
      output             tft_vsync


);

	wire hps_0_h2f_reset_n;
	
	wire               clk_33m;
	wire               clk_66m;
	wire [7:0]         vid_r,vid_g,vid_b;
	wire               vid_v_sync ;
	wire               vid_h_sync ;
	wire               vid_datavalid;
	
	
	PLL_0002 pll_inst (
		.refclk   (fpga_clk50m),   //  refclk.clk
		.rst      (1'b0),      //   reset.reset
		.outclk_0 (clk_33m), // outclk0.clk
		.outclk_1 (clk_66m), // outclk1.clk
		.locked   ()          // (terminated)
	);

	
	assign   tft_blank_n          =     vid_datavalid;	
	assign   tft_clk              =     clk_33m;
	assign   tft_rgb   				=     {vid_b[7:3],vid_g[7:2],vid_r[7:3]};
	assign   tft_vsync            =     vid_v_sync;
	assign   tft_hsync            =     vid_h_sync;
	
	

    soc_system u0 (
        .clk_clk                               (fpga_clk50m),                               //             clk.clk
        .reset_reset_n                         (hps_0_h2f_reset_n),                         //           reset.reset_n
		  
		  .memory_mem_a                          (memory_mem_a),                          //          memory.mem_a
		  .memory_mem_ba                         (memory_mem_ba),                         //                .mem_ba
		  .memory_mem_ck                         (memory_mem_ck),                         //                .mem_ck
		  .memory_mem_ck_n                       (memory_mem_ck_n),                       //                .mem_ck_n
		  .memory_mem_cke                        (memory_mem_cke),                        //                .mem_cke
		  .memory_mem_cs_n                       (memory_mem_cs_n),                       //                .mem_cs_n
		  .memory_mem_ras_n                      (memory_mem_ras_n),                      //                .mem_ras_n
		  .memory_mem_cas_n                      (memory_mem_cas_n),                      //                .mem_cas_n
		  .memory_mem_we_n                       (memory_mem_we_n),                       //                .mem_we_n
		  .memory_mem_reset_n                    (memory_mem_reset_n),                    //                .mem_reset_n
		  .memory_mem_dq                         (memory_mem_dq),                         //                .mem_dq
		  .memory_mem_dqs                        (memory_mem_dqs),                        //                .mem_dqs
		  .memory_mem_dqs_n                      (memory_mem_dqs_n),                      //                .mem_dqs_n
		  .memory_mem_odt                        (memory_mem_odt),                        //                .mem_odt
		  .memory_mem_dm                         (memory_mem_dm),                         //                .mem_dm
		  .memory_oct_rzqin                      (memory_oct_rzqin),                      //                .oct_rzqin
		  
        .hps_0_hps_io_hps_io_emac1_inst_TX_CLK (hps_eth1_TX_CLK), //    hps_0_hps_io.hps_io_emac1_inst_TX_CLK
        .hps_0_hps_io_hps_io_emac1_inst_TXD0   (hps_eth1_TXD0),   //                .hps_io_emac1_inst_TXD0
        .hps_0_hps_io_hps_io_emac1_inst_TXD1   (hps_eth1_TXD1),   //                .hps_io_emac1_inst_TXD1
        .hps_0_hps_io_hps_io_emac1_inst_TXD2   (hps_eth1_TXD2),   //                .hps_io_emac1_inst_TXD2
        .hps_0_hps_io_hps_io_emac1_inst_TXD3   (hps_eth1_TXD3),   //                .hps_io_emac1_inst_TXD3
        .hps_0_hps_io_hps_io_emac1_inst_RXD0   (hps_eth1_RXD0),   //                .hps_io_emac1_inst_RXD0
        .hps_0_hps_io_hps_io_emac1_inst_MDIO   (hps_eth1_MDIO),   //                .hps_io_emac1_inst_MDIO
        .hps_0_hps_io_hps_io_emac1_inst_MDC    (hps_eth1_MDC),    //                .hps_io_emac1_inst_MDC
        .hps_0_hps_io_hps_io_emac1_inst_RX_CTL (hps_eth1_RX_CTL), //                .hps_io_emac1_inst_RX_CTL
        .hps_0_hps_io_hps_io_emac1_inst_TX_CTL (hps_eth1_TX_CTL), //                .hps_io_emac1_inst_TX_CTL
        .hps_0_hps_io_hps_io_emac1_inst_RX_CLK (hps_eth1_RX_CLK), //                .hps_io_emac1_inst_RX_CLK
        .hps_0_hps_io_hps_io_emac1_inst_RXD1   (hps_eth1_RXD1),   //                .hps_io_emac1_inst_RXD1
        .hps_0_hps_io_hps_io_emac1_inst_RXD2   (hps_eth1_RXD2),   //                .hps_io_emac1_inst_RXD2
        .hps_0_hps_io_hps_io_emac1_inst_RXD3   (hps_eth1_RXD3),   //                .hps_io_emac1_inst_RXD3
        .hps_0_hps_io_hps_io_sdio_inst_CMD     (hps_sdio_CMD),     //                .hps_io_sdio_inst_CMD
        .hps_0_hps_io_hps_io_sdio_inst_D0      (hps_sdio_D0),      //                .hps_io_sdio_inst_D0
        .hps_0_hps_io_hps_io_sdio_inst_D1      (hps_sdio_D1),      //                .hps_io_sdio_inst_D1
        .hps_0_hps_io_hps_io_sdio_inst_CLK     (hps_sdio_CLK),     //                .hps_io_sdio_inst_CLK
        .hps_0_hps_io_hps_io_sdio_inst_D2      (hps_sdio_D2),      //                .hps_io_sdio_inst_D2
        .hps_0_hps_io_hps_io_sdio_inst_D3      (hps_sdio_D3),      //                .hps_io_sdio_inst_D3
        .hps_0_hps_io_hps_io_usb1_inst_D0      (hps_usb1_D0),      //                .hps_io_usb1_inst_D0
        .hps_0_hps_io_hps_io_usb1_inst_D1      (hps_usb1_D1),      //                .hps_io_usb1_inst_D1
        .hps_0_hps_io_hps_io_usb1_inst_D2      (hps_usb1_D2),      //                .hps_io_usb1_inst_D2
        .hps_0_hps_io_hps_io_usb1_inst_D3      (hps_usb1_D3),      //                .hps_io_usb1_inst_D3
        .hps_0_hps_io_hps_io_usb1_inst_D4      (hps_usb1_D4),      //                .hps_io_usb1_inst_D4
        .hps_0_hps_io_hps_io_usb1_inst_D5      (hps_usb1_D5),      //                .hps_io_usb1_inst_D5
        .hps_0_hps_io_hps_io_usb1_inst_D6      (hps_usb1_D6),      //                .hps_io_usb1_inst_D6
        .hps_0_hps_io_hps_io_usb1_inst_D7      (hps_usb1_D7),      //                .hps_io_usb1_inst_D7
        .hps_0_hps_io_hps_io_usb1_inst_CLK     (hps_usb1_CLK),     //                .hps_io_usb1_inst_CLK
        .hps_0_hps_io_hps_io_usb1_inst_STP     (hps_usb1_STP),     //                .hps_io_usb1_inst_STP
        .hps_0_hps_io_hps_io_usb1_inst_DIR     (hps_usb1_DIR),     //                .hps_io_usb1_inst_DIR
        .hps_0_hps_io_hps_io_usb1_inst_NXT     (hps_usb1_NXT),     //                .hps_io_usb1_inst_NXT
        .hps_0_hps_io_hps_io_spim0_inst_CLK    (hps_spim0_CLK),    //                .hps_io_spim0_inst_CLK
        .hps_0_hps_io_hps_io_spim0_inst_MOSI   (hps_spim0_MOSI),   //                .hps_io_spim0_inst_MOSI
        .hps_0_hps_io_hps_io_spim0_inst_MISO   (hps_spim0_MISO),   //                .hps_io_spim0_inst_MISO
        .hps_0_hps_io_hps_io_spim0_inst_SS0    (hps_spim0_SS0),    //                .hps_io_spim0_inst_SS0
        .hps_0_hps_io_hps_io_spim1_inst_CLK    (hps_spim1_CLK),    //                .hps_io_spim1_inst_CLK
        .hps_0_hps_io_hps_io_spim1_inst_MOSI   (hps_spim1_MOSI),   //                .hps_io_spim1_inst_MOSI
        .hps_0_hps_io_hps_io_spim1_inst_MISO   (hps_spim1_MISO),   //                .hps_io_spim1_inst_MISO
        .hps_0_hps_io_hps_io_spim1_inst_SS0    (hps_spim1_SS0),    //                .hps_io_spim1_inst_SS0
        .hps_0_hps_io_hps_io_uart0_inst_RX     (hps_uart0_RX),     //                .hps_io_uart0_inst_RX
        .hps_0_hps_io_hps_io_uart0_inst_TX     (hps_uart0_TX),     //                .hps_io_uart0_inst_TX
        .hps_0_hps_io_hps_io_i2c0_inst_SDA     (hps_i2c0_SDA),     //                .hps_io_i2c0_inst_SDA
        .hps_0_hps_io_hps_io_i2c0_inst_SCL     (hps_i2c0_SCL),     //                .hps_io_i2c0_inst_SCL
        .hps_0_hps_io_hps_io_i2c1_inst_SDA     (hps_i2c1_SDA),     //                .hps_io_i2c1_inst_SDA
        .hps_0_hps_io_hps_io_i2c1_inst_SCL     (hps_i2c1_SCL),     //                .hps_io_i2c1_inst_SCL
        .hps_0_hps_io_hps_io_gpio_inst_GPIO00  (hps_gpio_GPIO00),  //                .hps_io_gpio_inst_GPIO00
        .hps_0_hps_io_hps_io_gpio_inst_GPIO09  (hps_usb1_CONV_N),  //                .hps_io_gpio_inst_GPIO09
        .hps_0_hps_io_hps_io_gpio_inst_GPIO34  (hps_eth1_INT_N),  //                .hps_io_gpio_inst_GPIO34
        .hps_0_hps_io_hps_io_gpio_inst_GPIO37  (hps_gpio_GPIO37),  //                .hps_io_gpio_inst_GPIO37
        .hps_0_hps_io_hps_io_gpio_inst_GPIO44  (hps_gpio_GPIO44),  //                .hps_io_gpio_inst_GPIO44
        .hps_0_hps_io_hps_io_gpio_inst_GPIO48  (hps_gpio_GPIO48),  //                .hps_io_gpio_inst_GPIO48
        .hps_0_hps_io_hps_io_gpio_inst_GPIO53  (hps_led),  //                .hps_io_gpio_inst_GPIO53
        .hps_0_hps_io_hps_io_gpio_inst_GPIO54  (hps_key),  //                .hps_io_gpio_inst_GPIO54
        .hps_0_hps_io_hps_io_gpio_inst_GPIO61  (hps_gpio_GPIO61),  //                .hps_io_gpio_inst_GPIO61
        .hps_0_hps_io_hps_io_gpio_inst_GPIO62  (hps_gpio_GPIO62),  //                .hps_io_gpio_inst_GPIO62
		  
        .hps_0_h2f_reset_reset_n               (hps_0_h2f_reset_n),               // hps_0_h2f_reset.reset_n
		  
        .led_pio_export                        (fpga_led),                            //             led.export
        .button_pio_export                     (fpga_button),                         //          button.export
		  
        .uart_0_rxd                            (fpga_uart_0_rxd),                            //          uart_0.rxd
        .uart_0_txd                            (fpga_uart_0_txd),                            //                .txd
		  
        .spi_0_MISO                            (fpga_spi_0_MISO),                            //           spi_0.MISO
        .spi_0_MOSI                            (fpga_spi_0_MOSI),                            //                .MOSI
        .spi_0_SCLK                            (fpga_spi_0_SCLK),                            //                .SCLK
        .spi_0_SS_n                            (fpga_spi_0_SS_n),                            //                .SS_n
		  
        .clk_66m_clk                           (clk_66m),                           //         clk_66m.clk
        .video_tft_vid_clk                     (clk_33m),                     //       video_tft.vid_clk
        .video_tft_vid_data                    ({vid_r,vid_g,vid_b}),                    //                .vid_data
        .video_tft_underflow                   (),                   //                .underflow
        .video_tft_vid_datavalid               (vid_datavalid),               //                .vid_datavalid
        .video_tft_vid_v_sync                  (vid_v_sync),                  //                .vid_v_sync
        .video_tft_vid_h_sync                  (vid_h_sync),                  //                .vid_h_sync
        .video_tft_vid_f                       (),                       //                .vid_f
        .video_tft_vid_h                       (),                       //                .vid_h
        .video_tft_vid_v                       ()                        //                .vid_v
    );
	
	
	
	 endmodule

```
&#160; &#160; &#160; &#160; 保存文件为：DE1_SoC_GHRD.v。

&#160; &#160; &#160; &#160; 运行tcl文件：

![28](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/28.jpg)



#### 2.13 分配引脚

&#160; &#160; &#160; &#160; 设计引脚分配文件：

```tcl

package require ::quartus::project

set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_oct_rzqin -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[0] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[0] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[0] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[1] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[1] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[1] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[2] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[2] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[2] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[3] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[3] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[3] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[4] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[4] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[4] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[5] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[5] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[5] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[6] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[6] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[6] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[7] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[7] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[7] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[8] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[8] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[8] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[9] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[9] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[9] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[10] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[10] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[10] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[11] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[11] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[11] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[12] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[12] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[12] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[13] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[13] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[13] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[14] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[14] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[14] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[15] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[15] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[15] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[16] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[16] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[16] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[17] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[17] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[17] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[18] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[18] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[18] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[19] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[19] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[19] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[20] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[20] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[20] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[21] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[21] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[21] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[22] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[22] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[22] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[23] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[23] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[23] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[24] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[24] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[24] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[25] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[25] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[25] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[26] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[26] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[26] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[27] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[27] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[27] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[28] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[28] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[28] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[29] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[29] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[29] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[30] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[30] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[30] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dq[31] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dq[31] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dq[31] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "DIFFERENTIAL 1.5-V SSTL CLASS I" -to memory_mem_dqs[0] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dqs[0] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dqs[0] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "DIFFERENTIAL 1.5-V SSTL CLASS I" -to memory_mem_dqs[1] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dqs[1] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dqs[1] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "DIFFERENTIAL 1.5-V SSTL CLASS I" -to memory_mem_dqs[2] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dqs[2] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dqs[2] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "DIFFERENTIAL 1.5-V SSTL CLASS I" -to memory_mem_dqs[3] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dqs[3] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dqs[3] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "DIFFERENTIAL 1.5-V SSTL CLASS I" -to memory_mem_dqs_n[0] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dqs_n[0] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dqs_n[0] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "DIFFERENTIAL 1.5-V SSTL CLASS I" -to memory_mem_dqs_n[1] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dqs_n[1] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dqs_n[1] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "DIFFERENTIAL 1.5-V SSTL CLASS I" -to memory_mem_dqs_n[2] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dqs_n[2] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dqs_n[2] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "DIFFERENTIAL 1.5-V SSTL CLASS I" -to memory_mem_dqs_n[3] -tag __hps_sdram_p0
set_instance_assignment -name INPUT_TERMINATION "PARALLEL 50 OHM WITH CALIBRATION" -to memory_mem_dqs_n[3] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dqs_n[3] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "DIFFERENTIAL 1.5-V SSTL CLASS I" -to memory_mem_ck -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to memory_mem_ck -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "DIFFERENTIAL 1.5-V SSTL CLASS I" -to memory_mem_ck_n -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to memory_mem_ck_n -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_a[0] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_a[0] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_a[10] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_a[10] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_a[11] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_a[11] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_a[12] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_a[12] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_a[13] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_a[13] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_a[14] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_a[14] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_a[1] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_a[1] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_a[2] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_a[2] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_a[3] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_a[3] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_a[4] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_a[4] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_a[5] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_a[5] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_a[6] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_a[6] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_a[7] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_a[7] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_a[8] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_a[8] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_a[9] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_a[9] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_ba[0] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_ba[0] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_ba[1] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_ba[1] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_ba[2] -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_ba[2] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_cas_n -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_cas_n -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_cke -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_cke -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_cs_n -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_cs_n -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_odt -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_odt -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_ras_n -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_ras_n -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_we_n -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_we_n -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_reset_n -tag __hps_sdram_p0
set_instance_assignment -name CURRENT_STRENGTH_NEW "MAXIMUM CURRENT" -to memory_mem_reset_n -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dm[0] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dm[0] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dm[1] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dm[1] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dm[2] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dm[2] -tag __hps_sdram_p0
set_instance_assignment -name IO_STANDARD "SSTL-15 CLASS I" -to memory_mem_dm[3] -tag __hps_sdram_p0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITH CALIBRATION" -to memory_mem_dm[3] -tag __hps_sdram_p0
set_location_assignment PIN_V16 -to fpga_led[0]
set_location_assignment PIN_W16 -to fpga_led[1]
set_location_assignment PIN_V17 -to fpga_led[2]
set_location_assignment PIN_V18 -to fpga_led[3]
set_location_assignment PIN_W17 -to fpga_led[4]
set_location_assignment PIN_W19 -to fpga_led[5]
set_location_assignment PIN_Y19 -to fpga_led[6]
set_location_assignment PIN_W20 -to fpga_led[7]
set_location_assignment PIN_W21 -to fpga_led[8]
set_location_assignment PIN_Y21 -to fpga_led[9]
set_location_assignment PIN_AF14 -to fpga_clk50m
set_location_assignment PIN_AA14 -to fpga_button[0]
set_location_assignment PIN_AA15 -to fpga_button[1]
set_location_assignment PIN_AC18 -to fpga_spi_0_MISO
set_location_assignment PIN_Y17 -to fpga_spi_0_MOSI
set_location_assignment PIN_AD17 -to fpga_spi_0_SCLK
set_location_assignment PIN_Y18 -to fpga_spi_0_SS_n
set_location_assignment PIN_AG18 -to fpga_uart_0_rxd
set_location_assignment PIN_AF18 -to fpga_uart_0_txd
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_button[0]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_button[1]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_clk50m
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_led[0]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_led[1]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_led[2]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_led[3]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_led[4]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_led[5]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_led[6]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_usb1_STP
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_usb1_NXT
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_usb1_DIR
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_usb1_D7
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_usb1_D6
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_usb1_D5
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_usb1_D4
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_usb1_D3
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_usb1_D2
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_usb1_D1
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_usb1_D0
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_usb1_CONV_N
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_usb1_CLK
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_uart0_TX
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_uart0_RX
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_spim1_SS0
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_spim1_MOSI
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_spim1_MISO
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_spim1_CLK
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_spim0_SS0
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_spim0_MOSI
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_spim0_MISO
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_spim0_CLK
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_sdio_D3
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_sdio_D2
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_sdio_D1
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_sdio_D0
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_sdio_CMD
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_sdio_CLK
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_led
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_key
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_i2c1_SDA
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_i2c1_SCL
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_i2c0_SDA
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_i2c0_SCL
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_gpio_GPIO62
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_gpio_GPIO61
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_gpio_GPIO48
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_gpio_GPIO44
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_gpio_GPIO37
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_gpio_GPIO00
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_eth1_TX_CTL
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_eth1_TX_CLK
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_eth1_TXD3
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_eth1_TXD2
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_eth1_TXD1
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_eth1_TXD0
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_eth1_RX_CTL
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_eth1_RXD3
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_eth1_RX_CLK
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_eth1_RXD2
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_eth1_RXD1
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_eth1_RXD0
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_eth1_MDIO
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_eth1_MDC
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to hps_eth1_INT_N
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_uart_0_txd
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_uart_0_rxd
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_spi_0_SS_n
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_spi_0_SCLK
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_spi_0_MOSI
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_spi_0_MISO
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_led[9]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_led[8]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to fpga_led[7]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_blank_n
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_clk
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_hsync
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[15]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[14]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[13]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[12]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[11]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[10]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[9]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[8]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[7]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[6]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[5]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[4]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[3]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[2]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[1]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_rgb[0]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to tft_vsync
set_location_assignment PIN_AK19 -to tft_blank_n
set_location_assignment PIN_AH17 -to tft_clk
set_location_assignment PIN_AJ17 -to tft_hsync
set_location_assignment PIN_AJ16 -to tft_vsync
set_location_assignment PIN_AF16 -to tft_rgb[0]
set_location_assignment PIN_AG17 -to tft_rgb[1]
set_location_assignment PIN_AG16 -to tft_rgb[2]
set_location_assignment PIN_AE16 -to tft_rgb[3]
set_location_assignment PIN_AH18 -to tft_rgb[4]
set_location_assignment PIN_AH19 -to tft_rgb[5]
set_location_assignment PIN_AJ20 -to tft_rgb[6]
set_location_assignment PIN_AE17 -to tft_rgb[7]
set_location_assignment PIN_AC20 -to tft_rgb[8]
set_location_assignment PIN_AA18 -to tft_rgb[9]
set_location_assignment PIN_AA19 -to tft_rgb[10]
set_location_assignment PIN_AE19 -to tft_rgb[11]
set_location_assignment PIN_AD19 -to tft_rgb[12]
set_location_assignment PIN_AD20 -to tft_rgb[13]
set_location_assignment PIN_AH20 -to tft_rgb[14]
set_location_assignment PIN_AK21 -to tft_rgb[15]


```
&#160; &#160; &#160; &#160; 保存到工程文件夹内并运行，完成引脚分配。


#### 2.14 生成rbf文件

&#160; &#160; &#160; &#160; 分析综合，生成sof文件。打开“Convert Programmering Files...”：

![29](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/29.jpg)

&#160; &#160; &#160; &#160; 将文件类型改为rbf，文件名改为“soc_system.rbf”：

![30](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/30.jpg)

&#160; &#160; &#160; &#160; 选中“SOF data”，点击“add files”添加刚才编译生成的sof文件：

![31](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/31.jpg)

&#160; &#160; &#160; &#160; 点击“generate”，生成rbf文件以便之后使用：

![32](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/32.jpg)

------------------

### 3.制作Preloader Image

#### 3.1 打开SoC EDS工具

&#160; &#160; &#160; &#160; 使用管理员身份打开SoC EDS工具：

![33](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/33.jpg)

#### 3.2 制作bsp文件

&#160; &#160; &#160; &#160; 在SoC EDS中输入以下指令打开bsp-editor：

```shell
bsp-editor
```


![34](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/34.jpg)

&#160; &#160; &#160; &#160; 点击“File”，选择“New HPS BSP...”

![35](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/35.jpg)

&#160; &#160; &#160; &#160; 在“Preloader setting directory”中选择工程中的路径“..\DE1_SoC_GHRDhps_isw_handoff\soc_system_hps_0”。选"OK":

![36](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/36.jpg)


&#160; &#160; &#160; &#160; 点击“generate”，生成bsp文件，关掉bsp-editor。

#### 3.3 编译preloader和uboot

&#160; &#160; &#160; &#160; 去Quartus Prime安装路径下的“
...\intelFPGA\18.1\embedded\examples\hardware\cv_soc_devkit_ghrd”路径中复制Makefile文件到工程路径下。

&#160; &#160; &#160; &#160; 在SoC EDS中输入以下路径打开工程目录：

```shell
cd E:/DE1-SoC/FPGA_HPS/DE1_SoC_GHRD  //修改为自己的工程路径
```

&#160; &#160; &#160; &#160; 输入以下指令编译Preloader和Uboot：

```shell
make uboot
```
&#160; &#160; &#160; &#160; 如果出现以下错误：

```shell
tar zxf /cygdrive/c/intelFPGA/18.0/embedded/host_tools/altera/preloader/uboot-socfpga.tar.gz
tar: Error opening archive: Failed to open '/cygdrive/c/intelFPGA/18.0/embedded/host_tools/altera/preloader/uboot-socfpga.tar.gz'
make: *** [uboot-socfpga/.untar] Error 1
```

&#160; &#160; &#160; &#160; 可以参考小梅哥的解决方法：[win10下生成preloader报Failed to open gdrive/……/uboot-socfpga.tar.gz](http://www.corecourse.cn/forum.php?mod=viewthread&tid=27809)

&#160; &#160; &#160; &#160; 编译时间较长，可以听听相声。


#### 3.4 更新preloader和uboot

&#160; &#160; &#160; &#160; 将DE1-SoC的Linux启动SD卡插入电脑。（制作启动SD卡方法参见友晶《DE1-SoC培训教材》：1.4.2 制作microSD card Image）确定能被Windows识别分区的盘符，我这里识别为J盘：

![37](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/37.jpg)

&#160; &#160; &#160; &#160; 将路径“..\DE1_SoC_GHRD\software\preloader\uboot-socfpga”下的“u-boot.img”文件复制到“..\DE1_SoC_GHRD\software\preloader”路径下。

&#160; &#160; &#160; &#160; 将路径“..\DE1_SoC_GHRD\software\preloader\uboot-socfpga\spl”下的“u-boot-spl.bin”文件复制到“..\DE1_SoC_GHRD\software\preloader”路径下。

![38](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/38.jpg)

&#160; &#160; &#160; &#160; 在SoC EDS中输入以下路径：
```shell
cd software/preloader
```

&#160; &#160; &#160; &#160; 在SoC EDS中输入以下指令生成preloader.img：
```shell
mkpimage -hv 0 -o preloader.img u-boot-spl.bin
```

&#160; &#160; &#160; &#160; 在SoC EDS中输入以下指令生成更新preloader和uboot，注意最后的“J”要改成自己系统识别的盘符：
```shell
alt-boot-disk-util -p preloader.img -b u-boot.img -a write -d J  
```

&#160; &#160; &#160; &#160; 如果出现“Altera Boot Disk Utility was successful”，则更新成功。如果失败有可能是SoC EDS没有用管理员身份打开。

---------------


### 4.制作设备树
#### 4.1 准备文件
&#160; &#160; &#160; &#160; 在Quartus Prime安装路径下的“...\intelFPGA\18.1\embedded\examples\hardware\cv_soc_devkit_ghrd”路径找到“soc_system_board_info.xml”、“hps_common_board_info.xml”两个文件，复制粘贴到工程路径。

![39](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/39.jpg)

#### 4.2 生成dts文件

&#160; &#160; &#160; &#160; 在SoC EDS中输入以下路径退回上两级：
```shell
cd ../../
```

&#160; &#160; &#160; &#160; 在SoC EDS中输入以下指令生成dts文件：
```shell
make dts
```
#### 4.2 生成dtb文件

&#160; &#160; &#160; &#160; 在SoC EDS中输入以下指令生成dtb文件：
```shell
dtc -I dts -o dtb -fo socfpga.dtb soc_system.dts
```

--------

### 5.使用新的Uboot启动SoC

&#160; &#160; &#160; &#160; 将之前生成的“soc_system.rbf”和“socfpga.dtb”复制粘贴到SD卡中：
![40](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/40.jpg)

&#160; &#160; &#160; &#160; 将DE1-SoC开发板上的UART to USB接口连接至计算机，打开putty软件，具体配置如图：

![41](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/41.jpg)

&#160; &#160; &#160; &#160; 注意**修改端口号**。

&#160; &#160; &#160; &#160; 打开配置，启动DE1-SoC开发板电源，可以看到Uboot更新时间已更新：

![42](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%BB%8E%E9%9B%B6%E5%BC%80%E5%A7%8B%E6%90%AD%E5%BB%BASoC%E7%B3%BB%E7%BB%9F%EF%BC%88%E5%9F%BA%E4%BA%8EDE1-SoC%E5%BC%80%E5%8F%91%E6%9D%BF%EF%BC%89/42.jpg)


--------

&#160; &#160; &#160; &#160; 搭建完成！

&#160; &#160; &#160; &#160; 告辞。

