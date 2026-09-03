========================================================
              pxctl 完整命令參考手冊
              Portworx Enterprise CLI
========================================================

目錄：
  1. 基本操作（Basics）
  2. Volume 管理
  3. Cluster 管理
  4. CloudSnap 備份/還原
  5. Cloud Credentials 憑證
  6. Alerts 告警
  7. Secrets 密鑰
  8. Auth 認證 & Role 角色
  9. CloudDrive 雲端磁碟
 10. CloudMigrate 遷移
 11. Scheduling Policy 排程策略
 12. Storage Policy 存儲策略
 13. Upgrade 升級
 14. License 授權
 15. Context 上下文
 16. Kubedatastore
 17. Service 服務
 18. EULA

========================================================
 1. 基本操作（Basics）
========================================================

pxctl --version                    查看版本
pxctl --help                       查看所有命令
pxctl status                       查看 Portworx 整體狀態
pxctl status --json                JSON 格式輸出

用 kubectl 執行 pxctl：
  PX_POD=$(kubectl get pods -l name=portworx -n <namespace> \
    -o jsonpath='{.items[0].metadata.name}')
  kubectl exec $PX_POD -n <namespace> -- /opt/pwx/bin/pxctl <command>

預設路徑：/opt/pwx/bin/pxctl
所有命令支援 --json 輸出 JSON 格式

========================================================
 2. Volume 管理
========================================================

【2.1 創建 Volume】
  pxctl volume create <name>
  pxctl volume create -s 100 myVol       # 100GB
  pxctl volume create -s 10 -r 3 myVol   # 10GB, 3副本
  pxctl volume create -s 10 -r 3 \
    --io_priority high myVol              # 高IO優先級
  pxctl volume create -s 10 -r 3 \
    --fs ext4 --fs_format_options "-i 8192" myVol
  pxctl volume create --nodes=LocalNode localVol  # 副本放本地節點
  pxctl volume create --shared myVol     # 共享卷
  pxctl volume create --sharedv4 myVol   # Sharedv4 卷
  pxctl volume create --secure myVol     # AES-256 加密
  pxctl volume create --secure \
    --secret_key mykey myVol             # 指定密鑰加密

  volume create 主要 flags：
    -s, --size          大小 (GB)，預設 1
    -r, --repl          副本數 1-3，預設 1
    --io_priority       high/medium/low
    --io_profile        db_remote/auto/none/journal/auto_journal
    --fs                ext4/xfs
    --shared            全局共享卷
    --sharedv4          Sharedv4 卷
    --sharedv4_service_type  ClusterIP
    --secure            AES-256 加密
    --secret_key        加密密鑰名
    --use_cluster_secret  使用集群密鑰
    --journal           啟用日誌
    --early_ack         異步寫確認
    --async_io          異步IO
    --nodiscard         禁用 discard
    --fastpath          啟用 fastpath IO
    --sticky            防刪除標記
    --nodes             指定節點
    --zones             指定可用區
    --racks             指定機架
    --label, -l         標籤 (key=value)
    --aggregation_level, -a  聚合等級 1/2/3/auto
    --block_size, -b    區塊大小，預設 4096
    --queue_depth, -q   佇列深度 1-256，預設 128
    --scale             自動擴展上限 1-1024
    --periodic, -p      定期快照 interval mins,k
    --daily, -d         每日快照 hh:mm,k
    --weekly, -w        每週快照 weekday@hh:mm,k
    --monthly, -m       每月快照 day@hh:mm,k
    --mount_options     掛載選項 key=value
    --storagepolicy     存儲策略名
    --max_iops          最大 IOPS ReadIOPS,WriteIOPS
    --max_bandwidth     最大帶寬 MB/s
    --readahead         預讀

【2.2 列出 Volume】
  pxctl volume list                    列出所有
  pxctl volume list --all              包含快照
  pxctl volume list --name myVol       按名稱過濾
  pxctl volume list --node <nodeID>    按節點過濾
  pxctl volume list --snapshot         只顯示快照
  pxctl volume list --volumes          只顯示卷（不含快照）
  pxctl volume list --group <groupID>  按組過濾
  pxctl volume list --label color=blue 按標籤過濾
  pxctl volume list --trashcan         回收站中的卷
  pxctl volume list --time             按創建時間排序
  pxctl volume list --cloud-drive-id <id>  按雲端磁碟過濾
  pxctl volume list --pool-uid <uid>   按存儲池過濾
  pxctl volume list --parent <volID>   某卷的所有快照

【2.3 查看 Volume 詳情】
  pxctl volume inspect <volID/name>

