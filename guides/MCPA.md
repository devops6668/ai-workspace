📚 MCPA 認證學習筆記
Model Context Protocol Associate Certification

---

1️⃣ MCP 係乜？

MCP (Model Context Protocol) 係一個開放標準，用嚟連接 AI 應用同外部系統。

類比： MCP 就好似 AI 應用嘅 USB-C port — 標準化咗連接方式。

支持嘅 Client：
- Claude、ChatGPT
- VS Code Copilot、Cursor
- MCPJam 等

---

2️⃣ 核心架構

```
┌─────────────┐     JSON-RPC     ┌─────────────┐
│   MCP Host  │ ◄──────────────► │  MCP Server │
│  (AI App)   │                  │  (Tools/DB) │
└─────────────┘                  └─────────────┘
       │
       ▼
┌─────────────┐
│  MCP Client │
│  (Connector)│
└─────────────┘
```

三大組件：
- Host — AI 應用（如 Claude Desktop）
- Client — 連接 Host 同 Server 嘅橋樑
- Server — 暴露工具/資源嘅服務

---

3️⃣ 傳輸方式 (Transports)

stdio
- 透過標準輸入/輸出通信
- 適合本地單用戶場景
- 新行分隔嘅 JSON-RPC

Streamable HTTP
- 每個消息係一個 HTTP POST
- 回應可以係 JSON 或 SSE 流
- 適合多用戶/遠端場景

---

4️⃣ 消息模式 (Message Patterns)

Request & Response
json
// Client → Server (Request)
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/list",
  "params": {}
}

// Server → Client (Response)
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": { "tools": [...] }
}


Notifications
- 無需回應嘅單向消息
- 用於進度更新、列表變更等

Multi Round-Trip Requests
- Server 需要額外輸入時，返回 InputRequiredResult
- Client 帶住用戶輸入重試請求

---

5️⃣ Tools（工具）

用途： 讓 LLM 調用外部功能（API、數據庫等）

定義：
json
{
  "name": "get_weather",
  "description": "Get weather for a location",
  "inputSchema": {
    "type": "object",
    "properties": {
      "location": { "type": "string" }
    },
    "required": ["location"]
  }
}


關鍵概念：
- 模型控制（Model-controlled）— LLM 自動發現同調用
- Human-in-the-loop — 敏感操作需用戶確認
- Tool Annotations — 描述工具行為嘅元數據

錯誤處理：
- Protocol Errors — 請求結構問題（-32602）
- Tool Execution Errors — 執行時錯誤（isError: true）

---

6️⃣ Resources（資源）

用途： 讓 Server 暴露數據給 LLM 作為上下文

類型：
- 文件（file://）
- 數據庫 Schema
- URL（https://）
- 自定義 URI

操作：
- resources/list — 列出可用資源
- resources/read — 讀取資源內容
- resources/templates/list — 列出參數化模板

訂閱：
- 客戶端可訂閱資源變更通知
- Server 發送 notifications/resources/updated

---

7️⃣ Prompts（提示模板）

用途： Server 暴露預定義嘅提示模板

用途場景：
- 代碼審查模板
- 數據分析模板
- 特定工作流提示

---

8️⃣ 安全與治理

信任邊界
- Client ↔️ Server 之間嘅信任關係
- 認證同授權機制

權限控制
- OAuth 2.1 認證
- API Keys 管理
- Scope-based 授權

風險控制
- 輸入驗證
- 輸出清理
- Rate Limiting
- 審計日誌

安全最佳實踐
1. Server 必須驗證所有輸入
2. Client 應提示用戶確認敏感操作
3. 實施超時機制
4. 記錄工具使用日誌

---

9️⃣ 用例與生態

適用場景
- AI 助手連接企業系統
- 自動化工作流
- 數據分析整合
- 代碼生成工具

生態系統
- 多種 Client 實現
- 多種 Server 實現
- 社區擴展
- Registry 共享

---

🔟 考試重點

領域分布
1. MCP 基礎 (16%)
2. 架構與組件 (14%)
3. 交互與執行 (26%) ← 最重要
4. 安全與治理 (24%)
5. 用例與生態 (20%)

準則建議
- 理解 JSON-RPC 基礎
- 熟悉 LLM API（OpenAI/Anthropic）
- 了解 Agentic AI 概念
- 基本安全知識（OAuth、API Keys）

---

📚 學習資源

官方文檔：
- https://modelcontextprotocol.io/docs/2026-07-28/getting-started/intro
- https://modelcontextprotocol.io/specification/2026-07-28

社區：
- https://aaif.io/projects/model-context-protocol/

考試報名：
- https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/

---

🗓️ 學習計劃（4-6週）

| 週數 | 主題 | 重點 |
|------|------|------|
| 1 | MCP 基礎 | 概念、文檔 |
| 2 | 架構與組件 | Host/Client/Server |
| 3-4 | 交互與執行 | 工具調用、錯誤處理 |
| 5 | 安全與治理 | 認證、授權、風險 |
| 6 | 複習+模擬試 | 準備考試 |

---

最後更新：2026-08-07
作者：Paul Wong

---
