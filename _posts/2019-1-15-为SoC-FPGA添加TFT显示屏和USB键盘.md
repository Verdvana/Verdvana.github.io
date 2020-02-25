---
layout: post
title:  "为SoC-FPGA添加TFT显示屏和USB键盘"
date:   2019-1-15 13:34:10 +0700
tags:
  - SoC
  - FPGA
---

-------
### 1.前言

&#160; &#160; &#160; &#160; 手里有一块DE1-SoC开发板，按照[友晶](http://www.terasic.com.cn/cgi-bin/page/archive.pl?Language=China&No=466)的[培训手册](http://www.terasic.com.cn/cgi-bin/page/archive.pl?Language=China&CategoryNo=182&No=870&PartNo=4)和[小梅哥](http://www.corecourse.cn/forum.php)的[《基于Cyclone V SoC FPGA的嵌入式系统设计教程》](http://www.corecourse.cn/forum.php?mod=viewthread&tid=27704&highlight=AC501)初步搭建起了SoC-FPGA平台，并且在上面跑了一些简单的例程。

&#160; &#160; &#160; &#160; 后来看小梅哥的AC501开发板有一块5寸的TFT触摸屏，正好DE1-SoC上面连个黑白液晶屏都没有，就想着能不能在DE1-SoC上也添加一块小梅哥的屏幕，然后让Linux终端显示在屏幕上，就省去外接VGA显示器了。

&#160; &#160; &#160; &#160; 如果想完全在DE1-SoC上操作，光有屏幕还不行，还得接一个键盘输入指令。DE1-SoC上有两个USB Host可以接USB设备，不过需要添加USB键盘驱动才可以使用。

&#160; &#160; &#160; &#160; 上个图看一下最终效果：

![1](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/1.jpg)

&#160; &#160; &#160; &#160; 可以看到Linux终端显示在TFT屏幕上，然后用USB键盘输入管理员用户名“root”进入系统。

&#160; &#160; &#160; &#160; 下面就详细说明一下如何把这两个外设挂在SoC-FPGA上，并且为他们在Linux内核中添加驱动。


* 开发环境：
	* Quartus Prime Standard 18.1
	* SoC EDS Command Shell
* 操作系统：
	* Windows 10 Pro 1809
	* Ubuntu 18.04 LTS

-------
### 2.新建SoC-FPGA工程

&#160; &#160; &#160; &#160; 这部分内容可以参考小梅哥的教程，上面给链接了。搭建好的“soc_system.qsys”如下图：

![2](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/2.jpg)

---------------

### 3.添加Frame Reader IP核

&#160; &#160; &#160; &#160; 什么是Frame Reader IP核，为什么要添加，怎么添加，在我的另一篇文章“[在Quartus Prime 17.1以上版本中添加Frame Reader IP核](http://verdvana.top/fpga/verilog%20hdl/ip/soc/2019/01/02/%E6%B7%BB%E5%8A%A0Frame-Reader-IP%E6%A0%B8.html)”中都有，这里也不说了。

### 4.修改SoC-FPGA工程

#### 4.1 修改Qsys


&#160; &#160; &#160; &#160; 首先，修改“soc_system.qsys”。将刚才添加的Frame Reader，和Clocked Video Output ，Clock Bridge 三个IP核添加到Qsys系统中。

&#160; &#160; &#160; &#160; Clock Bridge设置如图：

![5](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/5.jpg)

&#160; &#160; &#160; &#160; Frame Reader设置如图：

![6](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/6.jpg)


&#160; &#160; &#160; &#160; Clocked Video Output设置如图：

![7](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/7.jpg)


&#160; &#160; &#160; &#160; 接线方式如图：
![3](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/3.jpg)

&#160; &#160; &#160; &#160; Frame Reader和Clocked Video Output是什么在之前的文章说过了。而Clock Bridge就是为这两个IP提供时钟的。

&#160; &#160; &#160; &#160; 保存，生成HDL。

&nbsp;

#### 4.2 修改顶层文件

