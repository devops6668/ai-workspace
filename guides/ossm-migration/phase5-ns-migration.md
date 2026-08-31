    腳本已寫好：

    /home/devops/Documents/ossm2_to_ossm3/migrate_workload_namespaces.sh

    功能概要

    這個腳本自動化了 Phase 5 的所有步驟：

    1. Preflight checks — 驗證 oc login、istioctl、activeRevision、Istio 狀態、namespace 是否存在
    2. 逐 namespace 遷移（project-01 → project-02 → project-03 → project-04 → devops）：
       - 打上 istio.io/rev=<revision>、maistra.io/ignore-namespace=true、service-mesh=enabled 標籤
       - 移除舊的 istio-injection 標籤
       - oc rollout restart deployment 重啟所有部署
       - 等待每個 deployment rollout 完成（300s timeout）
       - 用 istioctl ps 驗證 proxy 已連接到 OSSM 3
       - curl 測試每個 host 的 HTTP 狀態碼
    3. 最終驗證 — 確認沒有剩餘 OSSM 2 proxy，列出所有 OSSM 3 proxy

    用法

    bash
    Dry run（只看不執行）
    ./migrate_workload_namespaces.sh --dry-run

    遷移特定 namespace
    ./migrate_workload_namespaces.sh --namespace project-01

    正式執行（跳過確認）
    ./migrate_workload_namespaces.sh --yes

    完整執行
    ./migrate_workload_namespaces.sh


    注意事項

    - 腳本會自動偵測 activeRevision，也可以透過 ACTIVE_REVISION=basic-v1-24-3 環境變數覆蓋
    - 每個 namespace 之間有 10 秒間隔
    - devops namespace 的 deployment 列表已根據實際叢體調整（包含 dind、gitops-cli 等）
    - 如果某個 namespace 有未預期的 deployment，腳本會 fallback 到該 namespace 下的所有 deployment

---
    已更新。主要改動：

    1. Namespace 來源改為動態發現 — 預設從 ServiceMeshMemberRoll 讀取所有 member namespace，也可以手動指定：
       bash
    全部遷移（自動從 SMR 讀取）
       ./migrate_workload_namespaces.sh

    只遷移指定的
       ./migrate_workload_namespaces.sh project-01 project-02

    dry run
       ./migrate_workload_namespaces.sh --dry-run


    2. Deployment 也是動態獲取 — 用 oc get deployments -n <ns> 自動列出，不再 hardcode

    3. Connectivity test 自動推斷 — 根據 deployment name 推斷 hostname（hello-world1 → hello-world1.devops.local），跳過 curl、dotnet、dind 等基礎設施 deployment。可透過 HOST_SUFFIX 環境變數調整網域：
       bash
       HOST_SUFFIX=.example.com ./migrate_workload_namespaces.sh


    4. 可跳過空 namespace — SKIP_EMPTY=yes（預設）會跳過沒有 deployment 的 namespace（如 test）

    5. 所有環境變數可覆蓋：
       - ACTIVE_REVISION — 覆寫 revision
       - ISTIO_NS — 預設 istio-system
       - HOST_SUFFIX — 預設 .devops.local
       - SKIP_EMPTY — 預設 yes

