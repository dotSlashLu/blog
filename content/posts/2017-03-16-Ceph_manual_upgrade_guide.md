+++
title = "Ceph手动升级要点"
date = "2017-03-16T12:26:28.000Z"
update_time = "2017-04-13T23:03:55.000Z"
description = "总结Ceph手动升级需要注意的地方"
categories = ["OP"]
tags = ["Ceph"]
+++

总结一下自己从Hammer手动(不使用ceph-deploy)升级到Jewel遇到的问题作为前车之鉴。重要信息没有列举，没有直接遇到这些问题的读者请读完后再实施。

## 0. 安装问题

先升级Ceph，这一步没有什么，因为升级并不会重启现有节点，所以还是旧的在跑，需要注意的都在重启的时候。之前是用自己的源安装的，这次用外部源，国内最好配置国内源，一个示例可用的完整的使用了阿里的Ceph源的repo如下，写入`/etc/yum.repos.d/ceph.repo`即可。
```
[ceph]
name=Ceph packages for $basearch
baseurl=http://mirrors.aliyun.com/ceph/rpm-jewel/el7/$basearch
enabled=1
priority=2
gpgcheck=1

[ceph-noarch]
name=Ceph noarch packages
baseurl=http://mirrors.aliyun.com/ceph/rpm-jewel/el7/noarch
enabled=1
priority=2
gpgcheck=1

[ceph-source]
name=Ceph source packages
baseurl=https://mirrors.aliyun.com/ceph/rpm-jewel/el7/SRPMS
enabled=0
priority=2
gpgcheck=1
```

一开始使用这个源配置的时候遇到`Public key for *.rpm is not installed`错误，`gpgcheck`改成0即可。

然后直接`yum upgrade ceph`。可能会遇到依赖不满足的问题，可以试下安装epel的源：`epel-release`。

接下来注意一下重启的步骤，不然可能会出问题：
1. MON
2. OSD
3. MDS
4. RGW

---

## 1. 重启

Jewel版Ceph的默认用户变成ceph:ceph，然而低版本的则默认是root，直接重启会造成`/var/lib/ceph/{node-type}` permission denied问题。

需要将`/var/lib/ceph`以及子目录赋给ceph:ceph：`chown -R ceph:ceph /var/lib/ceph`。但是`chown`并不管链接，OSD的journal和data都是链接过来的，所以还需要chown data和journal。

Jewel与Hammer不同，使用systemctl作为服务管理，不再使用`/etc/init.d/ceph`了，这里说下升级会用到的systemctl用法给不熟悉的读者。systemctl是支持通配符的，操作所有ceph服务: `systemctl {status, start, stop} ceph-*`，注意不要少了`-`。重启前的旧进程因为是init script启动的，所以在systemctl下显示的是`ceph-{node-type}.{instance-id}.***`的形式，可以先status，看到名字之后再复制、stop，最简便的办法是`systemctl stop ceph-{node-type}*`，之后启动就是正常的systemctl service的命名方式了：`systemctl start ceph-{node-type}@{instance-id}.service`。


---

## 2. OSD问题

遇到OSD起不来的问题，大概log如下：
```
2016-06-08 03:06:24.146581 ffffb3ef3000 -1 osd.0 0 backend (filestore) is unable to support max object name[space] len
2016-06-08 03:06:24.146958 ffffb3ef3000 -1 osd.0 0 osd max object name len = 2048
2016-06-08 03:06:24.147090 ffffb3ef3000 -1 osd.0 0 osd max object namespace len = 256
2016-06-08 03:06:24.147205 ffffb3ef3000 -1 osd.0 0 (36) File name too long
2016-06-08 03:06:24.184133 ffffb3ef3000 1 journal close /var/lib/ceph/osd/ceph-0/journal
2016-06-08 03:06:24.249379 ffffb3ef3000 -1 ** ERROR: osd init failed: (36) File name too long
```

这是因为我的测试集群使用了ext4作为后端，而ext4对长文件名不友好，若只使用rbd，没有使用fs的话可以通过增加以下Ceph配置来解决这个问题，使用了fs的话就没有办法使用ext4作为后端了：

```
osd max object name len = 256
osd max object namespace len = 64
```

即使这样能解决问题也是不推荐的，[官方说法](http://docs.ceph.com/docs/jewel/rados/configuration/filesystem-recommendations/):

![]({{<imgHost 2017>}}/osd_name_too_long.png)

在生产中还是使用XFS，高于Jewel版可以尝试Bluestore。

---

## 3. 升级后

升级后在`ceph -s`时会看到`crush map has legacy tunables (require bobtail, min is firefly)`:

![]({{<imgHost 2017>}}/crush_map-legacy_tunables.png)

在所有节点升级完后执行`ceph osd crush tunables optimal`即可(有个坑，见下面5.2部分)。

---

## 4. 总结

Ceph升级起来还算是容易的，downtime也很短：因为在运行中chown不能保证新数据也是ceph:ceph的，所以需要stop掉服务之后再chown，chown的时间大概就是downtime，对于高可用的部署来说一般不成问题。

---

## 5. Update 

### 5.1 CHOWN

线上环境因为数据多，chown是很慢的，1.2T左右的数据要10分钟左右，可以一个故障域一个故障域地更新，设置`noout`的flag，这样down的时间长也不会导致大量同步流量。

为了加速chown，可以使用`parallel`：[https://blog.widodh.nl/2016/08/chown-ceph-osd-data-directory-using-gnu-parallel/](https://blog.widodh.nl/2016/08/chown-ceph-osd-data-directory-using-gnu-parallel/)，同时多个chown会快一点。为了尽量减少数据丢失可能，我是每个节点更新的，不是每台机上的OSD全down一起更新，所以和上述引文每个OSD一个并发不同，为了拿到更多并发chown，我把find的参数指定到`/var/lib/ceph/osd/{cluster-name}-{osd-id}/current`。

另外一个不推荐的办法是直接让ceph以旧权限运行，在所有节点的配置文件中添加`setuser match path = /var/lib/ceph/$type/$cluster-$id`。

### 5.2 tunables

如果你有较低版本的客户端，比如CentOS 6，升级会导致客户端报类似`feature set mismatch, my XXXXXX < server's XXXXXX, missing <missing code>`的错误。这是因为客户端的版本或系统不支持新版的特性。具体的特性可以在[这个表](http://ceph.com/planet/feature-set-mismatch-error-on-ceph-kernel-client/)里面查到，你可以依此升级你的客户端。或者你需要将`tunables`设置为一个客户端支持的，而不是`optimal`。所支持的特性有`legacy|argonaut|bobtail|firefly|hammer|jewel|optimal|default`。