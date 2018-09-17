+++
title = "Windows 上使用sshfs"
date = "2018-07-18T09:46:59.062Z"
categories = ["life-pro-tips"]
+++

作为Linux开发者需要利用Windows的图形界面的便利增加开发效率，所以需要将Linux的文件系统mount到Windows上。

Samba 是一个不错的选择，但是Samba 配置复杂，经常出各种问题，而且如果是要经外网访问也有安全问题，所以我觉得sshfs 是一个更安全高效的选择，协议更加安全，有fuse就可以使用，也无需多余配置。但是Windows 没有fuse，所以需要第三方软件的支持。

需要安装两个软件，分别安装[winfsp](https://github.com/billziss-gh/winfsp) [sshfs-win](https://github.com/billziss-gh/sshfs-win) 即可。

安装完就可以像挂载网络磁盘一样，在文件管理器中右键点击“此电脑”，选择”添加一个网络位置“，输入形如`\\sshfs\[locuser=]user@host[!port][\path]` 的地址，例如`\\sshfs\root@localhost!1024\` 就可以了。
