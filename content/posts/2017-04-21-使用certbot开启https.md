+++
title = "使用certbot开启HTTPS"
date = "2017-04-21T03:30:13.000Z"
categories = ["OP"]
tags = ["nginx"]
+++

Deadline就是生产力，因为Chrome 50开始不允许不安全域名使用`geolocation`，所以不得不上https了。使用certbot简直将添加https变成了一件trivial的事情，但是因为我是自己编译安装的nginx，所以没有自动配置好nginx。如果使用yum安装nginx，应该只需要安装执行certbot即可。

安装certbot:

```bash
yum -y install yum-utils
yum-config-manager --enable rhui-REGION-rhel-server-extras rhui-REGION-rhel-server-optional

yum install certbot
```

执行certbot：`certbot certonly --webroot -w {webroot} -d sub.domain.com -d domain.com`

其中`webroot`指网站的根目录，`-d`为该目录的域名，可以有多个，可以有几组这样的`-w`,`-d`组合。

这个命令会有两个验证步骤：在你指定的webroot下放一个文件，在远端尝试访问这个文件，来确定你是否有这个网站的权限。所以你执行这个命令前要保证这个域名和指定的webroot是可以访问的，否则会遇到类似`urn:acme:error:unauthorized :: The client lacks sufficient authorization :: Invalid response from http://sub.domain.com/.well-known/acme-challenge/longlonglonglonghash` 的错误。这时你需要检查下你的web服务器的配置了。

接下来手动配置nginx。

生成ssl dhparam：`openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048`。

配置nginx：

```conf
server {
        listen 443 http2 ssl;

        server_name example.com www.example.com;

        ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

        ########################################################################
        # from https://cipherli.st/                                            #
        # and https://raymii.org/s/tutorials/Strong_SSL_Security_On_nginx.html #
        ########################################################################

        ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
        ssl_prefer_server_ciphers on;
        ssl_ciphers "EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH";
        ssl_ecdh_curve secp384r1;
        ssl_session_cache shared:SSL:10m;
        ssl_session_tickets off;
        ssl_stapling on;
        ssl_stapling_verify on;
        resolver 8.8.8.8 8.8.4.4 valid=300s;
        resolver_timeout 5s;
        # Disable preloading HSTS for now.  You can use the commented out header line that includes
        # the "preload" directive if you understand the implications.
        #add_header Strict-Transport-Security "max-age=63072000; includeSubdomains; preload";
        add_header Strict-Transport-Security "max-age=63072000; includeSubdomains";
        add_header X-Frame-Options DENY;
        add_header X-Content-Type-Options nosniff;

        ##################################
        # END https://cipherli.st/ BLOCK #
        ##################################

        ssl_dhparam /etc/ssl/certs/dhparam.pem;

        location ~ /.well-known {
                allow all;
        }

        # The rest of your server block
        root /usr/share/nginx/html;
        index index.html index.htm;

        location / {
                # First attempt to serve request as file, then
                # as directory, then fall back to displaying a 404.
                try_files $uri $uri/ =404;
        }
}
```

之前的连接都是http的，既不想丢掉索引，又想大家都通过https访问，可以将http都跳转到https：

```
server {
    listen      80;
    server_name example.com;
    return 301 https://$host$request_uri;
}
```

使用了HTTPS之后应该如何在本地测试呢？可以使用自签名的证书：`openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout server.key -out server.crt`，然后在nginx配置中加入

```
    ssl_certificate server.crt;
    ssl_certificate_key server.key;
```

即可。


参考链接：

- [https://certbot.eff.org/#centosrhel7-nginx](https://certbot.eff.org/#centosrhel7-nginx)
- [https://www.digitalocean.com/community/tutorials/how-to-secure-nginx-with-let-s-encrypt-on-centos-7](https://www.digitalocean.com/community/tutorials/how-to-secure-nginx-with-let-s-encrypt-on-centos-7)