【2.4 刪除 Volume】
  pxctl volume delete <volID/name>
  pxctl volume delete myVol            # 會確認 Y/N

【2.5 更新 Volume】
  pxctl volume update <volName> --size=5           # 擴容到 5GB
  pxctl volume update <volName> --sharedv4=on      # 啟用 sharedv4
  pxctl volume update <volName> --sharedv4=off     # 關閉 sharedv4
  pxctl volume update <volName> --sticky=on        # 啟用防刪
  pxctl volume update <volName> --sticky=off       # 關閉防刪
  pxctl volume update <volName> --io_priority high # 設IO優先級
  pxctl volume update <volName> --io_profile db    # 設IO Profile
  pxctl volume update <volName> --label "color=red"  # 更新標籤
  pxctl volume update <volName> --group <groupName>  # 設組
  pxctl volume update <volName> --sharedv4_failover_strategy=normal
  pxctl volume update <volName> --sharedv4_mount_options "ro"
  pxctl volume update <volName> --max_iops 1000,1000
  pxctl volume update <volName> --max_bandwidth 200,200
  pxctl volume update <volName> --readahead on
  pxctl volume update <volName> --fastpath
  pxctl volume update <volName> --cow_ondemand on
  pxctl volume update <volName> --async_io on
  pxctl volume update <volName> --nodiscard on
  pxctl volume update <volName> --journal on
  pxctl volume update <volName> --queue_depth 256

  注意：擴容必須先 attach volume：
    pxctl host attach <volName>
    pxctl host mount --path /mnt/vol <volName>
    pxctl volume update <volName> --size=5

【2.6 更新副本數 (HA)】
  # 增加副本（必須+1）
  pxctl volume ha-update --repl=2 \
    --node <nodeID/poolUUID/nodeIP> <volName>
  # 減少副本（必須-1）
  pxctl volume ha-update --repl=1 \
    --node <nodeID/poolUUID/nodeIP> <volName>
  # 取消操作
  pxctl volume ha-update --cancel <volName>
  # 指定源節點
  pxctl volume ha-update --repl=2 \
    --node <targetNode> --sources <sourceNode> <volName>
  # 指定可用區/機架
  pxctl volume ha-update --repl=2 --zones zone1 <volName>
  pxctl volume ha-update --repl=2 --racks rack1 <volName>

  最大副本數 = 3

【2.7 快照】
  pxctl volume snapshot create \
    --name mysnap --label color=blue <volName>
  # 從快照還原（volume必須detach）
  pxctl volume restore --snapshot mysnap <volName>
  # 從回收站還原
  pxctl volume restore --trashcan trashedvol <volName>
  # 更新快照間隔
  pxctl volume snap-interval-update \
    --periodic 60,5 <volName>         # 每60分鐘，保留5個
  pxctl volume snap-interval-update \
    --daily 00:00,7 <volName>         # 每日零時，保留7個

  每卷最多 64 個快照，快照為只讀。

【2.8 克隆】
  pxctl volume clone -name myvol_clone myvol

【2.9 匯入】
  pxctl volume import --src /path/to/files myVol

【2.10 統計】
  pxctl volume stats <volName>         即時IO統計
  pxctl volume usage <volName>         使用量

【2.11 定位】
  pxctl volume locate <volID>          查看掛載位置

【2.12 Volume存取規則】
  pxctl volume access show <volName>
  pxctl volume access add <volName> --group group1:r
  pxctl volume access add <volName> --collaborator user1Id:w
  pxctl volume access add <volName> --public r
  pxctl volume access remove <volName> --collaborator user1Id
  pxctl volume access update <volName> \
    --groups group1:r,group2:w --collaborators user1Id:a

【2.13 檔案系統檢查】
  pxctl volume check start --mode fix_safe <volName>
  pxctl volume check start --mode check_health <volName>
  pxctl volume check start --mode fix_all <volName>
  pxctl volume check stop <volName>
  pxctl volume check status <volName>

【2.14 Trim / Auto-fstrim】
  pxctl volume trim start <volName>
  pxctl volume trim stop <volName>
  pxctl volume trim status <volName>
  pxctl volume trim usage <volName>
  pxctl volume autofstrim status <volName>
  pxctl volume autofstrim usage
  pxctl volume autofstrim push <volName>
  pxctl volume autofstrim pop <volName>

【2.15 Checksum驗證】
  pxctl volume verify-checksum start <volName>
  pxctl volume verify-checksum stop <volName>
  pxctl volume verify-checksum status <volName>

【2.16 掛載/卸載（Docker模式）】
  pxctl host attach <volName>
  pxctl host detach <volName>
  pxctl host mount --path /mount/path <volName>
  pxctl host unmount /mount/path

