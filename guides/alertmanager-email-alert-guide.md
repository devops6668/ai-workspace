# AlertManager Email Alert 設置指南

> Rancher Monitoring (v0.80.1) + Prometheus Operator + Gmail SMTP
> 更新日期：2026-08-07

## 架構概覽

```
Prometheus → AlertManager → Gmail SMTP → Email
```

- Prometheus: 觸發 alert rules
- AlertManager: 路由、分組、抑制、通知
- Gmail SMTP: 實際 send email

## 核心概念

### 三個 CRD 嘅關係

| CRD | 作用 | Namespace |
|-----|------|-----------|
| `alertmanagers.monitoring.coreos.com` | AlertManager 實例配置 | cattle-monitoring-system |
| `alertmanagerconfigs.monitoring.coreos.com` | Route + Receiver 配置 | 同 AlertManager 或所有 ns |
| `prometheusrules.monitoring.coreos.com` | Alert Rules 定義 | 任意 ns |

### Routing Tree

```
Root Route (所有 alert 嘅入口)
├── Route-0: severity=warning|critical → Email
├── Route-1: InfoInhibitor/Watchdog → null (不通知)
└── Fallback: null receiver
```

### Matchers 類型

- 等式：`label="value"` 或 `label!="value"`
- 正則：`label=~"regex"` 或 `label!~"regex"`

### Grouping 參數

| 參數 | 作用 | 預設值 |
|------|------|--------|
| `group_wait` | 新 group 出現後等幾耐先 send 第一次 | 30s |
| `group_interval` | 同 group 兩次 notification 之間嘅間隔 | 5m |
| `repeat_interval` | 同 alert 重複提醒嘅間隔 | 4h |

### Inhibit Rules

- critical 同 alertname 相同 → 抑制 warning
- warning 同 alertname 相同 → 抑制 info
- InfoInhibitor/Watchdog → 被抑制（null receiver）

## 關鍵配置

### 1. Alertmanager CRD

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Alertmanager
metadata:
  name: rancher-monitoring-alertmanager
  namespace: cattle-monitoring-system
spec:
  alertmanagerConfigMatcherStrategy:
    type: None    # 關鍵：設為 None 先唔會自動加 namespace matcher
                  # 預設 OnNamespace 會限制到 CRD 自己嘅 namespace
```

### 2. AlertmanagerConfig CRD

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: paul
  namespace: cattle-monitoring-system  # 必須同 AlertManager 同 ns
spec:
  receivers:
  - emailConfigs:
    - authPassword:
        key: password
        name: google-password
      authUsername: wwit888@gmail.com
      from: wwit888@gmail.com
      requireTLS: true
      sendResolved: true
      smarthost: smtp.gmail.com:587
      tlsConfig: {}
      to: wwit888@gmail.com
    name: alert
  route:
    receiver: alert
    groupBy: ['namespace', 'alertname']
    groupInterval: 5m
    groupWait: 30s
    matchers:
    - matchType: =~
      name: severity
      value: warning|critical
    repeatInterval: 10m
```

### 3. Gmail App Password Secret

```bash
kubectl create secret generic google-password \
  -n cattle-monitoring-system \
  --from-literal=password=xxxx-xxxx-xxxx-xxxx
```

### 4. PVC Usage Alert (80%)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: pvc-usage-alert
  namespace: cattle-monitoring-system
  labels:
    app: rancher-monitoring
    release: rancher-monitoring
spec:
  groups:
  - name: pvc-usage
    rules:
    - alert: PVCUsageHigh
      annotations:
        summary: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} usage is above 80%"
        description: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is using {{ $value | humanize }}% of its capacity on cluster {{ $labels.cluster }}."
      expr: |
        (kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100 >= 80
      for: 5m
      labels:
        severity: warning
```

## 常見 Pitfalls

### 1. Namespace 限制問題

**問題：** AlertmanagerConfig 嘅 route 只 match 自己 namespace 嘅 alert

**原因：** `alertmanagerConfigMatcherStrategy` 預設為 `OnNamespace`，Operator 會自動加 `namespace="xxx"` matcher

**解決：** 設為 `None`
```yaml
spec:
  alertmanagerConfigMatcherStrategy:
    type: None
```

### 2. Double Send 問題

**問題：** 同一個 alert send 兩次 email

**原因：** 多個 AlertmanagerConfig 有相同嘅 severity matcher，且都有 `continue: true`

**解決：** 只保留一個 AlertmanagerConfig for email

### 3. Group_by 空值問題

**問題：** Alert 冇分組，每個 alert 都獨立 send

**原因：** `groupBy: []` 等於用所有 label 分組

**解決：** 設定 `groupBy: ['namespace', 'alertname']`

### 4. Rancher UI 顯示問題

**問題：** Rancher UI 顯示 Route/Receiver ConfiguredReceiver = null

**原因：** Rancher 有自己嘅 Route/Receiver CRD（已棄用），同 AlertmanagerConfig 分開

**解決：** 唔理 Rancher UI 嘅顯示，以 AlertManager config 為準

## 驗證命令

```bash
# 查看 generated config
kubectl get secret alertmanager-rancher-monitoring-alertmanager-generated \
  -n cattle-monitoring-system \
  -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip

# 查看 active alerts
kubectl exec -n cattle-monitoring-system alertmanager-rancher-monitoring-alertmanager-0 \
  -c alertmanager -- wget -qO- http://localhost:9093/api/v2/alerts | python3 -m json.tool

# 查看 PVC usage
kubectl exec -n cattle-monitoring-system alertmanager-rancher-monitoring-alertmanager-0 \
  -c alertmanager -- wget -qO- 'http://rancher-monitoring-prometheus:9090/api/v1/query?query=(kubelet_volume_stats_used_bytes%20/%20kubelet_volume_stats_capacity_bytes)%20*%20100' | python3 -m json.tool

# 查看 AlertmanagerConfig
kubectl get alertmanagerconfig -A
kubectl get alertmanager -n cattle-monitoring-system -o yaml | grep -A3 matcherStrategy

# 查看 PrometheusRule
kubectl get prometheusrule -A
```

## 環境資訊

- K3s: 192.168.89.61, K8s v1.33.0
- Rancher Monitoring: v0.80.1 (chart 107.2.3)
- AlertManager: v0.28.1
- Prometheus Operator: v0.80.1
- Gmail: wwit888@gmail.com (App Password)
