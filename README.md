# MFConnect

把 Mac mini 變成家用列印伺服器：家人或朋友把 PDF 或圖片傳到 Mac mini，Mac mini 排進佇列，自動或經你核准後送到 Canon imageCLASS MF642Cdw（AirPrint / IPP）列印。

傳檔入口有兩個：

- **網頁上傳頁**：對方只需要瀏覽器，不用安裝任何東西。
- **iOS / iPadOS 分享選單**：在「照片」、「檔案」等 App 按「分享 → MFConnect」。

```
 iPhone / iPad ──(分享選單，HTTP)──┐
                                   ├──▶ Mac mini：MFConnect（選單列 App）
 任何瀏覽器 ───(上傳頁，HTTP)──────┘      ├─ HTTP 伺服器（Hummingbird 2，連接埠 8631）
                                          ├─ 工作佇列（等待核准 → 排隊 → 列印中 → 完成）
                                          └─ /usr/bin/lp ──(AirPrint / IPP)──▶ Canon MF642Cdw
```

> 文件日期：2026-11-14（台北時間）。所有時間都以 Asia/Taipei 顯示。

---

## 目錄

1. [專案結構](#專案結構)
2. [HTTP 伺服器的選擇](#http-伺服器的選擇)
3. [建置步驟](#建置步驟)
4. [簽署設定（Team、App Group）](#簽署設定)
5. [在 Mac mini 上第一次設定](#在-mac-mini-上第一次設定)
6. [用試跑（DryRun）模式試跑](#用試跑dryrun模式試跑)
7. [切換成真的列印](#切換成真的列印)
8. [API](#api)
9. [安全設計與明文 HTTP 的風險](#安全設計與明文-http-的風險)
10. [已知限制](#已知限制)
11. [假設](#假設)
12. [驗證狀態](#驗證狀態)
13. [手動測試清單](#手動測試清單)

---

## 專案結構

```
MFConnect/
├── project.yml                     XcodeGen 專案定義（產生 MFConnect.xcodeproj）
├── App/
│   ├── macOS/                      選單列 App（MenuBarExtra、LSUIElement）
│   ├── iOS/                        iOS / iPadOS 主 App（設定頁）
│   └── ShareExtension/             iOS / iPadOS Share Extension（SwiftUI 分享面板）
├── Packages/MFConnectKit/          本地 Swift Package
│   ├── Sources/MFConnectCore/      資料模型、API 契約（JobOptions、JobStatus、DTO、magic bytes、檔名清理）
│   ├── Sources/MFConnectServer/    僅 macOS：HTTP 伺服器、佇列、列印、儲存、Bonjour
│   ├── Sources/MFConnectClient/    上傳用戶端、Bonjour 探索、App Group 共用設定（給 iOS 用）
│   ├── Sources/mfconnect-devserver 開發用：不需 Xcode，以試跑模式啟動伺服器
│   └── Tests/                      單元測試與整合測試（swift test）
└── scripts/
    ├── smoke_test.sh               用 curl 示範認證、上傳、查狀態與錯誤碼
    └── build_all.sh                一鍵驗收：xcodegen → 建置兩個 scheme → swift test
```

| Target | 平台 | 用到的 Package 產品 |
|---|---|---|
| `MFConnectMac` | macOS 14+ | Core、Server |
| `MFConnectiOS` | iOS / iPadOS 17+ | Core、Client（並嵌入 Share Extension） |
| `MFConnectShare` | iOS / iPadOS 17+ | Core、Client |

## HTTP 伺服器的選擇

選用 **Hummingbird 2**，沒有自己用 `NWListener` 寫 HTTP 解析，理由如下：

1. **安全**：HTTP/1.1 解析（chunked、header 大小、pipelining）交給成熟的 SwiftNIO `llhttp`，不自己處理位元組邊界。
2. **串流 body**：`request.body` 是 `AsyncSequence<ByteBuffer>`，可以邊收邊寫磁碟、邊計數，超過上限立即中斷，不會整檔讀進記憶體。
3. **內建保護**：`MaximumAvailableConnections`（同時連線數上限）、`idleTimeout`（閒置斷線，防 slowloris）、header 大小上限。
4. **可在 Linux 測試**：伺服器、佇列與整合測試都能在 Linux 上用 `swift test` 執行，macOS 專屬 API（PDFKit、ImageIO、Keychain、DNS-SD）以 `#if canImport` 隔開。

## 建置步驟

需要：macOS 14 以上、**Xcode 26 以上**（Swift 6.2；`Package.resolved` 鎖定的 Hummingbird 2.28 需要 Swift 6.2）。

> 如果只有 Xcode 16，刪掉 `Packages/MFConnectKit/Package.resolved`，SwiftPM 會改選相容的舊版 Hummingbird 2。

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open MFConnect.xcodeproj
```

或用指令建置（不需簽署）：

```bash
xcodebuild -project MFConnect.xcodeproj -scheme MFConnectMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

```bash
xcodebuild -project MFConnect.xcodeproj -scheme MFConnectiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

```bash
cd Packages/MFConnectKit && swift test
```

一次跑完以上全部（也會統計本專案程式碼的警告數；警告不會被升級成錯誤）：

```bash
scripts/build_all.sh
```

## 簽署設定

### 1. 換掉佔位符

全專案的 bundle id 前綴都是 `com.example.mfconnect`。用自己的反向網域取代，至少要改這些地方：

| 位置 | 內容 |
|---|---|
| `project.yml` | `PRODUCT_BUNDLE_IDENTIFIER`（三個 target）、`com.apple.security.application-groups`、`keychain-access-groups`、`MFKeychainAccessGroup` |
| `Packages/MFConnectKit/Sources/MFConnectCore/APIContract.swift` | `MFConnectConstants.appGroupIdentifier` |
| `Packages/MFConnectKit/Sources/MFConnectServer/Security/Token.swift` | Keychain service 名稱（可不改） |
| `Packages/MFConnectKit/Sources/MFConnectClient/SharedConfiguration.swift` | Keychain service 名稱（可不改） |

改完後重新執行 `xcodegen generate`。

### 2. Team

在 `project.yml` 的 `settings.base.DEVELOPMENT_TEAM` 填入 Team ID，或在 Xcode 的 **Signing & Capabilities** 分頁替三個 target 都選擇 Team。

- **macOS**：沒填 Team 時以 ad-hoc（`-`）簽署，可以在本機執行。但 ad-hoc 簽署的 App 每次重新建置後，鑰匙圈可能會再問一次是否允許存取 token，「登入時自動啟動」也比較不穩定。長期使用請選 Team。
- **iOS / iPadOS**：實機需要 Team。免費的 Personal Team 可以用，但 App 7 天後會過期，需要重新安裝。

### 3. App Group 與 Keychain Sharing（iOS）

主 App 與 Share Extension 透過以下方式共用資料：

- **App Group** `group.com.example.mfconnect`：伺服器位址、名稱、上次的列印選項（UserDefaults）。
- **Keychain access group** `$(AppIdentifierPrefix)com.example.mfconnect.shared`：token。

使用 Automatic signing 時，Xcode 會在 Apple Developer 後台自動建立 App Group 並加進 provisioning profile。如果 Xcode 顯示 App Group 錯誤，到 **Signing & Capabilities → App Groups** 按「＋」，建立和 `project.yml` 一致的 group。

macOS App **沒有**使用 App Group，也**關閉了 App Sandbox**（個人使用，需要呼叫 `/usr/bin/lp`）。

> **要上 Mac App Store 的話**：沙盒 App 不能執行 `/usr/bin/lp`。必須新增一個以 `NSPrintOperation`（或 `PDFDocument.printOperation(for:scalingMode:autoRotate:)`）實作的 `PrintService`，開啟 App Sandbox，並加上 `com.apple.security.network.server` 與 `com.apple.security.print` entitlement。`PrintService` protocol 就是為了這種替換而設計的。

## 在 Mac mini 上第一次設定

1. **加入印表機**：到「系統設定 → 印表機與掃描器」按「＋」，選 Canon MF642C/643C，「使用」選 **AirPrint**，按「加入」。印一張測試頁確認可以用。
2. **固定 Mac mini 的 IP（建議）**：在路由器設定 DHCP 保留，讓 Mac mini 每次拿到同一個 IP。用 `.local` 主機名稱連線時則不受 IP 變動影響。
3. **能源設定**：「系統設定 → 能源」開啟「避免在顯示器關閉時自動進入睡眠」與「網路存取時喚醒」。也可以在 MFConnect 設定中開啟「防止閒置睡眠」。
4. **安裝 App**：在 Xcode 用 `MFConnectMac` scheme 選 **Product → Archive → Distribute App → Copy App**，把 `MFConnect.app` 放到「應用程式」資料夾後開啟。選單列會出現印表機圖示。
5. **允許通知**：第一次啟動時允許通知，有新工作等待核准時才看得到提醒，也可以直接在通知上按「核准列印」。
6. **防火牆**：如果開了 macOS 防火牆，第一次收到連線時選「允許」。
7. **設定**：點選單列圖示 → 「設定…」
   - 「印表機」選剛加入的 Canon 佇列（沒有選的話會自動選系統預設或名稱含 Canon 的佇列）。
   - 確認「需要我核准才列印」開啟。
   - 開啟「登入時自動啟動」。如果狀態顯示「需要到系統設定允許」，到「系統設定 → 一般 → 登入項目」允許 MFConnect。
   - 按「套用」。
8. **測試**：先用[試跑模式](#用試跑dryrun模式試跑)確認流程，再[切換成真的列印](#切換成真的列印)。
9. **分享給家人**：
   - **網頁**：選單列會顯示 `http://<主機名>.local:8631` 與 IP 版本的網址和 QR code。對方掃描後輸入 token（選單列「Token → 複製」）。開啟設定中的「QR code 內含 token」後，掃描即可直接使用，但看到 QR code 的人都能列印。
   - **iPhone / iPad**：安裝 MFConnect App，開啟後在自動搜尋清單點選伺服器，貼上 token，按「測試連線」。之後在任何 App 的分享選單選「MFConnect」即可。

## 用試跑（DryRun）模式試跑

試跑模式使用 `DryRunPrintService`：完整走過上傳、驗證、佇列、核准流程，但**不會呼叫 `lp`**，只寫紀錄。這樣不浪費紙和碳粉。**首次安裝時預設開啟**，選單列會顯示橘色的「試跑模式」標籤。

### 方法 A：在 App 裡試跑

1. 確認選單列顯示「試跑模式」。
2. 用手機打開上傳網址，上傳一個 PDF。
3. 選單列的「待核准」出現工作 → 按「核准」→ 歷史紀錄顯示「完成」，附註「試跑模式：沒有實際列印」。

### 方法 B：不開 App，用開發伺服器試跑（任何有 Swift 的 Mac 或 Linux 都可以）

```bash
cd Packages/MFConnectKit && swift run mfconnect-devserver --auto
```

畫面會印出上傳頁網址與這次的 token。`--auto` 表示不需核准。要讓區網裡的其他裝置連線，加上 `--host 0.0.0.0`。在另一個終端機視窗跑 smoke test：

```bash
MFC_TOKEN=<上面印出的 token> scripts/smoke_test.sh http://localhost:8631
```

`smoke_test.sh` 另外有兩個選項：`--fill-queue` 測 503（佇列已滿），`--lockout` 測 429（你的 IP 會被鎖 10 分鐘）。

## 切換成真的列印

1. 完成[第一次設定](#在-mac-mini-上第一次設定)的第 1 步（AirPrint 加入印表機）。
2. 選單列 → 「設定…」→「印表機」選擇 Canon 佇列 → **關閉「試跑模式」** → 「套用」。
3. 選單列的「試跑模式」標籤消失，就代表接下來的工作會真的送到印表機。

送印時會先執行 `lpoptions -p <佇列> -l`，確認該佇列實際支援哪些選項：

| 選項 | 送出的參數 | 不支援時 |
|---|---|---|
| 份數 | `-n 1…99` | — |
| 雙面 | `-o sides=one-sided / two-sided-long-edge / two-sided-short-edge` | 降級為單面，並在工作紀錄註明 |
| 黑白 | `-o print-color-mode=monochrome` | 依印表機預設色彩列印，並在工作紀錄註明 |

圖片（JPEG、PNG、HEIC）會先轉成 **A4、置中、等比例縮放**的單頁 PDF 再送印（寬圖自動用橫向頁面）；HEIC 會先以 ImageIO 轉成 JPEG。

送印後每 3 秒用 `lpstat -o` 追蹤狀態。如果 `lpstat -l -p` 連續 3 次回報缺紙、卡紙、蓋子未關、碳粉用盡，或佇列已停用，就取消該 CUPS 工作，標記為失敗並送出系統通知。處理好印表機後，可以在選單列按「重試」。

也可以不開 App 直接用開發伺服器實際列印（會真的印出來）：

```bash
cd Packages/MFConnectKit && swift run mfconnect-devserver --lp Canon_MF642C_643C
```

## API

所有 `/api/*` 都需要 `Authorization: Bearer <token>`。上傳一律使用**原始 body**（不使用 multipart）。

| 方法 | 路徑 | 說明 |
|---|---|---|
| GET | `/` | 內嵌上傳頁（單一 HTML，CSS / JS 全內嵌，CSP 禁止載入外部資源） |
| GET | `/api/info` | `{serverName, allowedFormats, maxUploadBytes, requiresApproval, apiVersion}` |
| POST | `/api/jobs` | body 為檔案原始內容；成功回 `201 {id, status}` |
| GET | `/api/jobs/{id}` | `{id, status, statusText, filename, message, createdAt, updatedAt}` |

`POST /api/jobs` 的 header：

| Header | 值 |
|---|---|
| `X-Filename` | 百分比編碼的檔名（只用於顯示） |
| `X-Copies` | `1`–`99`（預設 1） |
| `X-Duplex` | `none` / `long` / `short`（預設 none） |
| `X-Color` | `color` / `mono`（預設 color） |
| `X-Client` | 選填，百分比編碼的用戶端名稱，記入工作紀錄 |

狀態機：`pendingApproval → queued → printing → done`；失敗為 `failed`（可重試回到 `queued`），被拒絕為 `rejected`。

錯誤一律回 JSON `{error, message}`：

| 狀態碼 | 情境 |
|---|---|
| 400 | 選項 header 格式錯誤、空檔案、上傳中斷 |
| 401 | token 錯誤或未提供 |
| 404 | 找不到工作 |
| 408 | 上傳逾時（預設 5 分鐘） |
| 413 | 檔案超過上限（先看 Content-Length，串流中也持續計數） |
| 415 | 不是 PDF / JPEG / PNG / HEIC（以 magic bytes 判斷） |
| 429 | 同一 IP token 錯 5 次後鎖 10 分鐘；或 10 分鐘內上傳超過 60 次 |
| 503 | 佇列已滿（預設 20） |

## 安全設計與明文 HTTP 的風險

### ⚠️ 這是明文 HTTP

上傳頁與 API **沒有加密**。同一個區網裡能監聽封包的人（例如公共 Wi‑Fi、被入侵的裝置）可以看到 **token 與你列印的檔案內容**。

- **只在家中區網使用。**
- **不要**在路由器設定連接埠轉發（port forwarding）或 UPnP，**不要**把 8631 開放到網際網路。
- 需要在外面列印時，請走 **Tailscale** 或其他加密 VPN 通道，再連到 Mac mini 的 Tailscale IP。
- 懷疑 token 外洩時，在選單列按「重新產生…」，舊 token 會立即失效。

### 已實作的防護

| 項目 | 做法 |
|---|---|
| 驗證 | 首次啟動以系統 CSPRNG 產生 32 bytes token（base64url），存在鑰匙圈；固定時間（constant-time）比對 |
| 暴力破解 | 同一 IP 錯 5 次鎖 10 分鐘（鎖定期間正確 token 也拒絕）；上傳頻率限制 |
| 大小 | 預設 50 MB；先檢查 `Content-Length`，串流時持續計數，超過立即回 413 並關閉連線讀取端；body 邊收邊寫入磁碟，不整檔讀進記憶體 |
| 資源 | 同時連線數上限 16、連線閒置 30 秒斷線、單一請求 5 分鐘上限、佇列長度上限 20 |
| 格式 | 只收 PDF / JPEG / PNG / HEIC，以檔頭 magic bytes 判斷，不信副檔名與 Content-Type；圖片解碼限制最大邊長 7000 px，防 decompression bomb |
| 檔名 | 清理後只用於顯示（移除路徑、控制字元、雙向覆寫字元）；磁碟上一律以 UUID 命名，存在 `~/Library/Application Support/MFConnect/spool`（權限 0700），並二次檢查路徑不會跑出 spool |
| 指令執行 | 以 `Process` + 參數陣列呼叫 `lp`、`lpstat`、`lpoptions`、`cancel`，絕不經過 shell |
| 核准 | 預設「需核准」：新工作進 `pendingApproval`，按核准才列印 |
| 網頁 | 嚴格 CSP（`default-src 'none'`、`connect-src 'self'`）、`X-Frame-Options: DENY`、`nosniff`；所有動態內容用 `textContent` 寫入；token 放在 header，不用 cookie，所以沒有 CSRF 風險 |
| Bonjour | TXT 記錄只有伺服器名稱、是否需要核准、主機名稱、API 版本，**不含 token** |
| 保留 | 檔案列印完成後預設立即刪除（可設為保留 N 小時）；被拒絕的檔案立即刪除；紀錄預設保留 30 天 |

## 已知限制

- **明文 HTTP**：見上一節。
- **只支援 PDF 與圖片**（JPEG、PNG、HEIC；分享選單會把 GIF、TIFF、WebP 等其他圖片在手機上先轉成 JPEG）。Word、Excel、Pages 等文件請先匯出成 PDF。
- 有密碼保護的 PDF 會在送印前被判定失敗。
- 一次只處理一件工作；份數由印表機處理（`-n`）。
- 工作「完成」代表 CUPS 已把資料交給印表機，不保證紙已經印出。
- 缺紙或卡紙偵測依賴印表機透過 IPP 回報的 `printer-state-reasons`。
- 沒有使用者帳號：所有拿到 token 的人權限相同。紀錄中的「誰」是來源 IP 加用戶端自述（`X-Client`、User-Agent）。
- 沒有實作 background `URLSession`（加分項）：分享面板在上傳完成前需要保持開啟。檔案會串流上傳，所以大檔也不會讓 Extension 記憶體爆掉，但關閉面板會中斷上傳。
- macOS App 沒有沙盒，不能上 Mac App Store（見[簽署設定](#簽署設定)）。
- 自動搜尋使用 Bonjour，只在同一個網段有效；跨網段請手動輸入位址。

## 假設

以下是需求沒有明確規定、由我自行決定的部分：

1. **Multiplatform 專案**：以 XcodeGen 產生**同一個 Xcode 專案、三個 target**（macOS App、iOS App、iOS Share Extension），沒有使用 Xcode 的單一 multiplatform target。原因是 macOS 端（選單列伺服器）與 iOS 端（設定頁）的功能完全不同。
2. **Bundle id**：iOS `com.example.mfconnect`、Share Extension `com.example.mfconnect.ShareExtension`、macOS `com.example.mfconnect.mac`。
3. **App Group 只用於 iOS**（主 App 與 Extension 共用）。macOS App 是獨立程式，不需要。
4. **token 共用**：Keychain access group 用 `$(AppIdentifierPrefix)com.example.mfconnect.shared`，透過 Info.plist 的 `MFKeychainAccessGroup` 在執行時取得完整名稱。
5. **PDF 的 UTI**：需求寫的 `public.pdf` 在 Apple 平台的實際識別碼是 `com.adobe.pdf`（`UTType.pdf`），Share Extension 的啟用規則使用後者，另外接受 `public.image`，最多 20 個項目。
6. **試跑模式預設開啟**：避免第一次測試就浪費紙，使用者確認後再手動關閉。
7. **圖片轉 PDF**：以 Core Graphics PDF context 繪製 A4 頁面，再用 PDFKit 開啟驗證頁數。之所以不用 PDFKit 的 `PDFPage` 子類別，是因為 `PDFDocument.dataRepresentation()` 是否會呼叫子類別的 `draw(with:to:)` 沒有文件保證，而版面需要可控；HEIC 依需求先用 ImageIO 轉 JPEG。四周留約 10 mm 白邊，寬圖使用橫向頁面。
8. **雙面不支援時**：降級為單面；**沒有黑白選項時**：照印表機預設色彩列印。兩者都記錄在工作紀錄的附註中。
9. **`lpoptions` 讀取失敗時**：照使用者要求送出所有選項，由 CUPS 決定，並在紀錄中註明「無法讀取印表機選項」。
10. **錯誤判定**：缺紙、卡紙等狀態**連續 3 次**（約 9 秒）才判定失敗並取消 CUPS 工作，避免短暫狀態誤判；送印後 30 分鐘仍未完成視為逾時。
11. **失敗工作的檔案至少保留 24 小時**，方便重試；被拒絕的檔案立即刪除。
12. **重新啟動時**：上次仍在「列印中」的工作改為失敗（可重試），因為無法確定是否已印出；`pendingApproval` 與 `queued` 會保留並繼續處理。
13. **429 有兩種來源**：token 錯誤鎖定（需求），以及每個 IP 10 分鐘內最多上傳 60 次（額外加的保護）。
14. **只綁定指定介面**時綁定該介面的 IPv4 位址；選「所有網卡」時綁定 `0.0.0.0`（只有 IPv4，`.local` 名稱在一般家用網路會解析到 IPv4）。指定的介面不存在時伺服器不啟動，不會默默改成所有網卡。
15. **Bonjour 廣播**使用 DNS-SD C API（`DNSServiceRegister`），TXT 記錄另外放了 `host=<主機名>.local`，讓 iOS 端存 `.local` 名稱而非 IP，Mac mini 換 IP 也不影響。
16. **QR code 內含 token** 是額外加的便利選項，預設關閉。
17. **`X-Client`** 是額外的選填 header；因為 HTTP header 值只能是 ASCII，用戶端名稱以百分比編碼傳送。
18. **測試框架**使用 Swift Testing（`import Testing`），由 `swift test` 執行。
19. **時間**：選單列的工作時間一律以 Asia/Taipei 顯示；API 的時間欄位是 ISO 8601 UTC。

## 驗證狀態

這份程式碼在 Linux 環境中撰寫與測試，之後在 Mac mini（Xcode 27.2）上以 `scripts/build_all.sh` 完成建置驗證：

| 項目 | 狀態 |
|---|---|
| `MFConnectKit` 在 Swift 6.2（Linux）編譯，Swift 6 語言模式，本專案程式碼零警告 | ✅ 已驗證 |
| `swift test`：73 個測試全部通過（magic bytes、檔名與路徑穿越、大小限制含串流中途超過、token 驗證與鎖定、狀態機、lp 參數組合、佇列、整合測試） | ✅ 已驗證（Linux） |
| 整合測試：隨機連接埠啟動伺服器，以 URLSession 上傳假 PDF，DryRun 收到工作且狀態正確 | ✅ 已驗證（Linux） |
| `scripts/smoke_test.sh` 對開發伺服器 14 項全過（含 503、429） | ✅ 已驗證（Linux） |
| 上傳頁以 Chromium 手機尺寸實測：登入、錯誤 token、多檔、前端格式檢查、上傳進度、輪詢到「完成」、記住 token、登出、QR 帶 token | ✅ 已驗證 |
| `project.yml` 用 XcodeGen 2.44 實際產生專案：三個 target、Extension 嵌入、Info.plist、entitlements | ✅ 已驗證 |
| `xcodebuild` 建置 `MFConnectMac`、`MFConnectiOS`（Xcode 27.2） | ✅ 已驗證（Mac） |
| `swift test` 在 macOS 上執行 | ✅ 已驗證（Mac） |
| macOS 專屬程式碼（PDFKit / ImageIO 轉檔、Keychain、DNS-SD、SwiftUI 選單列、SMAppService、通知） | ✅ 編譯通過；⏳ 執行行為見手動測試清單 |
| iOS App、Share Extension（SwiftUI、NWBrowser、NSItemProvider） | ✅ 編譯通過；⏳ 執行行為見手動測試清單 |
| 實機列印、iOS 實機分享 | ⏳ 見下方手動測試清單 |


## 手動測試清單

在 Mac mini 與 iPhone / iPad 上逐項勾選。

### 建置

- [x] `scripts/build_all.sh` 全部成功（兩個 scheme 建置成功、`swift test` 通過）
- [ ] 本專案程式碼沒有警告（`build_all.sh` 會列出）

### macOS 選單列

- [ ] 啟動後選單列出現印表機圖示，Dock 沒有圖示（`LSUIElement`）
- [ ] 第一次啟動自動產生 token；重新開啟 App 後 token 不變（存在鑰匙圈）
- [ ] 顯示 `http://<主機名>.local:8631` 與 IP 網址，點選可切換 QR code，「複製」可用
- [ ] 用手機掃 QR code 能打開上傳頁
- [ ] 開關伺服器可以停止 / 啟動；停止時手機無法連線
- [ ] 設定改連接埠（例如 8632）後伺服器自動重啟在新連接埠
- [ ] 「綁定介面」選 en0 後只能從該網段連線；選不存在的介面時顯示錯誤
- [ ] token「重新產生」後舊 token 立即失效（網頁與 iOS 都顯示 token 錯誤）
- [ ] 「登入時自動啟動」：登出再登入後 App 自動啟動
- [ ] 「防止閒置睡眠」開啟時，終端機執行 `pmset -g assertions` 能看到 MFConnect 的 `PreventUserIdleSystemSleep`
- [ ] 終端機執行 `dns-sd -B _mfconnect._tcp` 能看到伺服器；`dns-sd -L "<名稱>" _mfconnect._tcp` 的 TXT 沒有 token

### 試跑模式

- [ ] 選單列顯示「試跑模式」標籤
- [ ] 網頁上傳 PDF → 選單列「待核准」出現，含檔名、份數、雙面、黑白 / 彩色、來源 IP
- [ ] 收到「新的列印工作等待核准」系統通知；通知上的「核准列印」按鈕有效
- [ ] 按「核准」→ 歷史紀錄顯示「完成」與「試跑模式：沒有實際列印」，印表機沒有動作
- [ ] 按「拒絕」→ 網頁顯示「已拒絕」
- [ ] 關閉「需要我核准才列印」→ 上傳後直接完成
- [ ] `MFC_TOKEN=… scripts/smoke_test.sh http://<mac-mini>.local:8631` 全部通過

### 真的列印（Canon MF642Cdw）

- [ ] 「印表機」清單出現 Canon 佇列；刪除印表機後重新整理，顯示「到系統設定加入」的引導文字
- [ ] 關閉試跑模式，PDF 單面彩色 1 份 → 正確印出
- [ ] PDF 3 份 → 印出 3 份
- [ ] PDF 雙面長邊翻頁 → 正確雙面；短邊翻頁 → 方向正確
- [ ] 黑白 → 印出黑白
- [ ] iPhone 拍的 HEIC 照片 → A4 置中、方向正確（直拍不會變橫的）
- [ ] 橫向 PNG 截圖 → 橫向頁面、置中
- [ ] 有密碼的 PDF → 標記「失敗」，訊息為「PDF 有密碼保護」
- [ ] 抽掉紙匣 / 缺紙時送印 → 約 10 秒後標記「失敗：印表機缺紙」，收到系統通知，CUPS 佇列中的工作已取消
- [ ] 補紙後在歷史紀錄按「重試」→ 正常印出
- [ ] 印表機關機時送印 → 30 分鐘內標記失敗（或在印表機開機後完成）
- [ ] 列印完成後 `~/Library/Application Support/MFConnect/spool` 是空的（保留 0 小時）
- [ ] 設定保留 1 小時 → 檔案在 1 小時後（下一次 15 分鐘的清理週期）被刪除

### 網頁上傳頁（手機 Safari / Android Chrome / 電腦瀏覽器）

- [ ] 單手操作順暢，按鈕夠大；深色模式顯示正常
- [ ] 錯誤 token 顯示「token 錯誤」；連錯 5 次顯示「嘗試次數太多」
- [ ] 多選檔案，每個檔案可個別設定份數、雙面、色彩
- [ ] 選 `.docx` 或改副檔名的假 PDF → 前端顯示「格式不支援」
- [ ] 超過 50 MB 的檔案 → 前端顯示「檔案太大」
- [ ] 上傳時進度條會動；完成後狀態依序顯示「等待核准 → 排隊中 → 列印中 → 完成」
- [ ] 重新整理頁面不必重新輸入 token；按「登出」後需要重新輸入
- [ ] 電腦瀏覽器拖放檔案可上傳

### iOS / iPadOS 主 App

- [ ] 第一次開啟時詢問「區域網路」權限，說明文字為繁體中文
- [ ] 自動搜尋列出 Mac mini；點選後填入位址（`.local`）
- [ ] 拒絕區域網路權限時顯示到設定開啟的說明
- [ ] 手動輸入 `192.168.x.x` 也可以
- [ ] 「測試連線」成功時顯示伺服器名稱、大小上限、是否需要核准；錯誤 token 顯示「token 錯誤」
- [ ] iPad 直向 / 橫向、分割畫面都正常

### Share Extension

- [ ] 「照片」選 1 張 → 分享選單出現 MFConnect
- [ ] 「照片」選 5 張 → 一次全部傳送，進度條正常
- [ ] 「檔案」選 PDF → 可傳送
- [ ] 分享網頁連結或文字時 **不會** 出現 MFConnect
- [ ] 面板顯示目標伺服器、份數、雙面、黑白 / 彩色；上次的選項會被記住
- [ ] 成功：顯示「已送出 N 個檔案，等待管理者核准後列印」
- [ ] Mac mini 關機時：顯示明確的連線失敗訊息
- [ ] 尚未在主 App 設定時：顯示「請先開啟 MFConnect App」
- [ ] 上傳 40 MB 以上的大 PDF 不會讓 Extension 當掉（串流上傳）
- [ ] GIF 或螢幕截圖（只提供 UIImage）也能傳送（轉成 JPEG）

### 安全

- [ ] 從另一台電腦執行 `curl http://<mac-mini>.local:8631/api/info`（不帶 token）→ 401
- [ ] 路由器上**沒有**任何連接埠轉發或 UPnP 對應到 8631
- [ ] `X-Filename: ../../../etc/passwd` 上傳 → 紀錄只顯示 `passwd`，spool 中的檔名是 UUID
