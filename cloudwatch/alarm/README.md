# CloudWatchアラーム作成スクリプトについて
cloudwatch/alarm以下にはよく使用するCloudWatchアラームの設定をシェル形式で実行可能なスクリプトを開発しています。
現状で対応しているリソースは以下の通りです。
- ALB
- CloudFront
- EC2
- RDS

# 利用の前提条件
- CloudWatchメトリクスが取得可能な状態であること
- アラームを通知するSNSトピックが作成されていること

# その他
バグ報告や修正の要望等ございましたら下記にてご連絡ください。
https://zenn.dev/satom/scraps/e69078ec2c36f0