&#160; &#160; &#160; &#160; 刚刚添加的三个IP是TFT屏幕所需要的，这样就多出来驱动屏幕的引脚。刚刚说到的Clock Bridge还需要一个66.6MHz的时钟，所以还需要添加一个PLL。

&#160; &#160; &#160; &#160; PLL的参数如下图：

![4](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/4.jpg)

&#160; &#160; &#160; &#160; 修改完的顶层文件代码为：

```verilog
module DE1_SoC_GHRD(

    input  wire        fpga_clk50m,    //             clk.clk
    input  wire [1:0]  fpga_button,  //      button_pio.export
		
	output wire        hps_eth1_TX_CLK, //    hps_0_hps_io.hps_io_emac1_inst_TX_CLK
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

	output wire [9:0]  fpga_led,              //         led_pio.export
		
	output wire [14:0] memory_mem_a,          //          memory.mem_a
	output wire [2:0]  memory_mem_ba,         //                .mem_ba
	output wire        memory_mem_ck,         //                .mem_ck
	output wire        memory_mem_ck_n,       //                .mem_ck_n
	output wire        memory_mem_cke,        //                .mem_cke
	output wire        memory_mem_cs_n,       //                .mem_cs_n
	output wire        memory_mem_ras_n,      //                .mem_ras_n
	output wire        memory_mem_cas_n,      //                .mem_cas_n
	output wire        memory_mem_we_n,       //                .mem_we_n
	output wire        memory_mem_reset_n,    //                .mem_reset_n
	inout  wire [31:0] memory_mem_dq,         //                .mem_dq
	inout  wire [3:0]  memory_mem_dqs,        //                .mem_dqs
	inout  wire [3:0]  memory_mem_dqs_n,      //                .mem_dqs_n
	output wire        memory_mem_odt,        //                .mem_odt
	output wire [3:0]  memory_mem_dm,         //                .mem_dm
	input  wire        memory_oct_rzqin,      //                .oct_rzqin
		
	input  wire        fpga_spi_0_MISO,       //           spi_0.MISO
	output wire        fpga_spi_0_MOSI,       //                .MOSI
	output wire        fpga_spi_0_SCLK,       //                .SCLK
	output wire        fpga_spi_0_SS_n,       //                .SS_n

	input  wire        fpga_uart_0_rxd,       //          uart_0.rxd
	output wire        fpga_uart_0_txd,       //                .txd
		
		      ///////// TFT /////////
    output      [7:0]  TFT_B,
    output             TFT_BLANK_N,
    output             TFT_CLK,
    output      [7:0]  TFT_G,
    output             TFT_HS,
    output      [7:0]  TFT_R,
    output             TFT_SYNC_N,
    output             TFT_VS,	
	output             TFT_BL


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



	
	assign   TFT_BLANK_N          =     vid_datavalid;
	assign   TFT_SYNC_N           =     1'b0;	
	assign   TFT_CLK              =     clk_33m;
	assign  {TFT_B,TFT_G,TFT_R}   =     {vid_b,vid_g,vid_r};
	assign   TFT_VS               =     vid_v_sync;
	assign   TFT_HS               =     vid_h_sync;
	assign   TFT_BL               =     1'b1;



soc_system u0 (
    .button_pio_export                     (fpga_button),        //      button_pio.export
    .clk_66m_clk                           (clk_66m), 
	.clk_clk                               (fpga_clk50m),        //             clk.clk
    .hps_0_h2f_reset_reset_n               (hps_0_h2f_reset_n),  // hps_0_h2f_reset.reset_n
        
	.led_pio_export                        (fpga_led),           //         led_pio.export
        
	.memory_mem_a                          (memory_mem_a),        //          memory.mem_a
	.memory_mem_ba                         (memory_mem_ba),       //                .mem_ba
	.memory_mem_ck                         (memory_mem_ck),       //                .mem_ck
	.memory_mem_ck_n                       (memory_mem_ck_n),     //                .mem_ck_n
	.memory_mem_cke                        (memory_mem_cke),      //                .mem_cke
	.memory_mem_cs_n                       (memory_mem_cs_n),     //                .mem_cs_n
	.memory_mem_ras_n                      (memory_mem_ras_n),    //                .mem_ras_n
	.memory_mem_cas_n                      (memory_mem_cas_n),    //                .mem_cas_n
	.memory_mem_we_n                       (memory_mem_we_n),     //                .mem_we_n
	.memory_mem_reset_n                    (memory_mem_reset_n),  //                .mem_reset_n
	.memory_mem_dq                         (memory_mem_dq),       //                .mem_dq
	.memory_mem_dqs                        (memory_mem_dqs),      //                .mem_dqs
	.memory_mem_dqs_n                      (memory_mem_dqs_n),    //                .mem_dqs_n
	.memory_mem_odt                        (memory_mem_odt),      //                .mem_odt
	.memory_mem_dm                         (memory_mem_dm),       //                .mem_dm
	.memory_oct_rzqin                      (memory_oct_rzqin),    //                .oct_rzqin
    
	.reset_reset_n                         (hps_0_h2f_reset_n),   //           reset.reset_n
        
	.spi_0_MISO                            (fpga_spi_0_MISO),     //           spi_0.MISO
	.spi_0_MOSI                            (fpga_spi_0_MOSI),     //                .MOSI
	.spi_0_SCLK                            (fpga_spi_0_SCLK),     //                .SCLK
	.spi_0_SS_n                            (fpga_spi_0_SS_n),     //                .SS_n
        
    .uart_0_rxd                            (fpga_uart_0_rxd),     //          uart_0.rxd
	.uart_0_txd                            (fpga_uart_0_txd),     //                .txd
        
    .hps_0_hps_io_hps_io_emac1_inst_TX_CLK (hps_eth1_TX_CLK), // hps_0_hps_io.hps_io_emac1_inst_TX_CLK
	.hps_0_hps_io_hps_io_emac1_inst_TXD0   (hps_eth1_TXD0),   //             .hps_io_emac1_inst_TXD0
	.hps_0_hps_io_hps_io_emac1_inst_TXD1   (hps_eth1_TXD1),   //             .hps_io_emac1_inst_TXD1
	.hps_0_hps_io_hps_io_emac1_inst_TXD2   (hps_eth1_TXD2),   //             .hps_io_emac1_inst_TXD2
	.hps_0_hps_io_hps_io_emac1_inst_TXD3   (hps_eth1_TXD3),   //             .hps_io_emac1_inst_TXD3
	.hps_0_hps_io_hps_io_emac1_inst_RXD0   (hps_eth1_RXD0),   //             .hps_io_emac1_inst_RXD0
	.hps_0_hps_io_hps_io_emac1_inst_MDIO   (hps_eth1_MDIO),   //             .hps_io_emac1_inst_MDIO
	.hps_0_hps_io_hps_io_emac1_inst_MDC    (hps_eth1_MDC),    //             .hps_io_emac1_inst_MDC
	.hps_0_hps_io_hps_io_emac1_inst_RX_CTL (hps_eth1_RX_CTL), //             .hps_io_emac1_inst_RX_CTL
	.hps_0_hps_io_hps_io_emac1_inst_TX_CTL (hps_eth1_TX_CTL), //             .hps_io_emac1_inst_TX_CTL
	.hps_0_hps_io_hps_io_emac1_inst_RX_CLK (hps_eth1_RX_CLK), //             .hps_io_emac1_inst_RX_CLK
	.hps_0_hps_io_hps_io_emac1_inst_RXD1   (hps_eth1_RXD1),   //             .hps_io_emac1_inst_RXD1
	.hps_0_hps_io_hps_io_emac1_inst_RXD2   (hps_eth1_RXD2),   //             .hps_io_emac1_inst_RXD2
	.hps_0_hps_io_hps_io_emac1_inst_RXD3   (hps_eth1_RXD3),   //             .hps_io_emac1_inst_RXD3
	
	.hps_0_hps_io_hps_io_sdio_inst_CMD     (hps_sdio_CMD),     //             .hps_io_sdio_inst_CMD
	.hps_0_hps_io_hps_io_sdio_inst_D0      (hps_sdio_D0),      //             .hps_io_sdio_inst_D0
	.hps_0_hps_io_hps_io_sdio_inst_D1      (hps_sdio_D1),      //             .hps_io_sdio_inst_D1
	.hps_0_hps_io_hps_io_sdio_inst_CLK     (hps_sdio_CLK),     //             .hps_io_sdio_inst_CLK
	.hps_0_hps_io_hps_io_sdio_inst_D2      (hps_sdio_D2),      //             .hps_io_sdio_inst_D2
	.hps_0_hps_io_hps_io_sdio_inst_D3      (hps_sdio_D3),      //             .hps_io_sdio_inst_D3
		
	.hps_0_hps_io_hps_io_usb1_inst_D0      (hps_usb1_D0),      //             .hps_io_usb1_inst_D0
	.hps_0_hps_io_hps_io_usb1_inst_D1      (hps_usb1_D1),      //             .hps_io_usb1_inst_D1
	.hps_0_hps_io_hps_io_usb1_inst_D2      (hps_usb1_D2),      //             .hps_io_usb1_inst_D2
	.hps_0_hps_io_hps_io_usb1_inst_D3      (hps_usb1_D3),      //             .hps_io_usb1_inst_D3
	.hps_0_hps_io_hps_io_usb1_inst_D4      (hps_usb1_D4),      //             .hps_io_usb1_inst_D4
	.hps_0_hps_io_hps_io_usb1_inst_D5      (hps_usb1_D5),      //             .hps_io_usb1_inst_D5
	.hps_0_hps_io_hps_io_usb1_inst_D6      (hps_usb1_D6),      //             .hps_io_usb1_inst_D6
	.hps_0_hps_io_hps_io_usb1_inst_D7      (hps_usb1_D7),      //             .hps_io_usb1_inst_D7
	.hps_0_hps_io_hps_io_usb1_inst_CLK     (hps_usb1_CLK),     //             .hps_io_usb1_inst_CLK
	.hps_0_hps_io_hps_io_usb1_inst_STP     (hps_usb1_STP),     //             .hps_io_usb1_inst_STP
	.hps_0_hps_io_hps_io_usb1_inst_DIR     (hps_usb1_DIR),     //             .hps_io_usb1_inst_DIR
	.hps_0_hps_io_hps_io_usb1_inst_NXT     (hps_usb1_NXT),     //             .hps_io_usb1_inst_NXT
		
	.hps_0_hps_io_hps_io_spim0_inst_CLK    (hps_spim0_CLK),    //             .hps_io_spim0_inst_CLK
	.hps_0_hps_io_hps_io_spim0_inst_MOSI   (hps_spim0_MOSI),   //             .hps_io_spim0_inst_MOSI
	.hps_0_hps_io_hps_io_spim0_inst_MISO   (hps_spim0_MISO),   //             .hps_io_spim0_inst_MISO
	.hps_0_hps_io_hps_io_spim0_inst_SS0    (hps_spim0_SS0),    //             .hps_io_spim0_inst_SS0
		
	.hps_0_hps_io_hps_io_spim1_inst_CLK    (hps_spim1_CLK),    //             .hps_io_spim1_inst_CLK
	.hps_0_hps_io_hps_io_spim1_inst_MOSI   (hps_spim1_MOSI),   //             .hps_io_spim1_inst_MOSI
	.hps_0_hps_io_hps_io_spim1_inst_MISO   (hps_spim1_MISO),   //             .hps_io_spim1_inst_MISO
	.hps_0_hps_io_hps_io_spim1_inst_SS0    (hps_spim1_SS0),    //             .hps_io_spim1_inst_SS0
		
	.hps_0_hps_io_hps_io_uart0_inst_RX     (hps_uart0_RX),     //             .hps_io_uart0_inst_RX
	.hps_0_hps_io_hps_io_uart0_inst_TX     (hps_uart0_TX),     //             .hps_io_uart0_inst_TX
		
	.hps_0_hps_io_hps_io_i2c0_inst_SDA     (hps_i2c0_SDA),     //             .hps_io_i2c0_inst_SDA
	.hps_0_hps_io_hps_io_i2c0_inst_SCL     (hps_i2c0_SCL),     //             .hps_io_i2c0_inst_SCL
		
	.hps_0_hps_io_hps_io_i2c1_inst_SDA     (hps_i2c1_SDA),     //             .hps_io_i2c1_inst_SDA
	.hps_0_hps_io_hps_io_i2c1_inst_SCL     (hps_i2c1_SCL),     //             .hps_io_i2c1_inst_SCL
		
        
	.hps_0_hps_io_hps_io_gpio_inst_GPIO00  (hps_gpio_GPIO00),  //             .hps_io_gpio_inst_GPIO00         
    .hps_0_hps_io_hps_io_gpio_inst_GPIO09  (hps_usb1_CONV_N),  //             .hps_io_gpio_inst_GPIO09

      
	.hps_0_hps_io_hps_io_gpio_inst_GPIO34  (hps_eth1_INT_N),   //             .hps_io_gpio_inst_GPIO34
	.hps_0_hps_io_hps_io_gpio_inst_GPIO37  (hps_gpio_GPIO37),  //             .hps_io_gpio_inst_GPIO37
	.hps_0_hps_io_hps_io_gpio_inst_GPIO44  (hps_gpio_GPIO44),  //             .hps_io_gpio_inst_GPIO44
	.hps_0_hps_io_hps_io_gpio_inst_GPIO48  (hps_gpio_GPIO48),  //             .hps_io_gpio_inst_GPIO48
        
	.hps_0_hps_io_hps_io_gpio_inst_GPIO53  (hps_led),          //             .hps_io_gpio_inst_GPIO53
    .hps_0_hps_io_hps_io_gpio_inst_GPIO54  (hps_key),          //             .hps_io_gpio_inst_GPIO54
        
	.hps_0_hps_io_hps_io_gpio_inst_GPIO61  (hps_gpio_GPIO61),  //             .hps_io_gpio_inst_GPIO61
	.hps_0_hps_io_hps_io_gpio_inst_GPIO62  (hps_gpio_GPIO62),  //             .hps_io_gpio_inst_GPIO62

		  
	.video_tft_vid_clk                    (clk_33m),                  //  alt_vip_itc.vid_clk
    .video_tft_vid_data                  ({vid_r,vid_g,vid_b}),       //             .vid_data
    .video_tft_underflow                 (),                          //             .underflow
    .video_tft_vid_datavalid             (vid_datavalid),             //             .vid_datavalid
    .video_tft_vid_v_sync                (vid_v_sync),                //             .vid_v_sync
    .video_tft_vid_h_sync                (vid_h_sync),                //             .vid_h_sync
    .video_tft_vid_f                     (),                          //             .vid_f
    .video_tft_vid_h                     (),                          //             .vid_h
    .video_tft_vid_v                     ()
    );

	 endmodule
```

