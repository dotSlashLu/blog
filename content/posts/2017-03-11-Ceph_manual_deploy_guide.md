+++
title = "Ceph手动部署要点"
date = "2017-03-10T17:59:12.000Z"
categories = ["OP"]
tags = ["Ceph"]
decription = "手动部署Ceph MON, OSD, MDS的步骤总结"
+++

虽然现在preferred的安装方式是采用ceph-deploy，简化了安装了流程，而且便于日后的维护升级。但是手动走一遍有利于新手理解一些Ceph的概念。这篇文章总结一下我几次手动部署的步骤，特别注意了一下官方文档中不清楚了错误的地方。

（针对10.2.x Jewel，12.2.x Luminous 参见[Ceph Luminous 安装要点](/2018/05/21/Ceph-Luminous-安装要点.html)）

## 0. 安装
至少在Hammer版，Ceph的rpm少包含了一个重要的依赖，在CentOS上导致使用init script的时候会报：
```
/etc/init.d/ceph: line 15: /lib/lsb/init-functions: No such file or directory
```
需要安装redhat-lsb，只有这个坑，其他的直接yum或者自己构建即可。

需要提醒的是，国内使用官方yum源可能很慢，可以使用国内的镜像源，例如阿里或网易。
    
## 1. Bootstrap monitors
首先要初始化monitors，这是最复杂的步骤，有了mon集群之后，其他集群就可以很方便地加入mon管理的节点拓扑了。

### 1.1 需要的东西
- fsid: `uuidgen`
- cluster name
- monitor name: `hostname -s`，注意，下面所提及的命令中的hostname，都是执行命令的机器的短hostname，即`hostname -s`，所以为了区分节点，建议使用FQDN，比如node1.cluster1.ceph，这样该机的短hostname即为node1
- monitor map：`monmaptool`
- mointor keyring：monitor之间使用密钥通信，初始化mon时需要使用密钥生成的keyring
- administrator keyring：创建管理用户client.admin

### 1.2 具体步骤
创建第一个节点，后面的节点因为在这个节点中已经生成了相关文件，会省略一些步骤。

创建/etc/ceph/{cluster name}.conf，最小模板：
```
[global]
fsid = {fsid}
mon initial members = {hostname}[,{hostname}]
mon host = {ip}[,{ip}]
```

创建 mon keyring：
```
ceph-authtool --create-keyring /tmp/ceph.mon.keyring --gen-key -n mon. --cap mon 'allow *'
```

创建administrator keyring：
```
ceph-authtool --create-keyring /etc/ceph/{cluster name}.client.admin.keyring --gen-key -n client.admin --set-uid=0 --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow'
```

把client.admin的key加入mon.keyring：
```
ceph-authtool /tmp/ceph.mon.keyring --import-keyring /etc/ceph/{cluster name}.client.admin.keyring
```

创建monmap：
```
monmaptool --create --add {hostname} {ip-address} --fsid {uuid} /tmp/monmap
```

创建mon的数据路径：
```
mkdir /var/lib/ceph/mon/{cluster-name}-{hostname}
```

提供monmap和keyring给monitor deamon：
```
ceph-mon --cluster {cluster-name} --mkfs -i {hostname} --monmap /tmp/monmap --keyring /tmp/ceph.mon.keyring
```

配置/etc/ceph/{cluster-name}.conf

mark as done：
```
touch /var/lib/ceph/mon/{cluster-name}-{hostname}/done
```

开启服务：
```
/etc/init.d/ceph --cluster {cluster-name} start mon.{hostname}
```


### 1.3 其他节点
需要从第一个节点拷贝4个文件：

- /tmp/ceph.mon.keyring
- /tmp/monmap
- /etc/{cluster-name}.client.admin.keyring
- /etc/{cluster-name}.conf

接下来只需要几步，具体命令参考第一个节点：

- 添加该节点到monmap（与第一个节点的命令相同，但略去`--create`参数）
- 创建mon的数据路径
- 提供monmap和keyring给monitor deamon
- 开启服务

## 2. OSD
初始化完mon之后，添加OSD只需要几个简单的命令。

使用ceph-disk 初始化硬盘或分区或文件夹：
```
ceph-disk prepare --cluster {cluster-name} --cluster-uuid {uuid} --fs-type {ext4|xfs|btrfs} {data-path} [{journal-path}]
```
需要注意的是，这里所说的journal-path，实践中发现其实应该填写的是一个block device或者一个文件名，而不是一个文件夹。如果data-path是文件夹，fs-type选项可以忽略。


激活OSD：
```
ceph-disk activate {data-path} [--activate-key {path}]
```
其中的参数activate-key是可选的，用来指定`/var/lib/ceph/bootstrap-osd/{cluster}.keyring`的位置。这个keyring是在ceph-mon mkfs时生成的，所以需要从刚才初始化的mon节点里拷贝过来。

## 3. MDS
若有使用cephfs，则MDS节点是必要的。

首先从mon节点拷贝/etc/ceph/{cluster-name}.conf 配置文件。

在配置文件中填入MDS配置，最小模板：
```
[mds.{mds-number}]
mds data = /var/lib/ceph/mds/mds-{mds-number}
keyring = /var/lib/ceph/mds/mds-{mds-number}/keyring
host = node1
```

创建keyring: `ceph auth get-or-create mds.{mds-number} mds 'allow ' osd 'allow *' mon 'allow rwx' > /var/lib/ceph/mds/mds-{mds-number}/keyring`。

开启MDS：`/etc/init.d/ceph --cluster {cluster-name} start mds.{mds-number}`。

需要注意的是，此时通过`ceph -s`是看不到mds相关信息的，`ceph mds stat`可以看到MDS不是active的状态。需要先创建一个fs，MDS就会被激活。

使用以下命令创建两个pool，一个用来存储fs的文件数据，一个用来存放fs的元数据：`ceph osd pool create {pool-name} {pg-number}`。其中的pg-number参数请参照官方placement group文档：[http://docs.ceph.com/docs/master/rados/operations/placement-groups/#choosing-the-number-of-placement-groups](http://docs.ceph.com/docs/master/rados/operations/placement-groups/#choosing-the-number-of-placement-groups)设置。

创建fs：`ceph fs new {fs-name} {metadata-pool_name} {data-pool_name}`。

此时再看`ceph mds stat`和`ceph -s`，就能看到mds为active and up的状态了。


## 4. 总结

官方文档没有说明白的几点是：

- 至少在CentOS 7.1和Hammer下，需要安装redhat-lsd，不然init script不能使用
- ceph-disk prepare的fs-type在data-path是一个文件夹时是可以省略的，并且journal-path应该带有文件名，ceph不会帮你决定journal文件的名字
- ceph-disk activate时所提供的activate key是mon节点初始化时生成的