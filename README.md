基于 ElasticSearch 服务对Application Load Balancer 日志做可视化分析
====
综述
-------
Amazon Elasticsearch Service（以下简称 AES 服务）是 AWS 托管的 Elasticsearch 服务，常用于日志分析处理的场景。AES 服务原生支持了跨可用区的高可用、在线版本升级、在线扩容、自动快照备份等功能。AES 还能与 CloudWatch logs、Kinesis Firehose以及 AWS IOT 服务直接集成获取数据，通过 Cloudwatch logs可以将RDS 数据库、Lambda、EMR 等服务日志、CloudTrial 审计日志、CDN 日志、WAF 日志、VPC flow log 流量日志等发送到 AES。结合Cloudwatch agent、Kinesis agent 以及诸如 Filebeat、Logstash 等工具还可以实现将应用程序日志、OS系统日志也发送到 AWS进行综合可视化的展现。并且AES服务能够与 Amazon SNS 服务（SNS 可以对接到短信、邮件、微信、钉钉、电话等）、Amazon Chime 即时通讯服务、Slack平台等集成做告警。因此，除了使用 Cloudwatch 进行监控以外，在 AWS 上非常流行的方式是用 AES 服务构建一个安全信息和事件管理 (SIEM) 系统。  
![](https://github.com/Edwin-wu/alb-log-parser/blob/master/pictures/SIEM.png)

在 AWS 上运行 HTTP/HTTPS服务的时候用户一般都会选用Application Load Balancer（以下简称 ALB），它能够自动扩展和收缩，与 AWS Shield集成抵挡 DDoS 攻击。ALB会生成与 Nginx 日志格式兼容的日志，但是目前只能保存到 S3，还不能直接与 ElasticSearch 集成。如果您有需要将 ALB 的日志发送到 AES 中做日志分析和告警，本文将提供无服务器化的方案将ALB 的日志数据近实时地传输到 AES 用于分析和展现。


方案概述
-------
我们知道 ALB 的日志可以接近实时地存放到 S3 存储桶上，而 S3 上新增文件是一个事件，那么可以考虑基于事件触发Lambda 的机制，将生成的日志文件读取并且解析，然后写入 AES 的 index。因此我们可以考虑采用如下图的架构：  
![](https://github.com/Edwin-wu/alb-log-parser/blob/master/pictures/architecture.png)

以下是关于本文的一些说明和注意事项：
*	Elastic Load Balancing 每 5 分钟为每个负载均衡器节点（每个负载均衡器可能有多个节点）发布一次日志文件。日志传输最终是一致的。负载均衡器可能会在相同时间段产生多个日志，一般是因为这个站点具有高流量。
*	由于我们需要用 Lambda 读取 S3，并写入 AES，所以Lambda 必须能够同时访问 S3和 AES。我们有 2 种推荐的部署模式，一是 Lambda 和 AES 都不放进 VPC 里面，这样比较简单；二是 Lambda 和 AES都放进 VPC 里面，那么 Lambda所部署的子网需要有路由访问 S3（可以通过 NAT 或者 S3 endpoint，一般推荐 S3 endpoint）。在安全实践中，我们推荐第二种方式。本文为了避免纠缠过多网络配置等细节，以第一种方案来进行说明，如果您在实际生产环境部署，请合理规划并推荐使用第二种方式，Lambda代码并不会有变化。如果您同时使用了多个 region，并且希望将日志集中到某个 region 的AES，则目前只能将 lambda和 AES 均不放入 VPC（因为 AES 在 VPC模式不支持 VPC 外的访问）。
*	本文以中国区为例子进行配置的，因此arn 是以arn:aws-cn开头的，如果是 AWS Global region 部署，则 arn 是以arn:aws开头的。如果您是基于海外区域部署，请注意修改相关的 arn。
*	本文的 Lambda 示例代码中采用了geoip2的数据库来解析客户端请求的来源城市、国家和经纬度。geoip2有免费版和收费版的 2 种数据库。本文采用免费版的库，部分解析结果可能会不准确，如果您需要精确的结果，可以考虑替换Lambda 代码包中GeoLite2-City.mmdb文件为收费数据库。
*	本文提供的自动配置lambda写入 AES 的bash 脚本需要安装jq命令。比如mac可以执行brew install jq，Amazon Linux可以执行sudo yum install yq，Ubuntu可以执行sudo apt-get install jq。


方案实现
-------
### 配置 ALB 将日志存储到 S3 存储桶
在 EC2 console 中找到您希望激活日志的ALB，选中后可以在页面最下方找到相应的配置选项。在这个配置界面，我们可以启用 ALB 的访问日志，并且在 S3 位置中输入一个存储桶名称(例如我这里叫 alb-logs-zhy)，勾选“为我创建此位置”，这样系统会自动为您创建该名称的存储桶。点击保存即可。
![](https://github.com/Edwin-wu/alb-log-parser/blob/master/pictures/ELB_setting.png)
![](https://github.com/Edwin-wu/alb-log-parser/blob/master/pictures/ELB_setting2.png)


过几分钟之后我们可以在对应的 S3 存储桶中可以看到对应年月日的 ALB 日志文件，下面是用aws s3 ls命令行查看 S3 日志存储桶中日志文件的截图：
![](https://github.com/Edwin-wu/alb-log-parser/blob/master/pictures/S3_file.png)
 
### 创建解析日志的 Lambda 函数并配置 S3 事件触发 Lambda
在上面的架构设计中，Lambda 必须要能够读取 S3 上的日志文件，并且写入 AES 。因此，它需要 S3 的只读权限以及写入 AES 的权限。由于 AES 内部的 Index 的读写权限是由 Elasticsearch 自己控制的（类似于RDS 数据库的表，并不是创建RDS的人就能有权限读写RDS 里面的表。这个是数据平面和控制平面分离的原则，从而实现安全控制），因此，AES 写入的权限是在 AES 服务中配置的，此处我们只要在 IAM 中给 Lambda对 S3 存储桶的只读权限。
为了简化篇幅起见，配置过程本文以命令行方式提供，实际过程也可以用图形化界面实现。安装和配置 AWS CLI的过程请参考[官方文档的链接](https://docs.aws.amazon.com/zh_cn/cli/latest/userguide/install-cliv1.html)。
安装配置好 AWS CLI以后，请在此[链接](https://raw.githubusercontent.com/Edwin-wu/alb-log-parser/master/alb-log-to-es-sample.sh)下载 bash 脚本，打开脚本修改其中的LOG_BUCKET_NAME和ES_DOMAIN_NAME的值为上文您采集 ALB 日志的存储桶名称，以及您已经建好的 AES集群名称。比如：
```bash
#!/bin/bash

#运行前请先修改LOG_BUCKET_NAME和ES_DOMAIN_NAME的值，以便脚本正确识别存储桶和 AES 集群

LOG_BUCKET_NAME=example-bucket
ES_DOMAIN_NAME=example-domain
```
在命令行中执行以下命令即可：
```bash
bash alb-log-to-es-sample.sh
```
### 配置AES中的日志格式和字段属性
接下来，我们需要登录到 Kibana 上用 Dev Tools设置alb-access-log 开头的 index 的字段类型，以便 AES 能够正确识别每个字段的类型。请在此[链接](https://raw.githubusercontent.com/Edwin-wu/alb-log-parser/master/alb-access-logs-template.txt)下载Dev Tools 的命令脚本，并把它黏贴到 Dev tools 里面，点击右上角的三角形符号执行该模板设定：
![](https://github.com/Edwin-wu/alb-log-parser/blob/master/pictures/ES_Dev_tool.png)
 
如果以上所有设置都成功的话，那么我们可以在Kibana 中创建 ALB 的 Index patterns 了。在 Kibana 的左侧选中Management 图标，点击 Index Patterns，再点击右侧的Create index pattern，在文本框中输入“alb-access-log*”，之后点击 Next Step，并选中 request_creation_time 作为 Time Filter，最后点击Create index pattern保存。 
![](https://github.com/Edwin-wu/alb-log-parser/blob/master/pictures/Create_index_pattern.png)
![](https://github.com/Edwin-wu/alb-log-parser/blob/master/pictures/Create_index_pattern2.png)
 
然后我们就可以在Kibana 的 Discovery 界面看到Lambda 发送过来的新产生的 ALB 日志了：
![](https://github.com/Edwin-wu/alb-log-parser/blob/master/pictures/Create_discover_log.png)
 
最后，我们就可以在 Kibana中将ALB 的日志进行分析和图形化了，比如：
![](https://github.com/Edwin-wu/alb-log-parser/blob/master/pictures/ES_visualization.png)

 
如果您使用的是 AES 7.1以上的版本，建议可以考虑部署一个日志索引生命周期管理，比如保留 7 天的日志索引在热存储，自动转移 30 天以上的日志索引到ultrawarm温存储，超过 30 天的日志索引则可以自动删除。这样可以节省存储容量，避免 AES 的index shard被耗尽。具体操作方法可以参考：
https://docs.aws.amazon.com/zh_cn/elasticsearch-service/latest/developerguide/ism.html


总结
-------
以上内容介绍了利用 Lambda自动解析 ALB 生成的日志并发送到 Amazon ElasticSearch服务，生成可视化监控报表的整体解决方案。结合Amazon Firehose、CloudWatch logs、 AWS IOT服务等，可以将所有可采集的日志汇聚到AES 中进行集中分析和展现，构建统一的 SIEM 平台。AES 内部还集成了随机森林算法可以支持异常检测，从而实现基于机器学习的 AI Ops的运维理念。
