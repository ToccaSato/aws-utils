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

alb_name=$(prompt_for_input "監視対象のALB名を入力してください: ")
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
    --output text $profile_option)

# SNSトピックの存在確認
if [ -z "$sns_topic_arn" ] || [ "$sns_topic_arn" == "None" ]; then
    echo "❌ SNSトピック $sns_topic が見つかりません。正しい名前を入力してください。"
    exit 1
fi

# ALB ARNの取得
alb_arn=$(aws elbv2 describe-load-balancers --names "$alb_name" --query "LoadBalancers[0].LoadBalancerArn" \
    --output text $profile_option)

if [ -z "$alb_arn" ] || [ "$alb_arn" == "None" ]; then
    echo "❌ ALB $alb_name が見つかりません。正しい名前を入力してください。"
    exit 1
fi

# ALB ARN をラベル形式に変換
alb_label=$(echo "$alb_arn" | awk -F'loadbalancer/' '{print $2}')

# ターゲットグループARNをそのまま使用
target_group_label="$target_group_arn"
if [ -z "$alb_label" ]; then
    echo "❌ ALB ARN をラベル形式に変換できませんでした。"
    exit 1
fi
echo "ALBラベル形式: $alb_label"

# ALBのターゲットグループARNを取得
target_group_arn=$(aws elbv2 describe-target-groups --load-balancer-arn "$alb_arn" --query "TargetGroups[0].TargetGroupArn" --output text $profile_option)


if [ -z "$target_group_arn" ] || [ "$target_group_arn" == "None" ]; then
    echo "❌ ターゲットグループが見つかりません。ALBに関連付けられたターゲットグループを確認してください。"
    exit 1
fi

# ターゲットグループARN をラベル形式に変換
target_group_label=$(echo "$target_group_arn" | awk -F':' '{print $6}')
if [ -z "$target_group_label" ]; then
    echo "❌ ターゲットグループARN をラベル形式に変換できませんでした。"
    exit 1
fi
echo "ターゲットグループラベル形式: $target_group_label"

# 監視対象メトリクスと設定
declare -A metrics
metrics=(
    ["RequestCount"]="AWS/ApplicationELB"
    ["HTTPCode_ELB_5XX_Count"]="AWS/ApplicationELB"
    ["HTTPCode_Target_5XX_Count"]="AWS/ApplicationELB"
    ["TargetResponseTime"]="AWS/ApplicationELB"
    ["HealthyHostCount"]="AWS/ApplicationELB"
)

# CloudWatchアラームの作成
create_alarm() {
    local metric=$1
    local threshold=$2
    local comparison_operator=$3
    local alarm_name="${alb_name}-alb-${metric}"
    local namespace="AWS/ApplicationELB"
    local dimensions="Name=LoadBalancer,Value=$alb_label"

    # HealthyHostCount の場合は TargetGroup と LoadBalancer を追加
    if [ "$metric" == "HealthyHostCount" ]; then
        dimensions="Name=TargetGroup,Value=$target_group_label Name=LoadBalancer,Value=$alb_label"
    fi

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
        --alarm-description "Alarm for $metric on $alb_name" \
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
    "RequestCount") create_alarm "$metric" 1000 "GreaterThanThreshold" ;;
    "HTTPCode_ELB_5XX_Count"|"HTTPCode_Target_5XX_Count") create_alarm "$metric" 10 "GreaterThanThreshold" ;;
    "TargetResponseTime") create_alarm "$metric" 0.5 "GreaterThanThreshold" ;;
    "HealthyHostCount") create_alarm "$metric" 1 "LessThanThreshold" ;;
    *) create_alarm "$metric" 1 "GreaterThanThreshold" ;;
    esac
done