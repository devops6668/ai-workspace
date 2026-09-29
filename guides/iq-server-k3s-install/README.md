# Sonatype IQ Server on K3s 安裝指南

## Table of Contents

- [Overview](#overview)
- [What is IQ Server](#what-is-iq-server)
- [What is H2 Database](#what-is-h2-database)
- [System Requirements](#system-requirements)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
  - [1. Create Namespace and PVC](#1-create-namespace-and-pvc)
  - [2. ConfigMap for config.yml](#2-configmap-for-configyml)
  - [3. Deployment and Service](#3-deployment-and-service)
  - [4. Deploy](#4-deploy)
  - [5. Verify](#5-verify)
- [Default Credentials](#default-credentials)
- [Production Recommendations](#production-recommendations)
- [References](#references)

---

## Overview

This guide documents the installation of **Sonatype IQ Server (Lifecycle)** on a K3s cluster, alongside an existing Nexus Repository 3.96.3-01 deployment.

Sonatype 提供 official Docker image `sonatype/nexus-iq-server`，支援 `linux/amd64` 同 `linux/arm64`，可直接用於 Kubernetes 部署。

> **Reference:** https://help.sonatype.com/en/install-self-hosted-iq-server.html

---

## What is IQ Server

Sonatype IQ Server（又稱 Nexus IQ Server / Sonatype Lifecycle）係一個軟件供應鏈安全平台：

- 掃描應用程式的依賴項（open source / third-party libraries）
- 偵測已知漏洞（CVE）、授權合規風險（license compliance）、質量問題
- 提供 SBOM（軟件物料清單）管理
- 與 CI/CD pipeline 整合（Jenkins、GitLab 等）

主要競爭對手：Snyk、Black Duck、GitHub Dependabot 等 SCA（Software Composition Analysis）工具。

---

## What is H2 Database

H2 係一個用 Java 寫嘅開源關database，IQ Server 內建：

| 特性 | 說明 |
|---|---|
| **類型** | 嵌入式（embedded），跑喺 IQ Server 自己嘅 JVM 入面 |
| **零配置** | 裝完即用，唔使額外裝 PostgreSQL |
| **內存模式** | 數據可以只存喺 RAM，超快但重啟冇咗 |
| **適合場景** | 測試 / 評估 / 少於 100 個應用程式 |

**Production 唔建議用 H2：**

| 問題 | 原因 |
|---|---|
| 性能差 | 大量掃描報告時 I/O 瓶頸嚴重 |
| 唔穩定 | K8s pod 重啟 / crash 可能整爛數據庫檔案 |
| 冇備份機制 | 冇 WAL、冇 replication |
| 單線程限制 | 高並發時會 lock 死 |

> Sonatype 文檔警告：We strongly advise against operating the IQ Server with an embedded database within container orchestration environments like Kubernetes. Doing so can lead to data corruption.

---

## System Requirements

| 項目 | 最低要求 | 建議 |
|---|---|---|
| CPU | 6 cores | 8+ cores |
| RAM | 6GB process space | 16GB+ |
| Disk | 500GB free | 1TB+ |
| Java | Java 25（IQ Server 204+） | 內建 JDK（bundle） |
| Network | 出 443 TCP 到 clm.sonatype.com | — |

**K3s 具體考慮：**
- IQ Server 需要 I/O 快嘅 disk，NFS 做 work directory 勉強可以（用 PostgreSQL 時支援 NFSv4.1）
- H2 用 local storage 會快好多
- 不建議喺 K8s 用 H2（見上）

---

## Prerequisites

- K3s cluster 已運行
- NFS CSI driver 已安裝（StorageClass: `nexus-csi`）
- Nexus Repository 已部署喺 `nexus` namespace
- 能出外網到 `clm.sonatype.com:443`
- 已準備好 IQ Server license（或 14 日免費試用）

---

## Installation

### 1. Create Namespace and PVC

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: iq-server
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: iq-data-pvc
  namespace: iq-server
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-csi
  resources:
    requests:
      storage: 50Gi
EOF
```

### 2. ConfigMap for config.yml

```bash
kubectl create configmap iq-config \
  --from-literal=config.yml='
baseUrl: http://iq-server:8070
sonatypeWork: /sonatype-work/clm-server
persistence:
  maxAge: 90
database:
  type: h2
  settings:
    dataDirectory: /sonatype-work/clm-server
' \
  -n iq-server
```

> Production 應改用 PostgreSQL，見 [Production Recommendations](#production-recommendations)。

### 3. Deployment and Service

```yaml
# iq-server-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: iq-server
  namespace: iq-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: iq-server
  template:
    metadata:
      labels:
        app: iq-server
    spec:
      containers:
        - name: iq-server
          image: sonatype/nexus-iq-server:latest
          ports:
            - containerPort: 8070
              name: http
            - containerPort: 8071
              name: admin
          env:
            - name: JAVA_OPTS
              value: "-Xms4g -Xmx4g -XX:+UseG1GC"
          volumeMounts:
            - name: iq-data
              mountPath: /sonatype-work
            - name: iq-config
              mountPath: /sonatype-work/clm-server/config.yml
              subPath: config.yml
          resources:
            requests:
              cpu: "4"
              memory: "8Gi"
            limits:
              cpu: "8"
              memory: "16Gi"
      volumes:
        - name: iq-data
          persistentVolumeClaim:
            claimName: iq-data-pvc
        - name: iq-config
          configMap:
            name: iq-config
---
apiVersion: v1
kind: Service
metadata:
  name: iq-server
  namespace: iq-server
spec:
  type: NodePort
  selector:
    app: iq-server
  ports:
    - port: 8070
      targetPort: 8070
      nodePort: 30070
      name: http
```

Save as `iq-server-deployment.yaml`.

### 4. Deploy

```bash
kubectl apply -f iq-server-deployment.yaml
```

### 5. Verify

```bash
# Wait for pod ready
kubectl get pods -n iq-server -w

# Check logs (success shows: Started SocketConnector@0.0.0.0:8070)
kubectl logs -n iq-server deployment/iq-server -f

# Access
curl http://<node-ip>:30070
# Default login: admin / admin123
```

---

## Default Credentials

| 用戶 | 密碼 |
|---|---|
| `admin` | `admin123` |

> 首次登入會要求修改密碼及輸入 License。

---

## Production Recommendations

| 項目 | 建議 |
|---|---|
| **Database** | 改用 PostgreSQL（至少 8 CPU, 32GB RAM） |
| **Storage** | IQ work directory 用 NFSv4.1 或 local SSD |
| **Service** | 設為 systemd service（非 H2 時 pod restart 唔怕） |
| **Port 8071** | 唔好用 LoadBalancer/Ingress 暴露，用 `kubectl port-forward` |
| **License** | 先申請 14 日免費試用，正式購買後輸入 |
| **Network** | 必須能出 443 TCP 到 `clm.sonatype.com` |

### 如果用 PostgreSQL

```yaml
database:
  type: postgresql
  settings:
    host: postgresql-service
    port: 5432
    name: iqserver
    user: iquser
    password: "${DATABASE_PASSWORD}"
```

---

## References

| 來源 | 連結 |
|---|---|
| IQ Server 安裝文檔 | https://help.sonatype.com/en/install-self-hosted-iq-server.html |
| 系統要求 | https://help.sonatype.com/en/system-requirements.html |
| 容器部署 | https://help.sonatype.com/en/container-deployments.html |
| 外部數據庫配置 | https://help.sonatype.com/en/external-database-configuration.html |
| Config YAML | https://help.sonatype.com/en/config-yaml.html |
| Docker Hub | https://hub.docker.com/r/sonatype/nexus-iq-server |
| HA 安裝 | https://help.sonatype.com/en/iq-server-high-availability-installation.html |
