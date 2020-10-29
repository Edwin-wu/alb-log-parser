#!/bin/bash

#运行前请先修改LOG_BUCKET_NAME和ES_DOMAIN_NAME的值，以便脚本正确识别存储桶和 AES 集群
LOG_BUCKET_NAME=example-bucket
ES_DOMAIN_NAME=example-domain


ES_ENDPOINT=$(aws es describe-elasticsearch-domain --domain-name $ES_DOMAIN_NAME --query "DomainStatus.Endpoint" --output text)
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cd /tmp
if [ ! -f "/tmp/alb-log-s3-reader.json" ];then
  echo "创建 Lambda 的权限配置文件"
else
  rm -f /tmp/alb-log-s3-reader.json
fi

echo -n "{ 
    \"Version\": \"2012-10-17\", 
    \"Statement\": [ 
        { 
            \"Effect\": \"Allow\", 
            \"Action\": [ 
                \"s3:GetObject\", 
                \"s3:ListBucket\" 
            ], 
            \"Resource\": \"arn:aws-cn:s3:::${LOG_BUCKET_NAME}\"
        },
        {
            \"Effect\": \"Allow\",
            \"Action\": \"logs:CreateLogGroup\",
            \"Resource\": \"arn:aws-cn:logs:cn-northwest-1:${AWS_ACCOUNT_ID}:*\"
          },
          {
            \"Effect\": \"Allow\",
            \"Action\": [
              \"logs:CreateLogStream\",
              \"logs:PutLogEvents\"
            ],
            \"Resource\": [
              \"arn:aws-cn:logs:cn-northwest-1:${AWS_ACCOUNT_ID}:log-group:/aws/lambda/ALB-log-parsing:*\"
            ]
          }
    ]
}">>alb-log-s3-reader.json
wget https://edwin-blog.s3.cn-northwest-1.amazonaws.com.cn/lambda-trustpolicy.json
echo "正在为Lambda创建 IAM角色....."
if aws iam create-role --role-name alb-log-s3-reader --assume-role-policy-document file://lambda-trustpolicy.json ; then
    if aws iam put-role-policy --role-name alb-log-s3-reader --policy-name alb-log-s3-reader --policy-document file://alb-log-s3-reader.json ; then
        role_arn=$(aws iam get-role --role-name alb-log-s3-reader --query "Role.Arn" --output text)
        echo " Lambda角色创建完毕，已成功关联 S3 权限。"
        rm alb-log-s3-reader.json lambda-trustpolicy.json
    else
        echo "Lambda角色创建完毕，但是关联 S3 权限失败。"
        rm alb-log-s3-reader.json lambda-trustpolicy.json
        exit 1
    fi
else
    echo "创建 Lambda 角色出现错误，请检查是否已有重名的角色或者您是否有权限创建新的 IAM 角色"
    rm alb-log-s3-reader.json lambda-trustpolicy.json
    exit 1
fi
echo "开始创建 Lambda 函数......"
wget https://edwin-blog.s3.cn-northwest-1.amazonaws.com.cn/ALB-log-parsing.zip
if aws lambda create-function \
        --function-name ALB-log-parsing \
        --runtime python3.7 \
        --zip-file fileb://ALB-log-parsing.zip \
        --handler lambda_function.lambda_handler \
        --role $role_arn \
        --timeout 600 \
    --environment "Variables={ES_ENDPOINT=$ES_ENDPOINT}" ; then
    lambda_arn=$(aws lambda get-function --function-name  ALB-log-parsing --query "Configuration.FunctionArn" --output text)
    echo " Lambda 创建完毕，正在为您 配置 S3 事件触发Lambda....."
else
    echo "创建 Lambda 函数失败，请检查LOG_BUCKET_NAME以及ES_DOMAIN_NAME是否已经配置正确，是否已有重名的 Lambda或者您是否有权限创建Lambda 函数"
    rm ALB-log-parsing.zip
    exit 1
fi
echo -n "{
    \"LambdaFunctionConfigurations\": [
        {
            \"LambdaFunctionArn\": \"${lambda_arn}\",
            \"Events\": [
                \"s3:ObjectCreated:*\"
            ]
        }
    ]
}">>notification.json
if aws lambda add-permission --function-name ALB-log-parsing --principal s3.amazonaws.com \
    --statement-id S3Statement --action "lambda:InvokeFunction" \
    --source-arn arn:aws-cn:s3:::$LOG_BUCKET_NAME \
    --source-account $AWS_ACCOUNT_ID ; then
    aws s3api put-bucket-notification-configuration --bucket $LOG_BUCKET_NAME --notification-configuration file://notification.json
    echo "Lambda和S3已经配置完毕，请在 Amazon ElasticSearch 中继续配置权限，允许 Lambda 写入"
else
    echo "配置 S3 时间触发 Lambda，请确认您是否有权限配置 S3 的事件触发器！"
    rm notification.json
    exit 1
fi