========================================================
 3. Cluster 管理
========================================================

【3.1 節點列表】
  pxctl cluster list

【3.2 節點詳情】
  pxctl cluster inspect <nodeID>

【3.3 刪除節點】
  pxctl cluster delete <nodeID>
  pxctl cluster delete --force <nodeID>  # 強制（可能丟數據）

【3.4 Cluster Domains（Metro DR）】
  pxctl cluster domains show
  pxctl cluster domains activate --name <domain>
  pxctl cluster domains deactivate --name <domain>

【3.5 配置狀態】
  pxctl cluster provision-status

【3.6 Token管理】
  pxctl cluster token show             顯示認證token
  pxctl cluster token reset            重設token

【3.7 Cluster Pair（跨集群配對）】
  pxctl cluster pair create \
    --ip <remoteIP> --token <token> --default
  pxctl cluster pair create \
    --ip <remoteIP> --token <token> --dr-mode
  pxctl cluster pair list
  pxctl cluster pair validate --id <pairID>
  pxctl cluster pair delete --id <pairID>

【3.8 Cluster Options（全域設定）】
  pxctl cluster options list           列出所有選項
  pxctl cluster options update         更新選項

  常用選項：
    --auto-decommission-timeout     自動退役超時（分鐘），預設20
    --internal-snapshot-interval    內部快照間隔（分鐘），預設30
    --snapshot-create-timeout       快照超時（分鐘），預設20
    --default-rpc-timeout           RPC超時（分鐘），預設5
    --repl-move-timeout             副本移動超時（分鐘），預設1440
    --license-expiry-check          授權到期提醒（天），預設7
    --cloudsnap-max-threads         雲端快照執行緒數，預設16
    --cloudsnap-err-retry-limit     雲端快照重試次數，預設3
    --sharedv4-threads              Sharedv4執行緒數，預設128
    --max-sharedv4-threads          Sharedv4最大執行緒，預設2048
    --sharedv4-mount-timeout-sec    Sharedv4掛載超時（秒），預設120
    --sharedv4-attachment-limit     Sharedv4最大掛載數，預設256
    --cache-flush                   快取刷新 enabled/disabled
    --cache-flush-seconds           快取刷新間隔（秒），預設30
    --auto-fstrim                   自動fstrim on/off
    --fstrim-schedule-start         fstrim排程 daily=hh:mm
    --fstrim-schedule-duration      fstrim持續時間（小時）
    --fstrim-max-io-rate            fstrim最大IO速率，預設32MiB
    --fstrim-min-io-rate            fstrim最小IO速率，預設1MiB
    --defrag-schedule-chunk-size    重整區塊大小（MB），預設32
    --skinnysnap                    精簡快照 on/off
    --skinnysnap-num-repls          精簡快照副本數，預設1
    --cloud-drive-locking           雲端磁碟鎖定 true/false
    --pause-pool-failovers          暫停池故障轉移 true/false
    --pause-dynamic-pool-rebalance  暫停動態池均衡 true/false
    --volume-expiration-minutes     回收站過期時間（分鐘）
    --diag-redaction-enabled        診斷脫敏 on/off

【3.9 重整（Defrag）排程】
  pxctl cluster defrag schedule create \
    --start-time daily=19:15 \
    --max-duration-minutes 90
  pxctl cluster defrag schedule show
  pxctl cluster defrag schedule delete <scheduleID>
  pxctl cluster defrag schedule clean-up
  pxctl cluster defrag status --node <nodeUUID>

  defrag schedule flags：
    --start-time             排程時間 daily/weekly/monthly
    --max-duration-minutes   持續時間（分鐘）
    --max-nodes-in-parallel  最大並行節點數，預設1
    --include-nodes          指定節點
    --exclude-nodes          排除節點
    --node-selector          節點標籤選擇器
    --one-iteration-only     運行一次後自動刪除
    --include-volumes        指定卷
    --exclude-volumes        排除卷

========================================================
 4. CloudSnap 備份/還原
========================================================

【4.1 備份到雲端】
  pxctl cloudsnap backup <volName>
  pxctl cloudsnap backup --full <volName>         # 強制全量
  pxctl cloudsnap backup --delete-local <volName> # 備份後刪本地快照
  pxctl cloudsnap backup --cred-id <credID> <volName>
  pxctl cloudsnap backup --label "env=prod" <volName>
  pxctl cloudsnap backup --frequency 7 <volName>  # 增量7次後全量

