---
layout: post
title:  "Cadence入门"
date:   2019-8-7 19:21:10 +0700
tags:
  - PCB
---

-------
### 1 前言

&#160; &#160; &#160; &#160; Altium Designer用了六年，不敢说精通吧，想做点好玩的基本都没啥问题。早都听说Cadence功能强大且使用复杂，之前看同事操作也觉得上手略难。后来还是被它丰富的功能所吸引，从AD的主要功能——PCB设计上手试一下。

* 开发环境：
	* Cadence SPB 17.2
* 操作系统：
	* Windows 10 Pro 1903

----

### 2 原理图设计

&#160; &#160; &#160; &#160; 原理图是通过Cadence收购的OrCAD设计，和AD一样也需要先建立原理图库。

#### 2.1 建立原理图库

&#160; &#160; &#160; &#160; 打开Capture CIS，选择“file”，然后新建库，如图：

![1](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/1.jpg)

&#160; &#160; &#160; &#160; 将新建的库保存，然后右键这个库，选择“New Part”：

![2](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/2.jpg)

&#160; &#160; &#160; &#160; 在弹出的对话框里填写新建器件的属性：

![3](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/3.jpg)

&#160; &#160; &#160; &#160; 前三个不用说了，会用AD就知道。“Part per Pkg”是指这个元件的原理图库有几部分组成，就像AD的原理图库种有的元件包含好几个part一样。其他默认，“OK”，然后就是器件原理图库编辑页面了：

![4](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/4.jpg)

&#160; &#160; &#160; &#160; 这里以电容为例。虚线框内为元件原理图的主体部分，虚线框外放引脚。右边两栏中的选项是画线画框等等的。按照正常比例画出电容的原理图，将虚线框调整到恰好包住原理图：

![5](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/5.jpg)

&#160; &#160; &#160; &#160; 在右边两栏找到“place pin”，添加：

![6](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/6.jpg)

&#160; &#160; &#160; &#160; “name”和“number”按照AD里那么写就行，然后点"ok"，把两个引脚都填写好：

![7](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/7.jpg)

&#160; &#160; &#160; &#160; 这里需要把name和number取消显示。在“Options”里选“Part Properies”：

![8](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/8.jpg)

&#160; &#160; &#160; &#160; 在弹出的User Properties中，将“Pin Names Visible”和“Pin Numbers Visible”都改为“False”：

![9](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/9.jpg)

&#160; &#160; &#160; &#160; 这样就把数字隐藏掉了：

![10](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/10.jpg)

&#160; &#160; &#160; &#160; 设计完电容的原理图库，保存，就完成了。


#### 2.2 设计引脚封装

&#160; &#160; &#160; &#160; 与AD不同，Allegro设计元器件封装得先设计焊盘。打开Padstack Editor：

![11](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/11.jpg)

&#160; &#160; &#160; &#160; 0603封装的焊盘是SMD，所以在Start选项卡里选择“SMD Pin”和“Rectangle”；下面单位选择“millimeter”。在Drill选项卡里的“Hole type”中选择“Square”：

![13](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/13.jpg)

&#160; &#160; &#160; &#160; 查看之前在AD中画的0603焊盘大小，如图：

![12](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/12.jpg)

&#160; &#160; &#160; &#160; 长宽为0.762mm×0.83mm。所以在Design Layers选项卡中，BEGIN LAYER的Regular Pad应选择“Rectangle”，并且“Width”和“Heigh”分别为0.762mm和0.83mm：

![14](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/14.jpg)

&#160; &#160; &#160; &#160; 然后设置阻焊层开窗。在Mask Layers选项卡中，SOLDERMASK_TOP的Pad选为“Rectangle”，长宽分别比焊盘多出0.1mm就行。PASTEMASK_TOP和SOLDERMASK_TOP设置的一样：

![15](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/15.jpg)

&#160; &#160; &#160; &#160; 这样就完成了焊盘的制作，点击保存，格式为“*.pad”。


#### 3.3 设计元件封装

&#160; &#160; &#160; &#160; 打开PCB Editor，选择“File”“New...”：

![16](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/16.jpg)

&#160; &#160; &#160; &#160; “Drawing Type”选“Package symbol”，上面的名称和路径自己定：

![17](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/17.jpg)

&#160; &#160; &#160; &#160; 先设置属性。点击“Setup”->“Design Paramters...”打开设置属性对话框：

![18](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/18.jpg)

&#160; &#160; &#160; &#160; 在Dispaly选项卡中全给他显示了，都打上勾：

![19](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/19.jpg)

&#160; &#160; &#160; &#160; 在Design选项卡中，单位改为毫米，左下角的坐标改为-50，不够再往大了改：

![20](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/20.jpg)


&#160; &#160; &#160; &#160; 设置完点“OK”。从AD里查看0603两个焊盘之间的距离：

![21](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/21.jpg)


