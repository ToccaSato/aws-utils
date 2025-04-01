#!/bin/bash

# AWS CLI の確認
if ! command -v aws &>/dev/null; then
    echo "AWS CLI がインストールされていません。インストールしてください。"
    exit 1
fi

# 入力を促す関数
prompt_for_input() {
    local prompt_message=$1
    local input_variable
    while true; do
        read -rp "$prompt_message" input_variable
        if [ -n "$input_variable" ]; then
            echo "$input_variable"
            break
        else
            echo "入力が空です。もう一度入力してください。"
        fi
    done
}

# RDSインスタンス識別子を取得
rds_instance_id=$(prompt_for_input "監視対象のRDSインスタンス識別子を入力してください: ")

# SNSトピック名を取得
sns_topic=$(prompt_for_input "アラームを通知するSNSトピック名を入力してください: ")

# AWS認証プロファイルの使用確認
read -rp "AWS認証プロファイルを使用しますか？ (y/n): " use_profile
if [[ "$use_profile" == "y" ]]; then
    profile=$(prompt_for_input "AWS認証プロファイル名を入力してください: ")
    if aws configure list-profiles | grep -qx "$profile"; then
        profile_option="--profile $profile"
        echo "✅ プロファイル '$profile' が見つかりました。"
    else
        echo "❌ プロファイル '$profile' が見つかりません。"
        exit 1
    fi
else
    profile_option=""
    echo "デフォルトのAWS認証プロファイルを使用します。"
fi

# SNSトピックARNの取得
if ! sns_topic_arn=$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':$sns_topic')].TopicArn | [0]" --output text $profile_option); then
    echo "❌ SNSトピックARNの取得に失敗しました。"
    exit 1
fi

# SNSトピックの存在確認
if [ -z "$sns_topic_arn" ] || [ "$sns_topic_arn" == "None" ]; then
    echo "❌ SNSトピック $sns_topic が見つかりません。正しい名前を入力してください。"
    exit 1
fi

# 監視対象メトリクスとそのCloudWatchネームスペース
declare -A metrics=(
    ["CPUUtilization"]="AWS/RDS"
    ["FreeableMemory"]="AWS/RDS"
    ["DatabaseConnections"]="AWS/RDS"
    ["ReadLatency"]="AWS/RDS"
    ["WriteLatency"]="AWS/RDS"
)

# CloudWatchアラームの作成関数
create_alarm() {
    local metric=$1
    local threshold=$2
    local comparison_operator=$3
    local alarm_name="${rds_instance_id}-rds-${metric}"
    local namespace="${metrics[$metric]}"
    local unit="None"

    aws cloudwatch put-metric-alarm \
        --alarm-name "$alarm_name" \
        --metric-name "$metric" \
        --namespace "$namespace" \
        --statistic "Average" \
        --dimensions "Name=DBInstanceIdentifier,Value=$rds_instance_id" \
        --period 60 \
        --threshold "$threshold" \
        --comparison-operator "$comparison_operator" \
        --evaluation-periods 1 \
        --alarm-actions "$sns_topic_arn" \
        --ok-actions "$sns_topic_arn" \
        --alarm-description "Alarm for $metric on $rds_instance_id" \
        $profile_option

    if [ $? -eq 0 ]; then
        echo "✅ アラーム $alarm_name を作成しました。"
    else
        echo "❌ アラーム $alarm_name の作成に失敗しました。"
    fi
}

# メトリクスごとのアラーム作成
for metric in "${!metrics[@]}"; do
    case "$metric" in
        "CPUUtilization")
            threshold=80
            comparison_operator="GreaterThanThreshold"
            ;;
        "FreeableMemory")
            threshold=64000000
            comparison_operator="LessThanThreshold"
            ;;
        "DatabaseConnections")
            threshold=100
            comparison_operator="GreaterThanThreshold"
            ;;
        "ReadLatency"|"WriteLatency")
            threshold=0.1
            comparison_operator="GreaterThanThreshold"
            ;;
        *)
            threshold=1
            comparison_operator="GreaterThanThreshold"
            ;;
    esac

    create_alarm "$metric" "$threshold" "$comparison_operator"
done