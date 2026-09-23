#!/bin/sh
# ============================================================
#  Firewall Keepalive — health-check script
#  Reads endpoints from /config/endpoints.txt
#  Tests each endpoint and prints summary
# ============================================================

set -e

ENDPOINTS_FILE="/config/endpoints.txt"

if [ ! -f "$ENDPOINTS_FILE" ]; then
  echo "❌ ERROR: $ENDPOINTS_FILE not found"
  exit 1
fi

# Count valid lines (skip empty/comment)
TOTAL=$(grep -cvE '^\s*$|^\s*#' "$ENDPOINTS_FILE" || true)
if [ "$TOTAL" -eq 0 ]; then
  echo "⚠️ No endpoints defined in $ENDPOINTS_FILE"
  exit 0
fi

PASS=0
FAIL=0
RESULTS=""
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

while IFS=' ' read -r PROTO HOST PORT REST; do
  # Skip empty lines and comments
  case "$PROTO" in
    ""|\#*) continue ;;
  esac

  LABEL="${PROTO}://${HOST}:${PORT}"
  STATUS=""

  case "$PROTO" in
    telnet)
      if nc -zvw3 "$HOST" "$PORT" >/dev/null 2>&1; then
        STATUS="✅ PASS"
        PASS=$((PASS + 1))
      else
        STATUS="❌ FAIL"
        FAIL=$((FAIL + 1))
      fi
      ;;

    curl)
      if curl -sfk --max-time 5 "http://${HOST}:${PORT}/" >/dev/null 2>&1; then
        STATUS="✅ PASS"
        PASS=$((PASS + 1))
      else
        STATUS="❌ FAIL"
        FAIL=$((FAIL + 1))
      fi
      ;;

    curl-https)
      if curl -sfk --max-time 5 "https://${HOST}:${PORT}/" >/dev/null 2>&1; then
        STATUS="✅ PASS"
        PASS=$((PASS + 1))
      else
        STATUS="❌ FAIL"
        FAIL=$((FAIL + 1))
      fi
      ;;

    openssl)
      # -CAfile /dev/null: accept self-signed certs (no trusted CA needed)
      # We only care if TCP+TLS handshake completes = firewall traffic generated
      CERT_OUTPUT=$(echo "" | openssl s_client -connect "${HOST}:${PORT}" \
        -CAfile /dev/null 2>/dev/null)
      CONNECT_OK=$(echo "$CERT_OUTPUT" | grep -c "BEGIN CERTIFICATE" || true)
      VERIFY_CODE=$(echo "$CERT_OUTPUT" \
        | grep "Verify return code:" \
        | sed 's/.*Verify return code: \([0-9]*\).*/\1/' \
        | head -1)

      # 0=valid chain, 18=self-signed, 19=self-signed in chain
      # All three = TLS handshake succeeded = traffic generated
      if [ "$CONNECT_OK" -gt 0 ]; then
        if [ "$VERIFY_CODE" = "0" ]; then
          STATUS="✅ PASS"
        elif [ "$VERIFY_CODE" = "18" ] || [ "$VERIFY_CODE" = "19" ]; then
          STATUS="✅ PASS (self-signed)"
        else
          STATUS="⚠️ WARN (cert code: ${VERIFY_CODE})"
        fi
        PASS=$((PASS + 1))
      else
        STATUS="❌ FAIL"
        FAIL=$((FAIL + 1))
      fi
      ;;

    *)
      STATUS="❌ SKIP (unknown protocol: ${PROTO})"
      FAIL=$((FAIL + 1))
      ;;
  esac

  RESULTS="${RESULTS}${STATUS}  ${PROTO} ${HOST}:${PORT}\n"

done < "$ENDPOINTS_FILE"

# Summary
echo "======================================="
echo "🔥 Firewall Keepalive Report"
echo "🕐 ${TIMESTAMP}"
echo "======================================="
echo ""
printf "%b" "$RESULTS"
echo ""
echo "---------------------------------------"
echo "Total: ${TOTAL} | ✅ Pass: ${PASS} | ❌ Fail: ${FAIL}"
echo "======================================="

# Exit non-zero if any failed (shows as failed Job in k8s)
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