【4.2 批量備份】
  pxctl cloudsnap backup-group \
    --volume_ids "vol1,vol2,vol3"
  pxctl cloudsnap backup-group --group <groupID>
  pxctl cloudsnap backup-group --label "env=prod"

【4.3 從雲端還原】
  pxctl cloudsnap restore \
    --volume <newVolName> --snap <cloudsnapID>
  pxctl cloudsnap restore --repl 3 \
    --io_priority high --volume <vol> --snap <snapID>
  pxctl cloudsnap restore --cred-id <credID> \
    --volume <vol> --snap <snapID>
  pxctl cloudsnap restore --nodes <nodeID> \
    --zones <zone> --racks <rack> \
    --volume <vol> --snap <snapID>
  pxctl cloudsnap restore --sharedv4 \
    --volume <vol> --snap <snapID>
  pxctl cloudsnap restore \
    --match_src_vol_provisioning \
    --volume <vol> --snap <snapID>

【4.4 列出雲端備份】
  pxctl cloudsnap list
  pxctl cloudsnap list --src <volName>   # 某卷的備份
  pxctl cloudsnap list --all             # 所有集群
  pxctl cloudsnap list --deleted-source-vol  # 已刪除卷的備份
  pxctl cloudsnap list --status failed   # 失敗的備份
  pxctl cloudsnap list --paginate        # 分頁顯示
  pxctl cloudsnap list --cloudsnap-id <id>

【4.5 備份狀態】
  pxctl cloudsnap status
  pxctl cloudsnap status --name <taskName>
  pxctl cloudsnap status --src <volName>
  pxctl cloudsnap status --local         # 節點本地

【4.6 備份歷史】
  pxctl cloudsnap history
  pxctl cloudsnap history --src <volName>

【4.7 停止備份】
  pxctl cloudsnap stop --name <taskName>

【4.8 刪除雲端備份】
  pxctl cloudsnap delete --snap <cloudsnapID>
  pxctl cloudsnap delete --snap <id> --cred-id <credID>

【4.9 備份目錄】
  pxctl cloudsnap catalog --snap <cloudsnapID>

【4.10 備份排程】
  pxctl cloudsnap schedules create \
    --periodic 60 --max 7 --retention 30 \
    --cred-id <credID> <volName>
  pxctl cloudsnap schedules create \
    --daily 00:00 --weekly Sunday@00:00 \
    --monthly 1@00:00 <volName>
  pxctl cloudsnap schedules list
  pxctl cloudsnap schedules update \
    -i <uuid> --periodic 120 --max 14
  pxctl cloudsnap schedules delete --uuid <uuid>

========================================================
 5. Cloud Credentials 憑證
========================================================

  pxctl credentials list                    列出所有憑證
  pxctl credentials validate <uuid/name>    驗證憑證
  pxctl credentials delete <uuid/name>      刪除憑證
  pxctl credentials delete-refs <name>      清理KVDB殘留引用

  # AWS S3（Access Key）
  pxctl credentials create \
    --provider s3 \
    --s3-access-key <KEY> \
    --s3-secret-key <SECRET> \
    --s3-region us-east-1 \
    --s3-endpoint s3.amazonaws.com \
    --s3-storage-class STANDARD \
    --bucket <BUCKET> \
    <NAME>

  # AWS S3（IAM）
  pxctl credentials create \
    --provider s3 \
    --s3-region us-east-1 \
    --s3-storage-class STANDARD \
    --use-iam \
    <NAME>

  # AWS S3（SSE加密）
  pxctl credentials create \
    --provider s3 \
    --s3-access-key <KEY> \
    --s3-secret-key <SECRET> \
    --s3-region us-east-1 \
    --s3-sse AES256 \
    <NAME>

  # Azure
  pxctl credentials create \
    --provider azure \
    --azure-account-name <ACCOUNT> \
    --azure-account-key <KEY> \
    <NAME>

  # Google Cloud
  pxctl credentials create \
    --provider google \
    --google-project-id <PROJECT> \
    --google-json-key-file /path/to/gcloud.json \
    --bucket <BUCKET> \
    <NAME>

  # Workload Identity (v3.4+)
  pxctl credentials create <name> \
    --provider <provider> \
    --use-workload-identity

========================================================
 6. Alerts 告警
