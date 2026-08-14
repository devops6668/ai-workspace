# 92 AD Groups + JupyterHub Login 問題 — 總結

---

## 問題

一個 user 有92個 AD group，不能 login JupyterHub，其他 app 冇問題。

---

## 根本原因（最 likely）

**OIDC JWT Token 太大** — 92 groups 嘅 token 可以去到 8-12KB，中間任何一個 proxy/middleware 都可能截斷。

---

## 可能中招嘅位置（由外到內）

```
Browser → F5 BIG-IP → NGINX Ingress → JupyterHub Proxy → Hub → Keycloak
          ↑              ↑                ↑
       最 likely       如果有 ingress    configurable-http-proxy
     (599 + 無 log)
```

| 位置 | 預設 limit | 92 groups token | 狀態 |
|------|-----------|----------------|------|
| Browser cookie | ~4KB | 8-12KB | ❌ 超 |
| F5 HTTP Profile | 8KB header | 8-12KB | ❌ 超 |
| F5 HTTP/2 stream | 默認 | stream reset | ❌ 中招 |
| F5 ASM/WAF | inspection | block 大 payload | ❌ 可能 block |
| NGINX Ingress buffer | 4KB | 8-12KB | ❌ 超 |
| JupyterHub configurable-http-proxy | 30s timeout | slow token exchange | ❌ timeout |

---

## 解法（由根治到治標）

### 根治：Keycloak 端減少 Token 大小

1. **Hardcoded Groups Mapper** — 只帶 JupyterHub 需要嘅 group
   - Keycloak Admin → Clients → JupyterHub → Mappers → Create → Hardcoded groups mapper
   - Token Claim Name: `groups`
   - 只加需要嘅 5-10 個 group

2. **LDAP Group Mapper Filter** — 喺 sync 階段就過濾
   - User Federation → LDAP → Groups mapper → 只 sync 特定 group

### 治標：加大各層 buffer

3. **F5 BIG-IP**（最 likely 中招）
   - HTTP Profile: Maximum Response Headers Size → 32768
   - Disable HTTP/2
   - ASM: 對 Keycloak endpoint disable
   - OneConnect: max-connections 200, idle-timeout 600

4. **NGINX Ingress**（如果 JupyterHub 有 ingress）
   - `proxy-buffer-size: "16k"`
   - `proxy-buffers-number: "8"`
   - `large-client-header-buffers: "4 16k"`

5. **JupyterHub Session Store** — 改用 server-side storage，唔擺 cookie

### 繞過：唔經 F5

6. **JupyterHub 直連 Keycloak NodePort** — 繞過 F5

---

## 排查步驟（帶去嗰個 cluster 跑）

```bash
# 1. 確認 Keycloak 有冇 log
curl -sk "https://keycloak.xxx/realms/xxx/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=xxx" \
  -d "username=xxx" \
  -d "password=xxx" | python3 -c "
import sys,json,base64
d=json.load(sys.stdin)
if 'access_token' in d:
    t=d['access_token']
    p=json.loads(base64.b64decode(t.split('.')[1]+'=='))
    print(f'Token: {len(t)} bytes, Groups: {len(p.get(\"groups\",[]))}')
else:
    print('Error:', d)
"

# 2. JupyterHub logs
kubectl logs -n jupyterhub deploy/hub --tail=100 | grep -i "599\|error\|token"

# 3. F5 logs
tmsh show /ltm log | grep -i "599\|keycloak\|reset"

# 4. Browser F12 Network tab 睇 response
```

---

## F5 Tuning 詳細設定

### HTTP Profile

```
名称:                   http-keycloak
最大 Response Headers:  32768     (default 8192)
最大 Response Body:     0         (0 = unlimited)
Receive Window Size:    65535
Send Timeout:          120       (default 20)
Idle Timeout:          300       (default 300)
Server Close Action:   No Close

HTTP/2 Settings:
  HTTP/2 Profile:      Disabled
  HTTP/2 Activation Mode: Disabled
```

### OneConnect Profile

```
Name:                    oneconnect-keycloak
Max Connections:         200     (per source IP)
Max Connections (per vserver): 2000
Idle Timeout:            600
Reap Max Idle:           600
```

### TCP Profile

```
Name:                    tcp-keycloak
Idle Timeout:            600
TCP Close Timeout:       600
Send Buffer Size:        65535
Receive Window Size:     65535
Max Retransmissions:     10
Max SYN Retransmissions: 5
```

### iRule (keycloak-oidc-fix)

```tcl
when HTTP_REQUEST {
    if { [string tolower [HTTP::uri]] contains "/protocol/openid-connect" } {
        ASM::disable
        HTTP::header remove "Accept-Encoding"
        set flag 0
    }
}

when HTTP_RESPONSE {
    if { [info exists flag] && $flag == 0 } {
        # OIDC response 唔做 buffer
    }
}
```

### Virtual Server 設定

```
Source Address Translation:  SNAT / Auto Map
Connection Idle Timeout:     300
HTTP Profile:                http-keycloak
SSL Profile (Client):        你嘅 SSL profile
SSL Profile (Server):        server-ssl-keycloak
OneConnect Profile:          oneconnect-keycloak
```

### ASM / WAF（如果有）

```
方法1：直接 disable ASM for Keycloak
方法2：Security → URL → Allow List 加入：
  /realms/*/protocol/openid-connect/*
  /realms/*/account/*
  /admin/*
方法3：Disable Response Inspection
```

---

## 一句話總結

> **92 groups → JWT 太大 → F5 HTTP/2 stream reset → 599 → Keycloak 冇 log。**
> **解法：Keycloak 端 filter groups，F5 端加大 buffer / disable HTTP/2。**

---

*Date: 2026-08-12*
*Author: Hermes Agent*
*Tags: jupyterhub, keycloak, AD, OIDC, F5, BIG-IP, 599, token-size*
