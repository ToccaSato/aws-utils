#!/bin/bash

# AWS CLI のインストール確認
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

# 監視対象のインスタンスIDを取得
instance_id=$(prompt_for_input "監視対象のインスタンスIDを入力してください: ")

# EBSボリュームのデバイス名とファイルシステムタイプを取得
read -rp "EBSボリュームのデバイス名(デフォルト: xvda1): " device_name
device_name=${device_name:-xvda1}

read -rp "EBSボリュームのファイルシステムタイプ(デフォルト: xfs): " fs_type
fs_type=${fs_type:-xfs}

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

# SNSトピックが見つからない場合
if [ -z "$sns_topic_arn" ] || [ "$sns_topic_arn" == "None" ]; then
    echo "❌ SNSトピック $sns_topic が見つかりません。正しい名前を入力してください。"
    exit 1
fi

# EC2インスタンスのNameタグを取得
if ! instance_name=$(aws ec2 describe-instances --instance-ids "$instance_id" --query "Reservations[].Instances[].Tags[?Key=='Name'].Value | [0]" --output text $profile_option); then
    echo "❌ EC2インスタンスのNameタグの取得に失敗しました。"
    exit 1
fi

# インスタンス名が見つからない場合、手動入力を促す
if [ -z "$instance_name" ] || [ "$instance_name" == "None" ]; then
    instance_name=$(prompt_for_input "インスタンス名が見つかりません。名前を手動で入力してください: ")
fi

echo "インスタンス名: $instance_name"

# 監視対象メトリクスとそのCloudWatchネームスペース
declare -A metrics=(
    ["CPUUtilization"]="AWS/EC2"
    ["StatusCheckFailed"]="AWS/EC2"
    ["mem_used_percent"]="CWAgent"
    ["disk_used_percent"]="CWAgent"
)

# CloudWatchアラームの作成関数
create_alarm() {
    local metric=$1
    local threshold=$2
    local unit=$3
    local dimensions=("${!4}")
    local alarm_name="${instance_name}-cwa-${metric}"
    local namespace="${metrics[$metric]}"

    aws cloudwatch put-metric-alarm \
        --alarm-name "$alarm_name" \
        --metric-name "$metric" \
        --namespace "$namespace" \
        --statistic "Average" \
        --dimensions "${dimensions[@]}" \
        --period 60 \
        --threshold "$threshold" \
        --comparison-operator "GreaterThanOrEqualToThreshold" \
        --evaluation-periods 1 \
        --alarm-actions "$sns_topic_arn" \
        --ok-actions "$sns_topic_arn" \
        --alarm-description "Alarm for $metric on $instance_id" \
        --unit "$unit" \
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
        "StatusCheckFailed")
            threshold=1
            unit="Count"
            ;;
        *)
            threshold=90
            unit="Percent"
            ;;
    esac

    if [[ "$metric" == "disk_used_percent" ]]; then
        dimensions=(
            "Name=path,Value=/"
            "Name=InstanceId,Value=$instance_id"
            "Name=device,Value=$device_name"
            "Name=fstype,Value=$fs_type"
        )
    else
        dimensions=("Name=InstanceId,Value=$instance_id")
    fi

    create_alarm "$metric" "$threshold" "$unit" dimensions[@]
done