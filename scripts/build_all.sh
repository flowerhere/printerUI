#!/usr/bin/env bash
# 一鍵驗收：產生 Xcode 專案 → 建置 macOS 與 iOS scheme → 跑 Package 測試。
# 在 Mac（已安裝 Xcode）上執行：scripts/build_all.sh
set -euo pipefail
cd "$(dirname "$0")/.."

LOG_DIR="build/logs"
mkdir -p "${LOG_DIR}"

# 先確認 xcodebuild 指向完整的 Xcode，而不是 Command Line Tools
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "${DEV_DIR}" != *.app/Contents/Developer ]]; then
  echo "✘ 目前的開發者目錄是「${DEV_DIR:-未設定}」，xcodebuild 需要完整的 Xcode。"
  echo "  1. 從 App Store 安裝 Xcode 26 以上並開啟一次"
  echo "  2. sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  echo "  3. sudo xcodebuild -license accept"
  exit 1
fi
echo "▸ 使用 $(xcodebuild -version | head -1)（${DEV_DIR}）"

if ! command -v xcodegen >/dev/null; then
  echo "▸ 安裝 XcodeGen（Homebrew）"
  brew install xcodegen
fi

echo "▸ 產生 MFConnect.xcodeproj"
xcodegen generate --spec project.yml

build() {
  local scheme="$1" destination="$2" log="${LOG_DIR}/$1.log"
  echo "▸ 建置 ${scheme}（${destination}）"
  if ! xcodebuild -project MFConnect.xcodeproj -scheme "${scheme}" -destination "${destination}" \
      -configuration Debug -derivedDataPath build/DerivedData \
      CODE_SIGNING_ALLOWED=NO build >"${log}" 2>&1; then
    echo "✘ ${scheme} 建置失敗，錯誤如下（完整紀錄：${log}）"
    grep -E "error:" "${log}" | sort -u | head -40
    exit 1
  fi
  # 只統計本專案原始碼的警告（排除第三方套件）
  local warnings
  warnings="$(grep -E "^/.*(App|Packages/MFConnectKit/Sources)/.*warning:" "${log}" | sort -u || true)"
  if [[ -n "${warnings}" ]]; then
    echo "⚠ ${scheme} 有 $(echo "${warnings}" | wc -l | tr -d ' ') 個警告："
    echo "${warnings}"
  else
    echo "✔ ${scheme} 建置成功，沒有警告"
  fi
}

build MFConnectMac "platform=macOS"
build MFConnectiOS "generic/platform=iOS Simulator"

echo "▸ 執行 Package 測試（swift test）"
(cd Packages/MFConnectKit && swift test 2>&1 | tee "../../${LOG_DIR}/swift-test.log" | grep -E "✘|error:|Test run|Executed")

echo "✔ 全部完成"