&#160; &#160; &#160; &#160; 分析综合、分配引脚。最后的RTL图是这样的：

![8](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/8.jpg)

&#160; &#160; &#160; &#160; 写过VGA显示器驱动的话就能看出这块TFT液晶屏的引脚跟VGA几乎一样，确实连时序都是一样的，所以只要是VGA时序的屏幕理论上都能用本文的方式驱动。

&#160; &#160; &#160; &#160; 这样SoC-FPGA工程就修改好了，最后将“DE1_SoC_GHRD.sof”文件生成“soc_system.rbf”文件，以备之后使用。

------

### 5.制作Preloader Image

&#160; &#160; &#160; &#160; 这部分内容小梅哥的教程里也有，这里查缺补漏快速过一下。

&nbsp;


#### 5.1 打开SoC EDS工具

&#160; &#160; &#160; &#160; 这里注意要用管理员模式打开，不然后面会报错。
![9](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/9.jpg)

&nbsp;


#### 5.2 生成bsp文件

&#160; &#160; &#160; &#160; 在SoC EDS中输入：

```shell
bsp-editor
```

&#160; &#160; &#160; &#160; 弹出bsp-editor主界面。依次点击 File-->New HPS BSP创建bsp文件，如图：

![10](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/10.jpg)

&#160; &#160; &#160; &#160; 设定Preloader Setting Directory的路径为：“..\ [工程名] \hps_isw_handoff\soc_system_hps_0”。比如我的是“E:\DE1-SoC\FPGA_HPS\DE1_SoC_GHRD\hps_isw_handoff\soc_system_hps_0”，点击“OK”完成设置。

