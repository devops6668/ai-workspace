# Nutanix UI Extension for Rancher — 歸檔筆記

> 整理日期：2026-08-27
> 來源：[nutanix-rancher-extension (GitHub)](https://github.com/nutanix-cloud-native/nutanix-rancher-extension)

---

## 概覽

Nutanix UI Extension 係 Nutanix 官方出嘅 Rancher Dashboard 擴展，用於喺 Rancher 入面直接管理 Nutanix 雲平台上嘅 Kubernetes 集群。裝完之後，唔使手動開 VM 或者填一堆參數，喺 Rancher UI 一鍵式部署 RKE2 cluster。

---

## 核心功能

| 功能 | 說明 |
|------|------|
| 直接連接 Prism Central | 自動發現 Nutanix 資源 |
| 下拉選單自動填充 | Projects、Clusters、Networks、Images、Categories、Storage Containers |
| Rancher Node Driver 整合 | 自動透過 AHV 開 VM 裝 K8s |
| 簡化 Cluster 建立流程 | 減少人手配置錯誤 |

---

## 前提條件

| 項目 | 最低版本 |
|------|----------|
| Nutanix Prism Central | 2024.3+ |
| Nutanix Rancher Node Driver | v3.6.0+ |
| Rancher | 2.11.8+（支援範圍見下表） |

### Rancher 版本兼容矩陣

| Rancher Branch | 支援版本範圍 | 狀態 |
|----------------|-------------|------|
| v2.13 | >= 2.13.1 | ✅ 支援 |
| v2.12 | 2.12.5 — 2.12.7 | ✅ 支援 |
| v2.11 | 2.11.8 — 2.11.11 | ✅ 支援 |
| Legacy | < 2.11.8 | ❌ 不支援 |

---

## 安裝步驟

### 方法一：從 Rancher Partner Extension Catalog 安裝（推薦）

1. Rancher UI > 左上角漢堡 Menu > **Configuration > Extensions**
2. 右上角三點 > **Manage Extension Catalogs**
3. 點 **Import Extension Catalog**
4. 輸入 Nutanix Helm repo URL：
   ```
   https://nutanix.github.io/nutanix-rancher-extension/
   ```
5. 去 **Available** tab，搵到 Nutanix Extension，點 **Install**
6. 選擇版本，確認安裝

### 方法二：手動加 Helm Repository

如果 Extension Catalog 方式唔 work，可以手動加：

```bash
helm repo add nutanix-extension https://nutanix.github.io/nutanix-rancher-extension/
helm repo update
```

然後喺 Rancher UI > Apps > Repositories 加入同一個 URL。

---

## 實際操作流程

安裝完 Extension + Node Driver 之後，建立 cluster 嘅流程：

```
1. Rancher UI > Cluster Management > Create
2. 揀 Nutanix 作為 Cloud Provider
3. 填 Prism Central IP + Credentials
4. Extension 自動連接 Prism Central API
5. 下拉選單自動列出 Nutanix 資源：
   ├── Projects
   ├── Clusters (Nutanix 折群)
   ├── Networks
   ├── Images (VM templates)
   ├── Storage Containers
   └── Categories
6. 揀好資源，設定 K8s 版本同 node 數量
7. Rancher 透過 Node Driver 指令 Prism Central 自動開 VM
8. VM 開好後自動裝 RKE2
9. 裝完自動 register 返 Rancher
```

### 講白啲

冇呢個 Extension → 手動去 Prism Central 開 VM → 裝 K8s → register 返 Rancher

有呢個 Extension → Rancher UI 一鍵搞定，自動開 VM + 裝 K8s + register

---

## 技術架構

```
Rancher Dashboard (UI)
        │
        ├── Nutanix UI Extension (Vue.js plugin)
        │       │
        │       └── Prism Central API (直接通訊)
        │               │
        │               ├── 自動發現資源
        │               └── 提供下拉選單數據
        │
        └── Nutanix Node Driver (AHV)
                │
                └── 自動開 VM + 裝 RKE2
```

---

## 注意事項

1. **需要 Nutanix 底層**：呢個 Extension 係 Nutanix 私有雲場景先用到，冇 Nutanix 基礎設施就用唔到
2. **Node Driver 要另外裝**：Extension 負責 UI，Node Driver 負責實際開 VM 操作
3. **Prism Central 權限**：Rancher 需要有 Prism Central 嘅 API 權限先可以操控資源
4. **網絡要求**：Rancher server 要可以訪問 Prism Central API endpoint

---

## 相關連結

- GitHub repo: https://github.com/nutanix-cloud-native/nutanix-rancher-extension
- Rancher Extensions 官方文件: https://extensions.rancher.io/
- Nutanix Portal 文件: https://portal.nutanix.com/

---

## 與其他 Rancher Extension 比較

| Extension | 用途 | 場景 |
|-----------|------|------|
| Nutanix UI Extension | Nutanix 雲平台整合 | Nutanix 私有雲 |
| Krum Rancher Extensions | App Launcher + i18n | 通用，方便訪問 k8s 應用 |
| Elemental | OS 管理 | Edge / bare metal |

---

## 總結

Nutanix UI Extension 係 Rancher + Nutanix 嘅 bridging UI，主要作用：

1. **減少配置時間**：自動發現 Nutanix 資源
2. **減少人手錯誤**：下拉選單代替手動輸入
3. **一鍵部署**：從 Rancher UI 直接開 VM + 裝 K8s
4. **提高可見性**：直接喺 Rancher 睇到 Nutanix 資源

你而家用嘅 K3s 係 bare metal / VM 上面裝嘅，呢個 Extension 係 Nutanix 私有雲場景先用到。如果公司冇 Nutanix，呢個 Extension 只係參考價值。
