 #!/bin/bash

# AWS CLI の確認
if ! command -v aws &>/dev/null; then
    echo "AWS CLI がインストールされていません。インストールしてください。"
    exit 1
fi

# RDSインスタンス識別子の入力
while true; do
  read -rp "監視対象のRDSインスタンス識別子を入力してください: " rds_instance_id
  if [ -n "$rds_instance_id" ]; then
    echo "監視対象のRDSインスタンス: $rds_instance_id"
    break
  else
    echo "インスタンス識別子が空です。もう一度入力してください。"
  fi
done

# SNSトピック名の入力
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
        # 入力したプロファイルが存在するか確認
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

# 監視対象メトリクスと設定
declare -A metrics
metrics=(
    ["CPUUtilization"]="AWS/RDS"
    ["FreeableMemory"]="AWS/RDS"
    ["DatabaseConnections"]="AWS/RDS"
    ["ReadLatency"]="AWS/RDS"
    ["WriteLatency"]="AWS/RDS"
)

# CloudWatchアラームの作成
for metric in "${!metrics[@]}"; do
    alarm_name="${rds_instance_id}-rds-${metric}"
    namespace="${metrics[$metric]}"

    # メトリクスごとのしきい値を設定
    case "$metric" in
        "CPUUtilization") threshold=80 ;; # CPU使用率のしきい値 80%
        "FreeableMemory") threshold=64000000 ;; # 利用可能メモリ 64MB
        "DatabaseConnections") threshold=100 ;; # 最大データベース接続数 100
        "ReadLatency"|"WriteLatency") threshold=0.1 ;; # 読み取り/書き込みレイテンシしきい値 0.1秒
        *) threshold=1 ;; # デフォルトしきい値
    esac

    unit="None"

    # CloudWatchアラームを作成
    comparison_operator="GreaterThanThreshold"
    if [ "$metric" == "FreeableMemory" ]; then
        comparison_operator="LessThanThreshold"
    fi

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

    # アラーム作成の成功/失敗を確認
    if [ $? -eq 0 ]; then
        echo "✅ アラーム $alarm_name を作成しました。"
    else
        echo "❌ アラーム $alarm_name の作成に失敗しました。"
    fi
done