&#160; &#160; &#160; &#160; 所以两个焊盘坐标是“-0.762mm,0”“0.762mm,0”。点击“Layout”，选择“Pins”来放置焊盘：

![22](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/22.jpg)

&#160; &#160; &#160; &#160; 在右边的Options选项卡中，在Padstack里选择之前画好的焊盘：

![23](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/23.jpg)

&#160; &#160; &#160; &#160; 如果找不到之前画好的焊盘，需要修改一下焊盘路径。选择“Setup”->“User Preferences...”：

![24](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/24.jpg)

&#160; &#160; &#160; &#160; 然后修改Paths下Library中的padpath，修改为焊盘所在路径，然后一路“OK”：

![25](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/25.jpg)

&#160; &#160; &#160; &#160; 选择好焊盘之后，在下面的Command中输入两次放置焊盘的坐标命令：

```shell
x -0.762 0
x 0.762 0
```
&#160; &#160; &#160; &#160; 即可插入焊盘：

![26](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/26.jpg)

&#160; &#160; &#160; &#160; 如果想改变引脚编号，可以点击“Text Edit”，然后点击需要修改的引脚直接输入：

![27](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/27.jpg)

&#160; &#160; &#160; &#160; 然后是画装配线。还是根据AD查看之前画好的0603封装中电容的实际大小为1.6mm×0.8mm：

![28](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/28.jpg)

&#160; &#160; &#160; &#160; 所以装配线的四个坐标即可算出。点击工具栏中的画线“Add Line”，在右边的属性中修改“Active Class and Subclass：”为装配层：“Package Geometry”，下面的层选为“Assembly_Top”：

![29](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/29.jpg)

&#160; &#160; &#160; &#160; 然后在下面的Command中依次输入装配线的四个坐标，即可画出装配线的框：

```shell
x -0.8 0.4
x -0.8 -0.4 
x 0.8 -0.4
x 0.8 0.4
x -0.8 -0.4
```
![30](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/30.jpg)

&#160; &#160; &#160; &#160; 最后画丝印层。方法和以上类似，只是把层换为“Silkscreen_Top”：

![31](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/31.jpg)

&#160; &#160; &#160; &#160; 如果需要修改线宽，选中线点右键，选择“Change Width...”，输入线宽即可。这样就完成了0603的封装：

![32](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/32.jpg)

&#160; &#160; &#160; &#160; 保存的时候会显示错误：缺失位号：

![33](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/33.jpg)

&#160; &#160; &#160; &#160; 需要在工具栏中选择“Add Text”，在右边的属性中修改“Active Class and Subclass：”为“Ref Des”，下面的层选为“Silkscreen_Top”，然后放置在中心，输入电容的位号：“C*”。再次保存：

![34](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/34.jpg)

&#160; &#160; &#160; &#160; 0603封装设计完成。

#### 3.4 原理图设计

&#160; &#160; &#160; &#160; 放置元器件：选择“Place”->“Part”：

![36](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/36.jpg)

&#160; &#160; &#160; &#160; 在右侧弹出的“Place Part”的“Libraries”中选择所画的原理图库，然后在上面的“Part List”中选择需要的元件，双击放置：

![37](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/37.jpg)

&#160; &#160; &#160; &#160; 如果想要放置其他没有画的常规元件，可以在Cadence自带的原理图库中寻找。点击“Libraries”下的“新建”图标：

![38](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/38.jpg)

&#160; &#160; &#160; &#160; 在弹出的对话框中打开路径：“...Cadence\Cadence_SPB_17.2-2016\tools\capture\library”,即可找到自带的原理图库：

![39](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/39.jpg)

&#160; &#160; &#160; &#160; 将需要的元件放入，对应引脚用线连接（Place Wire）或网络连接（Place Net），其它规范与Altium Designer大致相同，即可完成原理图绘制：

![40](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/40.jpg)


#### 3.5 封装匹配

&#160; &#160; &#160; &#160; 要将原理图的网表导入Allegro，就必须使原理图中的封装与PCB中的封装一一对应。在根目录下右键工程，选择“编辑全局属性”

![41](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/41.jpg)

&#160; &#160; &#160; &#160; 然后在封装那一列将与PCB中对应的封装名填写上：

![42](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/42.jpg)


#### 3.6 原理图编译与检查

&#160; &#160; &#160; &#160; 与Altium Designer中编译原理图类似，在根目录下选择工程，然后在“Tools”中选择“DRC”：

![43](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/43.jpg)


&#160; &#160; &#160; &#160; 弹出的对话框包含四个选项卡，非别是“设计规则选项”、“电气规则”、“物理规则”和“ERC martrix”：

![44](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/44.jpg)


&#160; &#160; &#160; &#160; 全部选默认就行。然后会生成DRC报告：

![45](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/45.jpg)

&#160; &#160; &#160; &#160; 哈哈，没错误，这就是规范的重要性（其实是因为电路太简单了）。如果有错误，就具体问题具体分析了。