![11](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/11.jpg)


&#160; &#160; &#160; &#160; 然后点击“Generate”生成preloader的原始档以及Makfile。生成之后点击“Exit”退出。

![12](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/12.jpg)


&nbsp;


#### 5.3 编译preloader和uboot

&#160; &#160; &#160; &#160; 在SoC EDS Command Shell中使用cd命令进入工程路径：

```shell
cd E:/DE1-SoC/FPGA_HPS/DE1_SoC_GHRD  //改成你自己的路径，注意斜杠方向
```

&#160; &#160; &#160; &#160; 直接编译会报错，所以提前给他解决了。这里使用小梅哥提供的方法：“[win10下生成preloader报无法打开gdrive / ...... / uboot-socfpga.tar.gz](http://www.corecourse.cn/forum.php?mod=viewthread&tid=27809&tdsourcetag=s_pctim_aiomsg)”。


&#160; &#160; &#160; &#160; 解决掉之后，在SoC EDS Command Shell中输入如下指令进行编译：

```shell
make uboot
```

&#160; &#160; &#160; &#160; 过程比较长，可以捉一会儿猫打发时间。

&#160; &#160; &#160; &#160; 编译完成之后在“[工程名]\software\preloader\uboot-socfpga”路径下找到“u-boot.img”文件；在“[工程名]\software\preloader\uboot-socfpga\spl”路径下找到“u-boot-spi.bin”文件。将这俩文件拷贝到“[工程名]\software\preloader”路径下。然后在SoC EDS Command Shell中使用如下命令进入此路径：

