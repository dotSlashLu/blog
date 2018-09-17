+++
title = "FastDFS与Ceph的比较"
date = "2017-01-27T20:23:55.000Z"
categories = ["存储", "分布式存储", "Ceph",]
+++

研究分布式存储只看Ceph是不够的，想有个横向对比，看看各有什么优缺点，从而深入对Ceph和分布式存储的理解。我司图片存储使用的是FastDFS，所以从它看起。

因为没有真正使用过，只是为了了解概念，所以浅尝辄止，参考资料比较单一，可能存在误解，里面甚至有我的很多猜测、思考和问题，请想了解FastDFS的同学绕道。


---


## 本质差别

FastDFS和Ceph的本质区别：FastDFS不是一个对象存储，是个分布式的文件存储，虽然和传统的NAS有差别，但其本质还是文件存储。所以这个对比其实不是那么横向，差别太大了：

- FastDFS以文件为单位，Ceph以Object为存储单位
- FastDFS没有strip文件，而Ceph(fs)把文件分成object分布在OSD中，read时可以并发，FastDFS没有这样的功能，性能受限于单机


---


## FastDFS节点

FastDFS的节点有两种：tracker和storage。

Tracker节点负责协调集群运作，storage上报心跳、记录storage所属group等，角色有点类似于Ceph中的MON。这些信息很少，且都可以通过storage上报获得无需持久化，所以都存储在内存中，也使得tracker的集群佷容易扩展，每个tracker是**平等**的。

这里我有一个**疑问**，既然是平等的，如何保障一致性？是几个节点同步的，还是storage上报时要多写？

我的猜测是靠同步的，因为下面介绍了写流程之后，你会发现其实一致性并不是很重要。一会儿我们再回到这个问题。

Storage就是存储节点了。

Storage以group为单位，一个group内的storage互为备份。每个storage可以挂不同的盘到不同的*path*。

这种备份是简单的镜像，所以一个group的总容量是最低的那个server决定的，没有Ceph CRUSH map的自动依据硬盘大小的weight功能。

文件上传后以hash为依据分布在storage的文件夹中。


---


## FastDFS上传过程
上传文件时，tracker会选择一个group，可以配置以下方式：
- RR，轮询
- Specified，指定一个group
- Load balance，剩余空间多的优先

选定group之后选择一个storage。规则是：

- RR
- Order by IP
- Order by priority，优先级排序

问题：既然group内的storage是镜像的，为什么还要选择一个上传呢，随机一个不都可以吗？

然后选定path，也就是同一台storage上不同的数据盘：

- RR
- 剩余空间多优先

Storage生成fileid：`base64({storage IP}{create time}{file size}{file crc32}{random number})`。

接着选定两级子目录，这个不重要且很简单，只是为了避免同个目录下的文件过多。

生成文件名，包含：
- group
- 目录
- 两级子目录
- fileid
- 文件后缀（客户端指定，区分类型）

一个文件名的例子：`group1/M00/00/0C/wKjRbExx2K0AAAAAAAANiSQUgyg37275.h`。


---


## FastDFS文件同步

文件写入上文规则选出的一个storage server即返回成功，再由后台线程同步到其他节点。而Ceph的要求是写入主primary OSD之后所有副本比如第二第三OSD完成之后才返回成功，数据安全性更高。

只primary写完就返回，那其它同group的storage什么时候能提供服务？这个要靠是否同步完成来判断。同步的进度靠primary storage的binlog记录，binlog会同步到tracker，读请求时tracker根据同步进度选择可读的storage。

现在我们回到刚才介绍tracker时所提的一致性问题。首先group的信息只在增加／减少节点时比较重要，而且暂时某些tracker没有update到节点的增加是不影响服务的，减少比较麻烦，如果没有update到，可能会读取失败，将来可以了解一下FastDFS是如何保证tracker间一致性的。


---


## FastDFS小文件合并机制

必要性：
1. 解决inode数量限制问题
2. 多级目录+目录里很多文件导致IO开销大
3. 备份恢复效率低

我认为问题1不成立，inode数量在format时是可调的，以ext4为例，可以最多存储2 ^ 32个文件，假设存储的都是空文件，4kb的block size，2 ^ 32个文件可以存储17TB，远大于常见单块硬盘容量。问题2，文件系统使用树来存储inode，比如ext3使用HTree，一个文件夹过多文件确实是个问题。然而问题3才是大问题，小文件在网络传输时overhead很大。

FastDFS增加了trunk file的概念，几个小文件合并在一个trunk file中，在文件id中增加该文件在trunk file中的offset。由于id返回给client就不能变了，所以删除一个文件之后对应trunk file是不能压缩的，只能将这段block重新利用。

Ceph没有类似的机制。


---


## FastDFS的问题

1. 数据安全性问题：写一份就返回，如果primary在未将文件同步到其他storage时挂掉就丢数据，Ceph没有这个问题，但是相应会有写入延时损耗
2. 性能问题：没有strip，读不是并发的
3. 运维问题：不能自动恢复数据