#### 3.7 OrCAD快捷键：

|  快捷键  |  含义  |
| --- | --- |
| h | 水平方向镜像 |
|   | 垂直方向镜像 |
| r | 旋转 |
| n | 放置网络 |
| y | 放置线 |



----

### 3 PCB设计

#### 3.1 原理图网表导入PCB

&#160; &#160; &#160; &#160; 在根目录下选中工程，点击“Tools”，选择“Create Netlist...”：

![46](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/46.jpg)

&#160; &#160; &#160; &#160; 弹出的对话框中，“Netlist Files”为网表存放路径，默认为工程路径下的“allegro”文件夹，没有则新建一个。其它选项也为默认，然后点击确定：

![47](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/47.jpg)

&#160; &#160; &#160; &#160; 这样在该文件夹下的*.dat文件即为生成的网表：

![48](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/48.jpg)

&#160; &#160; &#160; &#160; 打开Allero，新建文件。设置一个文件名。类型选择“Board”。路径选择工程路径：

![49](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/49.jpg)

&#160; &#160; &#160; &#160; 点击“OK”新建完成，保存。然后就可以导入网表了。选择“File”->“Import”->“Logic...”：

![50](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/50.jpg)

&#160; &#160; &#160; &#160; 在弹出的对话框中，第一个选项卡为导入使用Cadence设计的原理图的网表。选择“Design entry CIS(Capture)”；还需要把“忽略掉锁定的属性”勾选；在“导入网表路径”中，需要选择**要导入网表的文件夹，而不是文件：**

![51](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/51.jpg)

&#160; &#160; &#160; &#160; 完成后选择“Import Cadence”导入。如果没有Error，则说明导入成功：

![53](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/53.jpg)

&#160; &#160; &#160; &#160; 点击“Display”->“Status”查看状态：

![52](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/52.jpg)

&#160; &#160; &#160; &#160; “Unplaced symbols”为没有放置的器件，“Unrouted nets”为没有连接的网络。此时元器件还没有被放置到PCB上。点击“Place”->"Manually..."：

![54](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/54.jpg)

&#160; &#160; &#160; &#160; 弹出元器件放置清单：

![55](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/55.jpg)


#### 3.2 元器件放置

&#160; &#160; &#160; &#160; 首先需要绘制板框。在板框层“Board Geometry”->“Outline”中放置矩形或线条：

![56](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/56.jpg)

&#160; &#160; &#160; &#160; 指定封装库路径。点击“Setup”->“User Preferences”，选择“Paths”->“Library”，然后修改“padpath”和“psmpath”的路径为焊盘文件路径和封装路径：

![57](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/57.jpg)

&#160; &#160; &#160; &#160; 通过后台放置元器件。点击“Place”->“Quickplace”：然后点击“Place”，即可把元件放入PCB：

![58](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/58.jpg)

&#160; &#160; &#160; &#160; 然后点击“Place”，即可把元件放入PCB：

![59](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/59.jpg)


#### 3.3 PCB初始化设置与颜色配置

&#160; &#160; &#160; &#160; 点击“Setup”->“Design Parameter”，“Display”选项卡中，所有mode都勾选：

![60](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/60.jpg)

&#160; &#160; &#160; &#160; 在“Design”选项卡中，修改以下参数：

![61](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/61.jpg)

&#160; &#160; &#160; &#160; 修改原点。点击“Setup”->“Change Drawing Origin”：

![62](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/62.jpg)


&#160; &#160; &#160; &#160; 然后点击板框左下角，即可将原点设置在板框的左下角：

![63](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/63.jpg)

&#160; &#160; &#160; &#160; 修改格点。点击“Setup”->“Grid”，推荐使用25，分为5等分：

![65](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/65.jpg)


&#160; &#160; &#160; &#160; 选择需要显示的层。点击“Color”，打开“Color Dialog”：

![64](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/64.jpg)

&#160; &#160; &#160; &#160; 默认是全部打开的，先全部关掉，我们需要显示的层为：

* Geometry
	* Board geometry
		* Outline			（板框）
	* Package geometry
		* Silkscreen_Top 	（顶层丝印）
		* SilkScreen_Bottom （底层丝印）
* Components
	* Ref des
		* Silkscreen_Top 	（顶层位号）
		* SilkScreen_Bottom （底层位号）
* Stack-Up
	* Pin					（焊盘）
	* Via					（过孔）
	* Etch 					（走线）
	* Drc

&#160; &#160; &#160; &#160; 如图：

![65](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/Cadence%E5%85%A5%E9%97%A8/65.jpg)

&#160; &#160; &#160; &#160; 点击“OK”完成。布局布线时一般不需要显示位号，关掉即可。

&#160; &#160; &#160; &#160; 颜色配置同样在“Color Dialog”修改，按照自己喜好即可。

----
&#160; &#160; &#160; &#160; 告辞。

