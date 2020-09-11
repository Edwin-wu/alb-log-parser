# -*- coding: UTF-8 -*-
import boto3
import os
import json
import gzip
import geoip2.database
import re
from elasticsearch import Elasticsearch, RequestsHttpConnection
from elasticsearch import helpers
from requests_aws4auth import AWS4Auth
import datetime
from urllib.parse import unquote_plus

#定义log索引的名字开头
INDEX_PREFIX = "alb-access-logs"

#初始化，设定 log 字段
s3_client = boto3.client('s3')
reader = geoip2.database.Reader('GeoLite2-City.mmdb')

fields = [
    "connection_type",
    "timestamp",
    "alb_name",
    "client_ip",
    "client_port",
    "target_ip",
    "target_port",
    "request_processing_time",
    "target_processing_time",
    "response_processing_time",
    "alb_status_code",
    "target_status_code",
    "received_bytes",
    "sent_bytes",
    "request_verb",
    "request_url",
    "request_proto",
    "user_agent",
    "ssl_cipher",
    "ssl_protocol",
    "target_group_arn",
    "trace_id",
    "domain_name",
    "chosen_cert_arn",
    "matched_rule_priority",
    "request_creation_time",
    "actions_executed",
    "redirect_url",
    "error_reason",
    "target:port_list",
    "target_status_code_list",
    "new_field"
]

#把客户端 IP 解析成地理位置信息，比如城市、省份、国家和经纬度
def map_IP_to_location(IP):
    city = "未知"
    province = "未知"
    country = "未知"
    client_location = None
    Clientinfo={}
    source_response=None
    try:
        source_response = reader.city(IP)
    except Exception as e:
        print("Not able to match your IP: {} in Database!".format(IP))

    client_location = str(source_response.location.latitude) + ", " + str(source_response.location.longitude)
    if source_response.city.names.get("zh-CN"):
        city = source_response.city.names.get("zh-CN")
    if len(source_response.subdivisions)>0:
        province = source_response.subdivisions[0].names.get("zh-CN")
    if source_response.country.names.get("zh-CN"):
        country = source_response.country.names.get("zh-CN")
    Clientinfo["city"]=city
    Clientinfo["province"] = province
    Clientinfo["country"] = country
    Clientinfo["location"]=client_location
    return Clientinfo

#用正则规则解析 ALB 的日志
def parse_alb_log_file(fileObj):
    recordset=[]
    regex = r"([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*):([0-9]*) ([^ ]*)[:-]([0-9]*) ([-.0-9]*) ([-.0-9]*) ([-.0-9]*) (|[-0-9]*) (-|[-0-9]*) ([-0-9]*) ([-0-9]*) \"([^ ]*) ([^ ]*) (- |[^ ]*)\" \"([^\"]*)\" ([A-Z0-9-]+) ([A-Za-z0-9.-]*) ([^ ]*) \"([^\"]*)\" \"([^\"]*)\" \"([^\"]*)\" ([-.0-9]*) ([^ ]*) \"([^\"]*)\" \"([^\"]*)\" \"([^\"]*)\" \"([^\"]*)\" ($|\"[^ ]*\")(.*)"
    
    file_content = gzip.decompress(fileObj["Body"].read()).decode('utf-8')
    for line in file_content.strip().split("\n"):
        doc={}
        matches = re.search(regex, line)
        if matches:
            for i, field in enumerate(fields):
                if matches.group(i+1)=='-' or matches.group(i+1)=='' or matches.group(i+1)=='-1' or matches.group(i+1)=='"-"':
                    content=None
                else:
                    content=matches.group(i+1)
                doc[field]=content

            Clientinfo=map_IP_to_location(doc["client_ip"])
            doc["client_location"]=Clientinfo["location"]
            doc["client_city"] = Clientinfo["city"]
            doc["client_province"] = Clientinfo["province"]
            doc["client_country"] = Clientinfo["country"]
            alb_name = re.match(r"(.*)/(.*)/(.*)", doc["alb_name"])[2]
            record = {
                #根据日期生成每天的日志 index
                "_index": INDEX_PREFIX +"-"+alb_name+"-"+str(datetime.date.today()),
                "_source": doc
            }
            recordset.append(record)
        continue
    return recordset


def lambda_handler(event, context):
    #获取AKSK 以生成签名访问 ElasticSearch
    session = boto3.session.Session()
    credentials = session.get_credentials()
    ES_HOST = os.environ['ELASTIC_ENDPOINT']
    awsauth = AWS4Auth(credentials.access_key,
                       credentials.secret_key,
                       session.region_name, 'es',
                       session_token=credentials.token)
    es_client = Elasticsearch([ES_HOST+":443"], use_ssl=True, verify_certs=True, connection_class=RequestsHttpConnection, http_auth=awsauth)
    
    #从 S3 下载文件
    for record in event['Records']:
        bucket = record['s3']['bucket']['name']
        filename = unquote_plus(record['s3']['object']['key'])
        fileObj = s3_client.get_object(Bucket = bucket, Key=filename)
    #解析日志文件
        recordset=parse_alb_log_file(fileObj)
    #写入ElasticSearch
        if len(recordset) > 300:
            helpers.bulk(es_client, recordset)
            print("bulk writing {} records to ElasticSearch.... ".format(len(recordset)))
            recordset = []
        if len(recordset) >= 0:
            print("bulk writing {} records to ElasticSearch. Record process completed. End bulk writing".format(len(recordset)))
            helpers.bulk(es_client, recordset)