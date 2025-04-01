#!/bin/bash

# AWS CLI の確認
if ! command -v aws &>/dev/null; then
    echo "AWS CLI がインストールされていません。インストールしてください。"
    exit 1
fi

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

distribution_id=$(prompt_for_input "監視対象のCloudFront Distribution IDを入力してください: ")
sns_topic=$(prompt_for_input "アラームを通知するSNSトピック名を入力してください: ")

# AWS認証プロファイルの使用確認
read -rp "AWS認証プロファイルを使用しますか？ (y/n): " use_profile
if [[ "$use_profile" == "y" ]]; then
    while true; do
        read -rp "AWS認証プロファイル名を入力してください: " profile
        if aws configure list-profiles | grep -qx "$profile"; then
            profile_option="--profile $profile"
            echo "✅ プロファイル '$profile' が見つかりました。"
            break
        else
            echo "❌ プロファイル '$profile' が見つかりません。再度入力してください。"
        fi
    done
else
    profile_option=""
    echo "デフォルトのAWS認証プロファイルを使用します。"
fi

# SNSトピックARNの取得
sns_topic_arn=$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':$sns_topic')].TopicArn | [0]" \
    --output text --region us-east-1 $profile_option)

# SNSトピックの存在確認
if [ -z "$sns_topic_arn" ] || [ "$sns_topic_arn" == "None" ]; then
    echo "❌ SNSトピック $sns_topic が見つかりません。正しい名前を入力してください。"
    exit 1
fi

# CloudFront Distribution ID の確認
if [ -z "$distribution_id" ]; then
    echo "❌ CloudFront Distribution ID が入力されていません。"
    exit 1
fi
echo "CloudFront Distribution ID: $distribution_id"

# 監視対象メトリクスと設定
declare -A metrics
metrics=(
    ["Requests"]="AWS/CloudFront"
    ["4xxErrorRate"]="AWS/CloudFront"
    ["5xxErrorRate"]="AWS/CloudFront"
    ["BytesDownloaded"]="AWS/CloudFront"
    ["BytesUploaded"]="AWS/CloudFront"
)

# CloudWatchアラームの作成
create_alarm() {
    local metric=$1
    local threshold=$2
    local comparison_operator=$3
    local alarm_name="${distribution_id}-cloudfront-${metric}"
    local namespace="AWS/CloudFront"
    local dimensions="Name=DistributionId,Value=$distribution_id Name=Region,Value=Global"
    local alarm_description="Alarm for $metric on CloudFront Distribution $distribution_id"

    aws cloudwatch put-metric-alarm \
        --alarm-name "$alarm_name" \
        --metric-name "$metric" \
        --namespace "$namespace" \
        --statistic "Average" \
        --dimensions $dimensions \
        --period 60 \
        --threshold "$threshold" \
        --comparison-operator "$comparison_operator" \
        --evaluation-periods 1 \
        --alarm-actions "$sns_topic_arn" \
        --ok-actions "$sns_topic_arn" \
        --alarm-description "Alarm for $metric on CloudFront Distribution $distribution_id" \
        --region "us-east-1" \
        --treat-missing-data "missing" \
        --datapoints-to-alarm 1 \
        --evaluation-periods 1 \
        --statistic "Average" \
        --alarm-description "$alarm_description" \
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
    "Requests") create_alarm "$metric" 1000 "GreaterThanThreshold" ;;
    "4xxErrorRate") create_alarm "$metric" 5 "GreaterThanThreshold" ;;
    "5xxErrorRate") create_alarm "$metric" 1 "GreaterThanThreshold" ;;
    "BytesDownloaded") create_alarm "$metric" 100000000 "GreaterThanThreshold" ;; # 100MB
    "BytesUploaded") create_alarm "$metric" 10000000 "GreaterThanThreshold" ;;    # 10MB
    *) create_alarm "$metric" 1 "GreaterThanThreshold" ;;
    esac
done