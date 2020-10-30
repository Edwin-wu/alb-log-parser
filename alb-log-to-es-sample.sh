#!/bin/bash

#运行前请先修改LOG_BUCKET_NAME和ES_DOMAIN_NAME的值，以便脚本正确识别存储桶和 AES 集群
LOG_BUCKET_NAME=example-bucket
ES_DOMAIN_NAME=example-domain


ES_ENDPOINT=$(aws es describe-elasticsearch-domain --domain-name $ES_DOMAIN_NAME --query "DomainStatus.Endpoint" --output text)
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)


#创建 Lambda 的角色和权限
cd /tmp
if [ ! -f "/tmp/alb-log-s3-reader.json" ];then
  echo "创建 Lambda 的权限配置文件"
else
  rm -f /tmp/alb-log-s3-reader.json
fi

echo "{ 
    \"Version\": \"2012-10-17\", 
    \"Statement\": [ 
        { 
            \"Effect\": \"Allow\", 
            \"Action\": [ 
                \"s3:GetObject\", 
                \"s3:ListBucket\" 
            ], 
            \"Resource\": \"arn:aws-cn:s3:::${LOG_BUCKET_NAME}/*\"
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

echo "{ 
    \"Version\": \"2012-10-17\", 
    \"Statement\": [ 
        { 
            \"Effect\": \"Allow\", 
            \"Principal\": {
                \"Service\": \"lambda.amazonaws.com\"
            },
            \"Action\": \"sts:AssumeRole\"
          }
    ]
}">>lambda-trustpolicy.json
echo "正在为Lambda创建 IAM角色....."
if aws iam create-role --role-name alb-log-s3-reader --assume-role-policy-document file://lambda-trustpolicy.json ; then
    if aws iam put-role-policy --role-name alb-log-s3-reader --policy-name alb-log-s3-reader --policy-document file://alb-log-s3-reader.json ; then
        role_arn=$(aws iam get-role --role-name alb-log-s3-reader --query "Role.Arn" --output text)
        echo " Lambda角色创建完毕，已成功关联 S3 权限。"
        rm alb-log-s3-reader.json lambda-trustpolicy.json
    else
        echo "Lambda角色创建完毕，但是关联 S3 权限失败。"
        rm alb-log-s3-reader.json lambda-trustpolicy.json
        aws iam delete-role-policy --role-name alb-log-s3-reader --policy-name alb-log-s3-reader
        aws iam delete-role --role-name alb-log-s3-reader
        exit 1
    fi
else
    echo "创建 Lambda 角色出现错误，请检查是否已有重名的角色或者您是否有权限创建新的 IAM 角色"
    rm alb-log-s3-reader.json lambda-trustpolicy.json
    exit 1
fi

#创建 Lambda 函数
echo "开始下载 Lambda 代码......"
wget https://raw.githubusercontent.com/Edwin-wu/alb-log-parser/master/ALB-log-processor.zip -O ALB-log-processor.zip
echo "开始上传 Lambda 代码并创建函数......"
if aws lambda create-function \
        --function-name ALB-log-parsing \
        --runtime python3.7 \
        --zip-file fileb://ALB-log-processor.zip \
        --handler log_parser.lambda_handler \
        --role $role_arn \
        --timeout 600 \
    --environment "Variables={ELASTIC_ENDPOINT=$ES_ENDPOINT}" ; then
    lambda_arn=$(aws lambda get-function --function-name  ALB-log-parsing --query "Configuration.FunctionArn" --output text)
    echo " Lambda 创建完毕，正在为您 配置 S3 事件触发Lambda....."
else
    echo "创建 Lambda 函数失败，请检查是否已有重名的 Lambda或者您是否有权限创建Lambda 函数"
    aws iam delete-role-policy --role-name alb-log-s3-reader --policy-name alb-log-s3-reader
    aws iam delete-role --role-name alb-log-s3-reader
    rm ALB-log-parsing.zip
    exit 1
fi

#配置 S3 存储桶自动触发 lambda
echo "{
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
    echo "Lambda和S3已经配置完毕，即将在 Amazon ElasticSearch 中配置权限，允许 Lambda 写入"
else
    echo "配置 S3 事件触发 Lambda失败，请确认您是否有权限配置 S3 的事件触发器！"
    aws iam delete-role-policy --role-name alb-log-s3-reader --policy-name alb-log-s3-reader
    aws iam delete-role --role-name alb-log-s3-reader
    aws lambda delete-function --function-name ALB-log-parsing
    rm notification.json ALB-log-parsing.zip
    exit 1
fi
rm notification.json ALB-log-processor.zip

#配置 ElasticSearch 服务以添加 Lambda role 的权限
aws es describe-elasticsearch-domain --domain-name $ES_DOMAIN_NAME --query "DomainStatus.AccessPolicies" --output text >>old_policy.json
if jq .Statement[0].Principal.AWS[0] old_policy.json >/dev/null 2>&1; then
    new_principal=$(jq .Statement[0].Principal.AWS+[\"$role_arn\"] old_policy.json)
    new_policy=$(jq .Statement[0].Principal.AWS="$new_principal" old_policy.json --compact-output)
elif jq .Statement[0].Condition.IpAddress old_policy.json >/dev/null 2>&1; then
    additional_principal="{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"$role_arn\"},\"Action\":\"es:*\",\"Resource\":$(jq .Statement[0].Resource old_policy.json)}"
    new_principal=$(jq .Statement+[$additional_principal] old_policy.json)
    new_policy=$(jq .Statement="$new_principal" old_policy.json --compact-output)
    echo $new_policy
else
    new_principal=$(jq [.Statement[0].Principal.AWS]+[\"$role_arn\"] old_policy.json)
    new_policy=$(jq .Statement[0].Principal.AWS="$new_principal" old_policy.json --compact-output)
fi
if aws es update-elasticsearch-domain-config --domain-name $ES_DOMAIN_NAME --access-policies $new_policy; then
    echo "已经完成更新 ElasticSearch 的权限设置，请继续登录ElasticSearch设置"
    rm old_policy.json
else
    echo "更新 ElasticSearch 权限设置失败，请检查 ElasticSearch 是否开启了精细化权限控制，或者 ElasticSearch是否处于 VPC 中"
    exit 1
fi



