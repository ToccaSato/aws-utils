#!/bin/bash

# AWS CLI のインストール確認
# AWS CLI がインストールされていない場合、エラーメッセージを表示して終了
if ! command -v aws &>/dev/null; then
    echo "AWS CLI がインストールされていません。インストールしてください。"
    exit 1
fi

# 監視対象のインスタンスIDを対話形式で取得
while true; do
  read -rp "監視対象のインスタンスIDを入力してください: " instance_id
  if [ -n "$instance_id" ]; then
    echo "監視対象のインスタンスID: $instance_id"
    break
  else
    echo "インスタンスIDが空です。もう一度入力してください。"
  fi
done

# EBSボリュームのデバイス名とファイルシステムタイプを取得
read -rp "EBSボリュームのデバイス名(デフォルト: xvda1): " device_name
device_name=${device_name:-xvda}

read -rp "EBSボリュームのファイルシステムタイプ(デフォルト: xfs): " fs_type
fs_type=${fs_type:-xfs}

# SNSトピック名を取得（監視結果の通知先）
while true; do
    read -rp "アラームを通知するSNSトピック名を入力してください: " sns_topic
    if [ -n "$sns_topic" ]; then
        echo "SNSトピック名: $sns_topic"
        break
    else
        echo "SNSトピック名が空です。もう一度入力してください。"
    fi
done

# AWS認証プロファイルの使用確認
read -rp "AWS認証プロファイルを使用しますか？ (y/n): " use_profile
if [[ "$use_profile" == "y" ]]; then
    while true; do
        read -rp "AWS認証プロファイル名を入力してください: " profile
        # プロファイルが存在するか確認
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

# SNSトピックが見つからない場合、スクリプトを終了
if [ -z "$sns_topic_arn" ] || [ "$sns_topic_arn" == "None" ]; then
    echo "❌ SNSトピック $sns_topic が見つかりません。正しい名前を入力してください。"
    exit 1
fi

# EC2インスタンスのNameタグを取得
instance_name=$(aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --query "Reservations[].Instances[].Tags[?Key=='Name'].Value | [0]" \
    --output text $profile_option)

# インスタンス名が見つからない場合、手動入力を促す
if [ -z "$instance_name" ] || [ "$instance_name" == "None" ]; then
    read -rp "インスタンス名が見つかりません。名前を手動で入力してください: " instance_name
fi

echo "インスタンス名: $instance_name"

# 監視対象メトリクスとそのCloudWatchネームスペース
declare -A metrics
metrics=(
    ["CPUUtilization"]="AWS/EC2"
    ["StatusCheckFailed"]="AWS/EC2"
    ["mem_used_percent"]="CWAgent"
    ["disk_used_percent"]="CWAgent"
)

# CloudWatchアラームの作成
for metric in "${!metrics[@]}"; do
    alarm_name="${instance_name}-cwa-${metric}"
    namespace="${metrics[$metric]}"

    # メトリクスごとの閾値設定
    case "$metric" in
        "StatusCheckFailed") threshold=1 ;; # ステータスチェック失敗の閾値
        *) threshold=90 ;; # それ以外は90%
    esac

    # メトリクスごとの単位設定
    case "$metric" in
        "CPUUtilization"|"mem_used_percent"|"disk_used_percent") unit="Percent" ;;
        "StatusCheckFailed") unit="Count" ;;
        *) unit="None" ;;
    esac

    # ディスク使用率メトリクスの場合、追加のディメンションを設定
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

    # CloudWatchアラームを作成
    aws cloudwatch put-metric-alarm \
        --alarm-name "$alarm_name" \
        --metric-name "$metric" \
        --namespace "$namespace" \
        --statistic "Average" \
        --dimensions "${dimensions[@]}" \
        --period 60 \
        --threshold "$threshold" \
        --comparison-operator "GreaterThanThreshold" \
        --evaluation-periods 1 \
        --alarm-actions "$sns_topic_arn" \
        --ok-actions "$sns_topic_arn" \
        --alarm-description "Alarm for $metric on $instance_id" \
        --unit "$unit" \
        $profile_option

    # エラーハンドリング
    if [ $? -eq 0 ]; then
        echo "✅ アラーム $alarm_name を作成しました。"
    else
        echo "❌ アラーム $alarm_name の作成に失敗しました。"
    fi
done
