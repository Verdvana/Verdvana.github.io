---
layout: post
title:  "Quartus Prime 17.0及以上版本编译之后无法打开PLL MegaWizard的解决办法"
date:   2019-3-18 9:18:10 +0700
tags:
  - FPGA
---

-------
### 1.出现的问题

&#160; &#160; &#160; &#160; 在Quartus Prime 17.0及以上版本中，使用PLL并且编译之后无法再次打开PLL MegaWizard进行PLL参数的修改。

&#160; &#160; &#160; &#160; IP Component中能看到PLL，但是打开就是PLL.v的源文件，只能修改一下频率。没法再打开GUI修改界面。


------------------

### 2.解决方法

&#160; &#160; &#160; &#160; 其实官方论坛有：[https://forums.intel.com/s/question/0D50P00003yyTmTSAU/cannot-edit-the-generated-pll-intel-fpga-ip-v180?language=en_US](https://forums.intel.com/s/question/0D50P00003yyTmTSAU/cannot-edit-the-generated-pll-intel-fpga-ip-v180?language=en_US)


&#160; &#160; &#160; &#160; 在路径：..\intelFPGA\18.0\ip\altera\altera_pll下找到pll_wizard.plt文件，用文档编辑器打开，里面大概是这样：

```t
[Basic Functions|Clocks; PLLs and Resets|PLL]
Altera PLL v18.1= "%t" "%w/../common/lib/megawizard.pl" --wizard:altera_pll  --early_gen:on --wizard_file:"%w/source/top/pll_hw.tcl" --familyparameter:device_family %f %o %h
<INFO>
<QIP_FILE_ENABLED/>
<ACCEPT_OTHER_CNX VALUE="ON"/>
<DEVICE_FAMILY SUPPORTED="NONE | Stratix V | Arria V | Cyclone V | Arria V GZ" SUPPORT_CHECK="ON" /> 
<LANGUAGES   AHDL="OFF"/>
<PINPLAN SUPPORTED="ON"/>
<ALIAS>Altera PLL</ALIAS>
<ALIAS>Altera PLL v10.0</ALIAS>
<ALIAS>Altera PLL v10.1</ALIAS>
<ALIAS>Altera PLL v11.0</ALIAS>
<ALIAS>Altera PLL v11.1</ALIAS>
<ALIAS>Altera PLL v12.0</ALIAS>
<ALIAS>Altera PLL v12.1</ALIAS>
<ALIAS>Altera PLL v13.0</ALIAS>
<ALIAS>Altera PLL v13.1</ALIAS>
<ALIAS>Altera PLL v14.0</ALIAS>
<ALIAS>Altera PLL v14.1</ALIAS>
<ALIAS>Altera PLL v15.0</ALIAS>
<ALIAS>Altera PLL v15.1</ALIAS>
<ALIAS>Altera PLL v16.0</ALIAS>
<ALIAS>Altera PLL v16.1</ALIAS>
<ALIAS>Altera PLL v17.0</ALIAS>
<ALIAS>Altera PLL v17.1</ALIAS>
<ALIAS>Altera PLL v18.0</ALIAS>
<ALIAS>Altera PLL v18.1</ALIAS>
<ALIAS>Altera PLL v19.0</ALIAS>
<ALIAS>Altera PLL v19.1</ALIAS>
<ALIAS>Altera PLL v20.0</ALIAS>
<ALIAS>Altera PLL v20.1</ALIAS>
</INFO>
```

&#160; &#160; &#160; &#160; Intel收购Altera之后Altera PLL就改名为PLL Intel FPGA IP了，所以把上述文件中对应版本的Altera PLL改为PLL Intel FPGA IP即可。我用的18.1，所以修改为：
```t
[Basic Functions|Clocks; PLLs and Resets|PLL]
Altera PLL v18.1= "%t" "%w/../common/lib/megawizard.pl" --wizard:altera_pll  --early_gen:on --wizard_file:"%w/source/top/pll_hw.tcl" --familyparameter:device_family %f %o %h
<INFO>
<QIP_FILE_ENABLED/>
<ACCEPT_OTHER_CNX VALUE="ON"/>
<DEVICE_FAMILY SUPPORTED="NONE | Stratix V | Arria V | Cyclone V | Arria V GZ" SUPPORT_CHECK="ON" /> 
<LANGUAGES   AHDL="OFF"/>
<PINPLAN SUPPORTED="ON"/>
<ALIAS>Altera PLL</ALIAS>
<ALIAS>Altera PLL v10.0</ALIAS>
<ALIAS>Altera PLL v10.1</ALIAS>
<ALIAS>Altera PLL v11.0</ALIAS>
<ALIAS>Altera PLL v11.1</ALIAS>
<ALIAS>Altera PLL v12.0</ALIAS>
<ALIAS>Altera PLL v12.1</ALIAS>
<ALIAS>Altera PLL v13.0</ALIAS>
<ALIAS>Altera PLL v13.1</ALIAS>
<ALIAS>Altera PLL v14.0</ALIAS>
<ALIAS>Altera PLL v14.1</ALIAS>
<ALIAS>Altera PLL v15.0</ALIAS>
<ALIAS>Altera PLL v15.1</ALIAS>
<ALIAS>Altera PLL v16.0</ALIAS>
<ALIAS>Altera PLL v16.1</ALIAS>
<ALIAS>Altera PLL v17.0</ALIAS>
<ALIAS>Altera PLL v17.1</ALIAS>
<ALIAS>Altera PLL v18.0</ALIAS>
<ALIAS>PLL Intel FPGA IP v18.1</ALIAS>
<ALIAS>Altera PLL v19.0</ALIAS>
<ALIAS>Altera PLL v19.1</ALIAS>
<ALIAS>Altera PLL v20.0</ALIAS>
<ALIAS>Altera PLL v20.1</ALIAS>
</INFO>

```
&#160; &#160; &#160; &#160; 再次在Quartus Prime中打开PLL，又有MegaWizard出现并且可以重新配置PLL了。


--------

&#160; &#160; &#160; &#160; 告辞。

