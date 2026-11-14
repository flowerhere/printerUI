#!/usr/bin/env bash
# MFConnect 煙霧測試：用 curl 示範認證、上傳、查狀態與各種錯誤碼。
#
# 用法：
#   MFC_TOKEN=<選單列複製的 token> scripts/smoke_test.sh [伺服器網址] [選項]
#
#   伺服器網址   預設 http://localhost:8631
#   --lockout    也測試「token 錯 5 次鎖 10 分鐘」（會把你這台電腦的 IP 鎖住 10 分鐘！）
#   --fill-queue 也測試「佇列已滿 503」（會塞入多筆等待核准的工作，建議在試跑模式下執行）
#
# 建議先在選單列開啟「試跑模式」，避免真的印出來。
set -uo pipefail

BASE="http://localhost:8631"
RUN_LOCKOUT=0
RUN_FILL=0
for arg in "$@"; do
  case "${arg}" in
    --lockout) RUN_LOCKOUT=1 ;;
    --fill-queue) RUN_FILL=1 ;;
    http://*|https://*) BASE="${arg%/}" ;;
    *) echo "未知參數：${arg}" >&2; exit 2 ;;
  esac
done

if [[ -z "${MFC_TOKEN:-}" ]]; then
  echo "請先設定環境變數 MFC_TOKEN，例如：MFC_TOKEN=xxxx $0" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

# check <說明> <預期狀態碼> <實際狀態碼>
check() {
  if [[ "$2" == "$3" ]]; then
    green "✔ $1（$3）"; PASS=$((PASS + 1))
  else
    red "✘ $1：預期 $2，實際 $3"; FAIL=$((FAIL + 1))
    [[ -s "${WORK}/body" ]] && sed 's/^/    /' "${WORK}/body" && echo
  fi
}

# req <method> <path> [curl 參數…]：輸出 HTTP 狀態碼，回應內容寫入 ${WORK}/body
req() {
  local method="$1" path="$2"; shift 2
  curl -sS -o "${WORK}/body" -w '%{http_code}' -X "${method}" "${BASE}${path}" "$@" 2>/dev/null || echo "000"
}

AUTH=(-H "Authorization: Bearer ${MFC_TOKEN}")

# 最小的合法 PDF（一頁空白 A4）
cat > "${WORK}/test.pdf" <<'PDF'
%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] >> endobj
trailer << /Root 1 0 R >>
%%EOF
PDF
printf 'hello, this is not a pdf\n' > "${WORK}/fake.pdf"

echo "目標：${BASE}"
echo "── 基本 ──"
check "GET / 上傳頁" 200 "$(req GET /)"
check "GET /api/info 沒有 token → 401" 401 "$(req GET /api/info)"
check "GET /api/info 帶 token → 200" 200 "$(req GET /api/info "${AUTH[@]}")"
echo "    $(cat "${WORK}/body")"

echo "── 上傳 ──"
FILENAME="$(printf '煙霧測試 %s.pdf' "$(TZ=Asia/Taipei date '+%H%M%S')" | od -An -tx1 | tr -d ' \n' | sed 's/../%&/g')"
code="$(req POST /api/jobs "${AUTH[@]}" \
  -H "Content-Type: application/octet-stream" \
  -H "X-Filename: ${FILENAME}" -H "X-Copies: 2" -H "X-Duplex: long" -H "X-Color: mono" \
  --data-binary @"${WORK}/test.pdf")"
check "POST /api/jobs 上傳 PDF → 201" 201 "${code}"
echo "    $(cat "${WORK}/body")"
JOB_ID="$(sed -n 's/.*"id":"\([0-9A-Fa-f-]\{36\}\)".*/\1/p' "${WORK}/body")"

if [[ -n "${JOB_ID}" ]]; then
  check "GET /api/jobs/${JOB_ID} → 200" 200 "$(req GET "/api/jobs/${JOB_ID}" "${AUTH[@]}")"
  echo "    $(cat "${WORK}/body")"
  echo "    （需核准模式下狀態為 pendingApproval；到選單列按「核准」後再查一次會變成 done）"
fi

echo "── 錯誤碼 ──"
check "上傳不支援的格式（副檔名 .pdf 但內容是文字）→ 415" 415 \
  "$(req POST /api/jobs "${AUTH[@]}" -H "X-Filename: fake.pdf" --data-binary @"${WORK}/fake.pdf")"
check "份數 100 → 400" 400 \
  "$(req POST /api/jobs "${AUTH[@]}" -H "X-Copies: 100" --data-binary @"${WORK}/test.pdf")"
check "雙面參數錯誤 → 400" 400 \
  "$(req POST /api/jobs "${AUTH[@]}" -H "X-Duplex: both" --data-binary @"${WORK}/test.pdf")"
# 宣稱 2 GB 的 Content-Length：伺服器只看 header 就回 413 並斷線，不會接收內容
check "Content-Length 超過上限 → 413" 413 \
  "$(req POST /api/jobs "${AUTH[@]}" -H "Content-Length: 2147483648" -H "Expect:" --data-binary @"${WORK}/test.pdf" --max-time 10)"
check "查詢不存在的工作 → 404" 404 "$(req GET "/api/jobs/00000000-0000-0000-0000-000000000000" "${AUTH[@]}")"
check "上傳時 token 錯誤 → 401" 401 \
  "$(req POST /api/jobs -H "Authorization: Bearer wrong" --data-binary @"${WORK}/test.pdf")"

if [[ "${RUN_FILL}" == 1 ]]; then
  echo "── 佇列已滿 ──"
  last=""
  for _ in $(seq 1 60); do
    last="$(req POST /api/jobs "${AUTH[@]}" -H "X-Filename: fill.pdf" --data-binary @"${WORK}/test.pdf")"
    [[ "${last}" != 201 ]] && break
  done
  check "持續上傳直到佇列已滿 → 503" 503 "${last}"
  echo "    （請到選單列拒絕這些 fill.pdf 工作）"
fi

if [[ "${RUN_LOCKOUT}" == 1 ]]; then
  echo "── 鎖定（你的 IP 將被鎖 10 分鐘）──"
  last=""
  for _ in 1 2 3 4 5; do last="$(req GET /api/info -H "Authorization: Bearer wrong-token")"; done
  check "token 錯誤第 5 次 → 429" 429 "${last}"
  check "鎖定期間即使 token 正確也 → 429" 429 "$(req GET /api/info "${AUTH[@]}")"
  echo "    （可在設定視窗按「解除所有鎖定」）"
fi

echo
echo "通過 ${PASS} 項，失敗 ${FAIL} 項"
[[ "${FAIL}" == 0 ]]
