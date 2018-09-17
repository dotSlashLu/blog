+++
title = "Ceph Luminous 安装要点"
date = "2018-05-21T02:34:52.000Z"
update_time = "2018-06-04T23:36:18.000Z"
categories = ["Ceph", "OP"]
+++

只记录Luminous 和旧版有区别的地方，基本流程没有变，参见[旧文](/2017/03/11/Ceph_manual_deploy_guide.html)。

## Bootstrap keyring
之前的版本在初始化mon的时候会在`/var/lib/ceph/bootstrap-{节点名}/`自动生成bootstrap其他节点用的keyring，但是有时候又不会。

如果没有这个keyring，可以手动生成以初始化除了mon以外的节点。

根据[文档](http://docs.ceph.com/docs/master/install/manual-deployment/)：

```
ceph-authtool --create-keyring /var/lib/ceph/bootstrap-osd/ceph.keyring \
--gen-key -n client.bootstrap-osd --cap mon 'profile bootstrap-osd'
```

但是不知道为什么并没有用，在`ceph auth list`里面并没有看到新的key生成。所以还是用老方法：

```
ceph auth get-or-create client.bootstrap-osd mon 'profile bootstrap-osd'
```

## 创建bluestore
Luminous 默认存储backend 由filestore替换成了新的bluestore，同时也简化了初始化流程：

```
ceph-volume lvm create --data {data-path}
```

要求硬盘没有挂载。

这样默认创建出来的bluestore 会分出两个区，一个区给block，一个区给db。如果有更好的设备，可以按如下方式把db单独放在另一块盘。

假设sdc是一块ssd，想要把所有bluestore的db都放在sdc上。在sdc上创建bluestore rocksdb用的lg：
```
pvcreate /dev/sdc
vgcreate ceph-journal /dev/sdc
```

对每个OSD，
- 创建db用的lv：
```
lvcreate --size 10G ceph-journal --name ${dev}.db && \
lvcreate --size 10G ceph-journal --name ${dev}.wal
```

- prepare, activate:
```
ceph-volume lvm prepare --data /dev/${dev} --block.db ceph-journal/${dev}.db --block.wal ceph-journal/${dev}.wal
ceph-volume lvm activate ${osd num} ${osd uuid}
```
其中的`osd num`和`osd uuid`可以在prepare的结果中看到。




## mgr
Luminous 新增了mgr节点，和mon一起对外界提供监控和管理接口，如果没有mgr节点会报错。
```
yum install ceph-mgr
mkdir /var/lib/ceph/mgr/ceph-1
ceph auth get-or-create mgr.1 mon 'allow profile mgr' osd 'allow *' mds 'allow *' > /var/lib/ceph/mgr/ceph-1/keyring
systemctl start ceph-mgr@1
```

奇怪的是mgr虽然成了必需节点，但是client.admin key并没有mgr的权限，导致很多获取stats的命令都用不了了，所以还要手动添加一下：

```
ceph auth caps client.admin mds allow mon 'allow *' osd 'allow *' \
mgr 'allow *'
```