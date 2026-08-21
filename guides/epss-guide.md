🛡️ EPSS (Exploit Prediction Scoring System) 深度指南
Exploit Prediction Scoring System — 漏洞被利用概率預測系統

---

1️⃣ 問題背景：點解需要 EPSS？

每年 CVE 數量爆表（2024 年已超 2 萬個），但企業真正會修嘅只有 5-20%。
核心問題：邊啲漏洞要先修？

```
傳統做法（CVSS 為主）：
  CVSS >= 7.0 → 當高危 → 全部修
  ↓
  但 CVSS 高危漏洞中，只有 2-7% 真正被 exploit 過
  ↓
  結果：花大量時間修緊 93-98% 根本唔會有人用嘅漏洞
```

---

2️⃣ EPSS 係乜？

EPSS 由 FIRST（Forum of Incident Response and Security Teams）主導，
2019 年開始，一個開放社區驅動嘅概率評分系統。

核心問題唔同：
- CVSS 問：「如果被 exploit，破壞力幾大？」→ 嚴重程度
- EPSS 問：「呢個漏洞會唔會被 exploit？」→ 被利用概率

每個 CVE 攞到 0-1 之內一個分數（0%-100%），代表未來 30 日被利用嘅概率。

---

3️⃣ 模型架構：1,100+ 變數

EPSS 用 Bayesian approach，基於以下特徵：

```
┌─────────────────────────────────────────────────────┐
│                  EPSS 模型輸入                       │
├─────────────────────────────────────────────────────┤
│                                                     │
│  ① 漏洞自身特徵                                      │
│     - CVSS 分數、攻擊向量（network/local）              │
│     - 漏洞類型（buffer overflow、RCE、SQLi 等）        │
│     - 受影響組件類型（OS kernel、web server 等）       │
│                                                     │
│  ② 環境因素                                          │
│     - 組件流行度（nginx vs 冷門 library）              │
│     - 廠商 patch 狀態、公開咗幾耐                      │
│                                                     │
│  ③ 威脅情報                                          │
│     - 有冇已知 exploit code（Metasploit、ExploitDB）   │
│     - Dark web / underground forum 討論              │
│     - APT group 使用情況                              │
│     - Honeypot / IDS 實際觀測                         │
│                                                     │
│  ④ 歷史模式                                          │
│     - 類似漏洞過去被利用嘅機率                         │
│     - 呢類型 CVE 幾耐出 exploit                       │
│                                                     │
└─────────────────────────────────────────────────────┘
```

---

4️⃣ 運作機制

```
歷史資料 → Bayesian Model → 初始預測
                                ↓
              實際觀察（有冇 exploit 出現）→ 調整分數
                                ↓
                        下一批 CVE 再預測
```

動態更新系統：
- 每日更新分數
- 每個 CVE 嘅分數會隨時間、新情報改變
- 新 CVE 出現時，基於「類似漏洞」歷史做 initial guess，逐漸修正

---

5️⃣ EPSS + CVSS 優先矩陣

```
                    CVSS 高 (>=7)       CVSS 低 (<7)
                  ┌──────────────────┬──────────────────┐
  EPSS 高 (>=0.7)│  🚨 優先修！      │  ⚠️ 要關注       │
                  │  不論 CVSS 幾高   │  可能升級         │
                  │  都要即刻修       │                  │
                  ├──────────────────┼──────────────────┤
  EPSS 低 (<0.7) │  📋 要評估        │  ✅ 後處理        │
                  │  按 CVSS + asset │  standard        │
                  │  價值排優先       │  patch cycle     │
                  └──────────────────┴──────────────────┘
```

FIRST 嘅 prioritization 建議：
- Score >= 0.7：高概率被 exploit → 即刻修
- Score 0.2-0.7：中等風險 → 按 CVSS + asset 價值排
- Score < 0.2：低概率 → standard patch cycle

---

6️⃣ 實際例子

```
CVE-A: CVSS 9.8 (Critical),  EPSS 0.02 (2%)
CVE-B: CVSS 7.5 (High),      EPSS 0.85 (85%)

舊做法：CVE-A 優先（CVSS 9.8 > 7.5）
EPSS 做法：CVE-B 優先（85% 機率 30 日內被利用）

原因：
  CVE-A 雖然 severity 高，但冇人寫 exploit → 風險唔大
  CVE-B 雖然 severity 低啲，但已有 exploit code → 修慢就出事
```

---

7️⃣ 限制同注意事項

```
⚠️ 主要限制：
  - 只睇 30 日 window，唔係長遠預測
  - 新 CVE 嘅分數唔穩定，要等累積資料（頭幾日唔準）
  - 主要針對 mass exploitation，對 targeted APT 預測力較弱
  - 唔包含你嘅環境 context（你有冇用呢個組件佢唔知）
```

最佳實踐：
1. EPSS + CVSS 一齊睇
2. 結合自己嘅 asset inventory（呢個 CVE 影唔影響你）
3. 考慮 compensating control（WAF、network segmentation）

---

8️⃣ 點樣用 EPSS？

```
免費 API：
  https://api.first.org/data/v1/epss

查詢範例：
  curl https://api.first.org/data/v1/epss?cve=CVE-2024-3094

整合工具：
  - NVD 已整合 EPSS score
  - Splunk、Tenable、Rapid7 原生支援
  - 可寫 script 定期 pull 做 prioritize
```

自動化 prioritization 流程：
```
1. 定期 pull EPSS + CVSS data
2. 結合 asset inventory 過濾
3. 按 EPSS × CVSS × asset value 排序
4. 自動出 report / create ticket
```

---

9️⃣ 總結

```
CVSS = 嚴重程度（如果爆咗幾痛）
EPSS = 被利用概率（呢粒幾時會爆）

兩者結合 → data-driven vulnerability prioritization
從 guesswork 變成 evidence-based decision
```

參考來源：
- https://www.first.org/epss/
- https://www.splunk.com/en_us/blog/learn/epss-exploit-prediction-scoring-system.html
- https://api.first.org/data/v1/epss