```shell
cd software/preloader
```
&#160; &#160; &#160; &#160; 使用mkpimage工具生成preloader.img，命令如下：

```shell
mkpimage -hv 0 -o preloader.img u-boot-spl.bin
```
&#160; &#160; &#160; &#160; 此时你的preloader目录下就会出现preloader.img文件。

&nbsp;

#### 5.4 更新preloader和uboot

&#160; &#160; &#160; &#160; 将DE1-SoC的启动SD卡插入PC。确定一下那个能打开的分区的盘符，我这里是“J”。输入以下命令完成更新：

```shell
alt-boot-disk-util -p preloader.img -b u-boot.img -a write -d J //最后的字母既是盘符，根据个人情况修改
```
&#160; &#160; &#160; &#160; 如果之前不用管理员身份打开SoC EDS的话这一步将不会提示“Altera Boot Disk Utility was successful”。

-----

### 6.制作设备树
#### 6.1 准备所需文件

&#160; &#160; &#160; &#160; 去“..\intelFPGA\18.1\embedded\examples\hardware\cv_soc_devkit_ghrd”路径下将“hps_common_board_info.xml”和“soc_system_board_info.xml”俩文件复制到工程路径下。在SoC EDS Command Shell输入如下指令回到工程路径：

```shell
cd ../../
```