========================================================

  pxctl alerts show                       顯示所有告警
  pxctl alerts show --type volume         Volume類型
  pxctl alerts show --type node           節點類型
  pxctl alerts show --type cluster        集群類型
  pxctl alerts show --type drive          磁碟類型
  pxctl alerts show --type pool           存儲池類型
  pxctl alerts show --type all            全部
  pxctl alerts show --severity alarm      最低嚴重性
  pxctl alerts show --severity warn       警告以上
  pxctl alerts show --id <alertID>        按ID
  pxctl alerts show --resource <name>     按資源
  pxctl alerts show --is-cleared false    未清除的
  pxctl alerts show --start-time 2024-01-01T00:00:00Z
  pxctl alerts show --end-time 2024-01-31T23:59:59Z
  pxctl alerts show --out alerts.csv      輸出到CSV

  pxctl alerts purge                      清除告警
  pxctl alerts purge --type volume -y     自動確認
  pxctl alerts info                       告警資訊

========================================================
 7. Secrets 密鑰管理
========================================================

  # Vault 認證
  pxctl secrets vault login \
    --vault-address http://myvault.com \
    --vault-token <token>

  # AWS KMS 認證
  pxctl secrets aws login
  # 互動式輸入：
  #   AWS_ACCESS_KEY_ID
  #   AWS_SECRET_ACCESS_KEY
  #   AWS_SECRET_TOKEN_KEY
  #   AWS_CMK
  #   AWS_REGION

  # KVDB（預設）
  pxctl secrets kvdb login

========================================================
 8. Auth 認證 & Role 角色
========================================================

  # 登入
  pxctl auth login --cred <credID>

  # 角色管理
  pxctl role create <roleName>
  pxctl role delete <roleName>
  pxctl role list
  pxctl role inspect <roleName>

========================================================
 9. CloudDrive 雲端磁碟
========================================================

  pxctl clouddrive list                    列出雲端磁碟
  pxctl clouddrive inspect <driveID>       磁碟詳情

========================================================
 10. CloudMigrate 遷移
========================================================

  # 開始遷移
  pxctl cloudmigrate start \
    --volume <volID> --target-cluster <clusterID>
  pxctl cloudmigrate start \
    --volume <volID> --target-cred <credID>

  # 查看遷移狀態
  pxctl cloudmigrate status
  pxctl cloudmigrate status --volume <volID>

  # 停止遷移
  pxctl cloudmigrate stop --volume <volID>

========================================================
 11. Scheduling Policy 排程策略
========================================================

  pxctl sched-policy list
  pxctl sched-policy inspect <policyName>

========================================================
 12. Storage Policy 存儲策略
========================================================

  pxctl storage-policy list
  pxctl storage-policy inspect <policyName>

========================================================
 13. Upgrade 升級
========================================================

  pxctl upgrade --tag <version> <containerName>
  # 例：pxctl upgrade --tag 1.1.6 my-px-enterprise

  建議逐節點升級，保持仲裁和IO連續性。

========================================================
 14. License 授權
========================================================

  pxctl license show                      顯示授權
  pxctl license update <licenseKey>       更新授權

========================================================
 15. Context 上下文
========================================================

  # 管理多集群認證上下文
  pxctl context list
  pxctl context set <contextName>
  pxctl context delete <contextName>

========================================================
 16. Kubedatastore
========================================================

  # 管理 Kubernetes 作為 datastore
  pxctl kubedatastore set
  pxctl kubedatastore status

========================================================
 17. Service 服務
========================================================

  pxctl service restart                   重啟服務
  pxctl service status                    服務狀態

========================================================
 18. EULA
========================================================

  pxctl eula                              顯示EULA链接

========================================================
                常用場景速查
========================================================

【日常檢查流程】
  1. pxctl status                         整體健康
  2. pxctl cluster list                   節點狀態
  3. pxctl volume list                    卷狀態
  4. pxctl alerts show --type all         告警
  5. pxctl cloudsnap status               備份進度

【創建加密高可用卷】
  pxctl volume create -s 100 -r 3 \
    --io_priority high --secure \
    --secret_key mykey --fs ext4 \
    --label "app=mysql,env=prod" mysql-data

【自動備份排程】
  pxctl cloudsnap schedules create \
    --periodic 60,5 \
    --daily 00:00,7 \
    --weekly Sunday@00:00,4 \
    --monthly 1@00:00,12 \
    --cred-id <credID> mysql-data

【跨集群遷移】
  1. pxctl cluster pair create \
       --ip <remoteIP> --token <token> --default
  2. pxctl cloudmigrate start \
       --volume <volID> --target-cluster <clusterID>
  3. pxctl cloudmigrate status

【故障排查】
  pxctl alerts show --type all --severity warn
  pxctl volume inspect <problemVol>
  pxctl volume stats <problemVol>
  pxctl cluster inspect <nodeID>

========================================================
  官方文檔：https://docs.portworx.com/portworx-enterprise/reference/cli/pxctl-reference
========================================================
