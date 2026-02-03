---
layout: post
title:  "如何利用GitHub Pages搭建个人博客"
date:   2018-12-18 11:07:10 +0700
tags:
  - Others
---

-------
### 1.前言

&#160; &#160; &#160; &#160;利用GitHub为开发者建立的私人页面“GitHub Pages”来搭建个人博客,不需要租服务器或购买域名。    

-------
### 2.注册GitHub帐号

&#160; &#160; &#160; &#160;打开GitHub官网注册帐号：[GitHub](https://github.com/)

![注册账号](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/how_to_make_website/sign_up_github.jpg)     

--------
### 3.创建仓库
&#160; &#160; &#160; &#160;去创建一个新的仓库：[新建仓库](https://github.com/new)       
 
&#160; &#160; &#160; &#160;仓库的名称必须是 __“用户名.github.io”__ (区分大小写)。   

![新建仓库](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/how_to_make_website/creat_a_new_repository.jpg)


-----
### 4.设置仓库

&#160; &#160; &#160; &#160;新建仓库后，在当前页面选择Setting，进入设置页面，用来生成GitHub Pages。

&#160; &#160; &#160; &#160;先去选择一个主题。

![选择主题](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/how_to_make_website/chosse-a-theme.png)

&#160; &#160; &#160; &#160;选择。

![选择](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/how_to_make_website/select-theme.png)

&#160; &#160; &#160; &#160;生成。


![生成pages](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/how_to_make_website/generate_github_pages.jpg)

&#160; &#160; &#160; &#160;设置好之后就可以打开这个页面了，地址就是 __“用户名.github.io”__ 。

&#160; &#160; &#160; &#160;这时候这个网页就初步搭建好，只是还没有任何内容。

-----
### 5.选择模板

&#160; &#160; &#160; &#160;去Jekyll选择一个喜欢的模板：[Jekyll](http://jekyllthemes.org/)

&#160; &#160; &#160; &#160;将选择的模板下载并解压，把解压出的文件替换掉你github.io仓库中的文件。

![替换文件](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/how_to_make_website/choose_theme.jpg)

&#160; &#160; &#160; &#160;刚建好的仓库肯定没我这么多东西，大概就两三个文件，都删掉再把模板拖进去也行。

&#160; &#160; &#160; &#160;替换的时候可以用Sourcetree或者GitHub客户端等软件将你的仓库克隆到本地进行替换，我懒得写了所以这里直接在网页上替换了，往里拖就行。

&#160; &#160; &#160; &#160;等一分钟。

&#160; &#160; &#160; &#160;再打开你的GitHub Pages页面，就会变成刚刚选择的模板的样式，但内容还是模板里面自带的。

------
### 6.修改内容

&#160; &#160; &#160; &#160;首先看下这些文件都是些啥：

![文件](https://raw.githubusercontent.com/Verdvana/Verdvana.github.io/master/_posts/how_to_make_website/file.jpg)

* index.html：博客主页内容；

*  \_config.yml：博客的基本配置文件，修改主页的文字就在这里面修改；

* \data: 这文件夹里放的是工程页面中的内容，可以添加工程名儿和日期照片啥的；

* \_layouts：这文件夹里面存放每个页面的设计，一般有default.html（默认页面）和posts.html（博文页面）；

* \_includes：这个文件夹里的的内容将会通用到你博客每个页面，起到一种便利的作用；

* \_posts：这个文件夹里就是博文了，要用markdown语法编写。

&#160; &#160; &#160; &#160;按照需求修改就行了，我从没学过网页也能猜到个大概。修改完之后保存上传至GitHub，上个厕所回来再刷新GitHub Pages网页就可以看到网页有变化。

&#160; &#160; &#160; &#160;至于能写成啥样就不关我的事儿了。

--------



&#160; &#160; &#160; &#160;告辞。