&nbsp;

#### 6.2 生成dts文件

&#160; &#160; &#160; &#160; 接着输入如下指令生成dts文件：

```shell
make dts
```

&nbsp;

#### 6.3 生成dtb文件

&#160; &#160; &#160; &#160; 输入如下指令生成dts文件：

```shell
dtc -I dts -o dtb -fo socfpga.dtb soc_system.dts
```

&#160; &#160; &#160; &#160; 这样就在工程路径下生成了“socfpga.dtb”文件。

---------

### 7.运行修改后的工程

&#160; &#160; &#160; &#160; 将刚刚生成的“soc_system.rbf”和“socfpga.dtb”两个文件复制到SD卡里替换掉原来的文件。然后将SD卡弹出，插入DE1-SoC卡槽。插上小梅哥的5寸TFT液晶屏，按下开发板电源键，可以看到Linux终端显示到了液晶屏上。

![13](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/13.jpg)

&#160; &#160; &#160; &#160; 但是此时插上USB键盘并不会输入内容。这就需要修改Linux内核。


-----

### 8.修改Linux内核

#### 8.1 准备工作

&#160; &#160; &#160; &#160; 启动Ubuntu系统。

&#160; &#160; &#160; &#160; 下载Linux系统源码：[https://github.com/altera-opensource/linux-socfpga](https://github.com/altera-opensource/linux-socfpga)。

