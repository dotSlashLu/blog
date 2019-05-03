+++
title = "一次python内存泄露debug"
date = "2017-07-20T02:14:20.925Z"
categories = ["编程"]
tags = ["debug"]
+++

最近发现平台一个python组件跑一段时间之后就会丢消息，卡住，然后内存暴增。这个组件主要负责接收agent上报，上报采用了ZeroMQ，收到消息后分给worker thread进一步处理入库。Debug的时候没有经验颇踩了一些坑浪费了很多时间，记录在此以警世人。

## 1. 直觉排查
因为之前遇到过类似的情况，直觉上以为是zmq的问题，可能上报连接过多，并且没有主动关闭，造成tw bucket overflow，再加上重试机制，只要一堵塞，就有越来越多重试，造成雪崩。看看`ss`，确实连接很多。想办法改进了一下agent，连接数是有降下来了，遗憾的是卡住内存暴增的现象还是没有解决。

## 2. 系统调用分析
这种卡住的情况，使用`pdb`是没办法的，只能使用`strace` + `gdb`。

`gdb`有python模块，但是业务机上面gdb无法和python一起build，所以attach了dump core也没有看出什么，全是??，也无法使用`py-bt`等命令来排查python代码问题。

`ps -T`找出这个进程的线程，找了一个内存最大的线程去`strace`，发现卡在`recv`:

```
$ strace -p 32031
Process 32031 attached - interrupt to quit
recvfrom(44, ^C <unfinished ...>
Process 32031 detached
```

为什么卡在`recv`？难道是一个client导致的？从44这个fd着手，去查查这个socket的远端：

```
$ ls -alh /procs/31757/fd/44
lrwx------ 1 root root 64 Jul  2 03:23 44 -> socket:[730348541]

$ss -emp | grep 730348541
ESTAB      0      0            10.3.y.y:33226         10.3.x.x:4313     timer:(keepalive,9min23sec,0) users:(("python",31757,44)) ino:730348541 sk:ffff88010c747800
```

看到timer，这个连接已经keepalive了9分钟，这让我确信是zmq的连接机制的问题，双重保险，除了改了agent的socket的linger选项，还改小了keepalive：
```
sysctl -w net.ipv4.tcp_keepalive_time=30 net.ipv4.tcp_keepalive_intvl=10 net.ipv4.tcp_keepalive_probes=1
```

遗憾的是并没有什么用。。。


## 3. gdb - 事实真相
失望之后隔天再调，遇到了几次问题之后，发现每次卡住的IP很眼熟啊，记录一下还真的都是10.3.x.x:4313，原来每次都卡在recv这个IP上，想起这个IP是数据库proxy的IP，认为是db的问题，可能是一直不返回造成卡死？

偶然一次在gdb里`info threads`，发现卡住的并不是一个thread。。。而是有两个，都是在`recvfrom(44,`...一个进程的所有thread的fd是共享资源，所以两个thread同时在recv一个socket，这肯定有竞争啊。

问题现在就很简单了，就是应用层面的数据库连接竞争。刚好一个同事最近确实改了数据库部分的代码，改成了每个库分配一个连接池，不是线程安全的。

## 4. 事后总结
Debug不能乱阵脚，要有逻辑，除了有线索直接去查问题，整体排查应该从上至下，从大局入手，先看个概览。针对这个问题来说，多线程程序卡住，应该首先想到的就是锁啊，是不是饿死了啊。