&#160; &#160; &#160; &#160; 我这里选的和小梅哥一样的版本：socfpga-4.5。把下载好的源码解压到一个地方。我选择了主目录下的tools文件夹内，并修改文件名为“linux-socfpga”。

&#160; &#160; &#160; &#160; 下载编译器：[https://github.com/Verdvana/gcc-linaro-arm-linux-gnueabihf-4.8-2014.04_linux.tar](https://github.com/Verdvana/gcc-linaro-arm-linux-gnueabihf-4.8-2014.04_linux.tar)。

&#160; &#160; &#160; &#160; 同样我选择了和小梅哥一样的版本“gcc-linaro-arm-linux-gnueabihf-4.8-2014.04_linux.tar”。 把下载好的编译器解压到Linux源码文件夹旁边，文件名不用改。

![14](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/14.png)

&nbsp;

#### 8.2 设置交叉编译环境

&#160; &#160; &#160; &#160; 快捷键“alt”+“ctrl”“t”打开终端。进入“tools”目录，命令如下：

```shell
cd ~/tools
```

&#160; &#160; &#160; &#160; 打开用户初始化文件：

```shell
gedit ~/.profile
```
&#160; &#160; &#160; &#160; 文件末尾添加如下路径：

```t
PATH="$HOME/bin:$HOME/.local/bin:$PATH"
export PATH=/home/verdvana/tools/gcc-linaro-arm-linux-gnueabihf-4.8-2014.04_linux/bin:$PATH       //用户名改成自己的
```
![15](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/15.png)

&#160; &#160; &#160; &#160; 保存退出。

&#160; &#160; &#160; &#160; 执行如下命令让交叉工具生效：

```shell
source /home/verdvana/.profile     //用户名改成自己的
```

&nbsp;

#### 8.3 配置和编译内核

&#160; &#160; &#160; &#160; 输入以下命令进入Linux内核源码目录：

```shell
cd /home/verdvana/tools/linux-socfpga    //用户名改成自己的
```
&#160; &#160; &#160; &#160; 输入以下命令安装相关库：

```shell
sudo apt-get install build-essential
sudo apt-get install libncurses5
sudo apt-get install libncurses5-dev
```
&#160; &#160; &#160; &#160; 指定硬件架构：

```shell
export ARCH=arm
```
&#160; &#160; &#160; &#160; 选择原厂提供的默认基本配置：

```shell
make socfpga_defconfig
```
![16](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/16.png)

&#160; &#160; &#160; &#160; 打开配置界面：

```shell
make ARCH=arm menuconfig
```
![17](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/17.png)

&#160; &#160; &#160; &#160; 开始配置内核。

&#160; &#160; &#160; &#160; 首先使能Altera UART驱动。依次进入Device Drivers-->Charater devices-->Serial drivers，在Alrera JTAG UART support、Altera UART support、Altera UART console support选项前的“< >”中输入“y”以使能该选项。

![18](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/18.png)

&#160; &#160; &#160; &#160; 然后使能Altera SPI驱动。首先进入Device Drivers，在SPI support选项前的的“< >”中输入“y”以使能该选项。

![19](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/19.png)

&#160; &#160; &#160; &#160; 接着按下回车进入此选项，在Altera SPI Controller选项前的“< >”中输入“y”以使能该选项。

![20](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/20.png)

&#160; &#160; &#160; &#160; 使能Frame Reader驱动。依次进入Device Drivers-->Graphics support-->Frame buffer Devices,在Support for frame buffer devices选项前的“< >”中输入“y”以使能该选项，会弹出其他选项。

![21](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/21.png)

&#160; &#160; &#160; &#160; 在Altera VIP Frame Reader framebuffer support选项前的“< >”中输入“y”以使能该选项。

![22](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/22.png)

&#160; &#160; &#160; &#160; 为了支持使用显示屏作为console终端，还需要在Device Drivers-->Graphics support-->Console display driver support选项中使能Framebuffer Console support选项。

![23](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/23.png)

&#160; &#160; &#160; &#160; 小梅哥的教程中就说到这里就可以使用USB键盘输入命令了，但实测并不行，还得添加USB HIP外设驱动才能外接键盘使用。

&#160; &#160; &#160; &#160; 依次进入Device Drivers-->HID support-->USB HID support，在PID device support选项前的“< >”中输入“y”以使能该选项。

![24](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/24.png)

&#160; &#160; &#160; &#160; 按键盘上的“>”键使“<Save>”高亮，然后按回车以保存设置。

![25](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/25.png)

&#160; &#160; &#160; &#160; 选择“<Ok>”。然后一直按“ESC”以退出配置界面。

&nbsp;

#### 8.4 保存内核配置文件

&#160; &#160; &#160; &#160; 当前配置暂存在.config文件中，是临时文件。为了方便以后继续调用，需要把他存在“linux-socfpga/arch/arm/configs”路径下。命令如下：

```shell
make savedefconfig && mv defconfig arch/arm/configs/DE1_SoC_defconfig
```
&#160; &#160; &#160; &#160; 保存完成后在“linux-socfpga/arch/arm/configs”路径下就多出一个“DE1_SoC_defconfig”文件。

![26](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/26.png)

&#160; &#160; &#160; &#160; 下次调用保存好的配置文件就输入如下命令：

```shell
make DE1_SoC_defconfig
```

&nbsp;

#### 8.5 编译内核

&#160; &#160; &#160; &#160; 输入以下命令切换到root用户：

```shell
sudo -i

```
&#160; &#160; &#160; &#160; 然后需要输入登陆Ubuntu的密码。

&#160; &#160; &#160; &#160; 进入linux-fpga路径：

```shell
cd /home/verdvana/tools/linux-socfpga   //用户名改成自己的
```
&#160; &#160; &#160; &#160; 使用如下命令指定处理器架构和交叉编译工具：

```shell
export ARCH=arm
export CROSS_COMPILE=/home/verdvana/tools/gcc-linaro-arm-linux-gnueabihf-4.8-2014.04_linux/bin/arm-linux-gnueabihf-
```
&#160; &#160; &#160; &#160; 输入如下命令加载配置好的内核配置文件：

```shell
make DE1_SoC_defconfig
```
&#160; &#160; &#160; &#160; 输入如下指令编译内核：

```shell
make
```
&#160; &#160; &#160; &#160; 编译时间也略长，可以趁机出去走两步。

&#160; &#160; &#160; &#160; 编译完成之后会在“linux-socfpga/arch/arm/boot”路径下生成“zlmage”文件。

![27](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/27.png)

&#160; &#160; &#160; &#160; 将此文件复制到开发板启动SD卡里，覆盖掉原来的文件。安全弹出SD卡，插到开发板里，上电启动，插一个USB键盘，欸嘿嘿，成了！

![1](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/%E4%B8%BASoC-FPGA%E6%B7%BB%E5%8A%A0TFT%E6%98%BE%E7%A4%BA%E5%B1%8F%E5%92%8CUSB%E9%94%AE%E7%9B%98/1.jpg)

--------

&#160; &#160; &#160; &#160; 告辞。