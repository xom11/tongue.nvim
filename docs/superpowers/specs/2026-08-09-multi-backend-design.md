# Nhiều backend: macism, im-select, im-select.exe

Ngày: 2026-08-09

## Vấn đề

`resolve()` hiện hardcode đúng hai nhánh: `tongue` trên Darwin, `fcitx5-remote`
trên Linux. Máy nào không có hai binary đó thì plugin nằm im hoàn toàn, kể cả khi
đã cài `macism` hoặc `im-select` — những công cụ vốn đã thoả đúng hợp đồng backend
mà plugin đòi hỏi (`get` in một token, `set <token>`).

Ngoài ra `backend` bắt buộc phải là một table viết tay. Muốn dùng `macism` với
layout US thay vì ABC, người dùng phải chép nguyên bảng bốn khoá — trong khi thứ
họ muốn đổi chỉ là một chuỗi.

## Phạm vi

Thêm ba preset, mở chuỗi auto-detect thành dữ liệu, cho phép chọn preset bằng tên
và đè `english` mà không phải viết lại cả backend.

**Không** nằm trong phạm vi: ibus, fcitx4, gsettings; đổi máy trạng thái trong
`init.lua`; đổi hợp đồng `sanitize`.

## Quyết định đã chốt

1. **macism/im-select được auto-detect**, xếp sau `tongue`. Máy đang có `tongue`
   không đổi hành vi một chút nào.
2. **Preset mang sẵn `english` mặc định** (`com.apple.keylayout.ABC` trên macOS,
   `1033` trên Windows) và cho phép đè bằng `setup({ english = ... })`.
3. **Windows `im-select.exe` được auto-detect.** Chuỗi resolve của Windows sẽ có
   test thật; bản thân binary thì không ai chạy được từ máy này.

## Thiết kế

### 1. `lua/tongue/presets.lua` — ba bảng dữ liệu mới

```lua
macism = {
  english = "com.apple.keylayout.ABC",
  get = { "macism" },
  set = { "macism" },
  note = <cảnh báo input-source-only, nguyên văn ở mục 7>,
},

im_select = {  -- github.com/daehahn/im-select, macOS
  english = "com.apple.keylayout.ABC",
  get = { "im-select" },
  set = { "im-select" },
  note = <như trên>,
},

im_select_exe = {  -- im-select.exe, Windows; token là locale ID
  english = "1033",
  get = { "im-select.exe" },
  set = { "im-select.exe" },
  note = <như trên>,
},
```

Khoá preset là định danh Lua hợp lệ, để `require("tongue.presets").im_select`
vẫn viết được như `.tongue` và `.fcitx5` hôm nay.

Cả ba **không** khai `tokens`. ID nguồn nhập là tuỳ máy, một allow-list ở đây sẽ
chặn nhầm cấu hình hợp lệ. Luật một-token trong `sanitize` vẫn bắt được rác —
đúng như lý do `fcitx5` cũng không khai `tokens`.

`english = "com.apple.keylayout.ABC"` là mặc định im-select.nvim dùng, và là
layout mà mọi IME tiếng Việt ngoài đều ngồi lên trên.

### 2. `note` — khoá thứ năm, tuỳ chọn, chỉ để hiển thị

`validate` chấp nhận `note` là chuỗi hoặc `nil`, giống cách nó đối xử với
`unknown`. Không module nào khác đọc nó ngoài `health`. Backend tự viết cũng đặt
được.

Đây là khoá **duy nhất** được thêm vào hợp đồng backend, và nó không mang ngữ
nghĩa điều khiển — chỉ là văn bản.

### 3. `resolve()` — bảng ứng viên thay chuỗi `if`

```lua
local CANDIDATES = {
  Darwin = {
    { "tongue",    "tongue"    },
    { "macism",    "macism"    },
    { "im-select", "im_select" },
  },
  Linux = {
    { "fcitx5-remote", "fcitx5" },
  },
  Windows_NT = {
    { "im-select.exe", "im_select_exe" },
  },
}
```

Cột 1 là tên binary đem đi dò, cột 2 là khoá preset. Thứ tự trong bảng **là** thứ
tự ưu tiên. Thêm backend về sau = thêm một dòng, không phải một nhánh — đúng với
lời file `presets.lua` tự nhận: preset là *dữ liệu*, không phải code đặc quyền.

`reason` trả về giữ nguyên quy ước hiện tại: tên binary đã dò trúng (`"tongue"`,
`"macism"`, `"fcitx5-remote"`…).

### 4. `resolve()` — chữ ký nhận prober tiêm được

```lua
---@param opts table?
---@param probe table?  { sysname = string, executable = fun(name):boolean }
function M.resolve(opts, probe)
```

Mặc định: `sysname` lấy từ `uv.os_uname()`, `executable` gọi `vim.fn.executable`.
Tiêm từng phần được — test chỉ cần khai thứ nó quan tâm.

Đây là điều kiện để chuỗi Windows có test thật từ một máy macOS, và nó theo đúng
nguyên tắc `backend.lua` đã tự phát biểu ở đầu file: `init.lua` không biết gì về
OS, nên máy trạng thái test được. Giờ đến lượt `resolve` chịu cùng kỷ luật đó.

### 5. Bề mặt cấu hình mới

```lua
require("tongue").setup({
  backend = "macism",                        -- tên preset, hoặc table như cũ
  english = "com.apple.keylayout.US",        -- đè token English lên backend nào cũng được
})
```

Thứ tự xử lý trong `resolve`:

1. Chọn backend thô: table tự khai → tra preset theo tên → SSH thì dừng → dò
   chuỗi ứng viên.
2. Nếu `opts.english` có mặt: `vim.deepcopy` backend rồi mới đè.
3. `validate` **sau khi** đè.

Ba ràng buộc bắt buộc:

- **`english` đè lên cả backend auto-detect**, không riêng backend tự khai. Đó mới
  là ca thường gặp: có sẵn `macism`, chỉ muốn đổi ABC thành US.
- **Phải deepcopy trước khi đè.** Sửa tại chỗ là làm bẩn bảng preset dùng chung
  cho cả phiên; lần `setup()` thứ hai sẽ thấy giá trị của lần thứ nhất.
- **Validate sau khi đè.** Nhờ vậy `backend = "tongue", english = "us"` báo lỗi
  `backend.tokens must contain backend.english` thay vì âm thầm làm mọi lần đọc
  bị `sanitize` loại bỏ.

**Tra tên preset:** thử `presets[name]` trước, không có thì thử
`presets[name:gsub("[^%w]", "_")]`. Người dùng sẽ gõ tên binary
(`"im-select"`, `"im-select.exe"`) chứ không gõ định danh Lua, và cả hai đều quy
về đúng một khoá. Chỉ một luật, viết ra trong tài liệu, không phải một bảng bí
danh giấu trong code.

Tên preset không tồn tại → lỗi liệt kê các tên hợp lệ. Không im lặng quay về
auto-detect: người dùng đã nói rõ họ muốn gì, đoán thay họ là cách config thôi
không còn dự đoán được.

**`validate` giờ chạy trên mọi đường**, kể cả preset dựng sẵn — trước đây preset
được tin tưởng vô điều kiện. Đó là chủ ý: một preset viết hỏng phải nổ to ngay
trong bộ test, chứ không phải biến thành lỗi lúc chạy trên máy người dùng.

`english` không phải chuỗi, hoặc là chuỗi rỗng → lỗi, cùng thông điệp mà
`validate` dùng cho `backend.english`.

### 6. `init.lua` — một dòng duy nhất phải sửa

`setup()` hiện chỉ báo lỗi khi `opts.backend ~= nil`, vì đó từng là knob duy nhất
sinh ra được lỗi cấu hình. `english` giờ cũng sinh được:

```lua
if opts.backend ~= nil or opts.english ~= nil then
```

Không sửa chỗ này thì `english` sai sẽ làm plugin nằm im **không một lời nào** —
đúng kiểu hỏng âm thầm mà cả plugin này được viết ra để chống.

Ngoài dòng đó, `init.lua` không đổi. Máy trạng thái vẫn không biết gì về OS.

### 7. `health.lua` — nói thẳng giới hạn

Ngay sau dòng `active via <reason>`, nếu backend có `note`:

```lua
health.warn(cfg.note)
```

Nội dung `note` của ba preset mới, đại ý:

> đọc/ghi input source ID mà thôi. Với IME ngoài (GoTiengViet, EVKey, OpenKey,
> GoNhanh), tiếng Việt và tiếng Anh là **cùng một** input source, nên backend này
> không phân biệt được — cài `tongue` nếu bạn dùng loại IME đó.

Đây là cái giá phải trả cho quyết định auto-detect. Không có dòng này thì việc
tự chọn `macism` là một cú hạ cấp im lặng, nhắm đúng vào thứ plugin sinh ra để
chống. Nó là `warn` chứ không phải `info`: backend vẫn chạy, chỉ là có thể đang
chạy vô ích.

### 8. Test — `tests/backend_spec.lua` (mới)

Thêm `"backend"` vào danh sách spec trong `tests/run.lua`, đặt ngay sau
`"sanitize"`.

Các khẳng định:

| | |
|---|---|
| Darwin có đủ ba binary | chọn `tongue` |
| Darwin không có `tongue` | chọn `macism` |
| Darwin chỉ có `im-select` | chọn `im_select` |
| Darwin trắng trơn | `nil`, lý do nhắc tên OS |
| Linux có `fcitx5-remote` | chọn `fcitx5` |
| Windows_NT có `im-select.exe` | chọn `im_select_exe` |
| OS lạ | `nil`, không ném lỗi |
| `backend = "macism"` | ra đúng preset, kể cả khi binary không tồn tại |
| `backend = "im-select"` và `"im_select"` | cùng ra một preset |
| `backend = "im-select.exe"` | ra `im_select_exe` |
| `backend = "khong-co-that"` | lỗi có liệt kê tên hợp lệ |
| `english = "..."` đè lên preset auto-detect | backend trả về đổi, **và** `presets.macism.english` không đổi |
| `backend = "tongue", english = "us"` | lỗi tokens |
| `english = 42` / `""` | lỗi |
| `SSH_TTY` có đặt, `backend` tự khai | vẫn thắng |
| `SSH_TTY` có đặt, không khai gì | `nil` |

Ca deepcopy quan trọng hơn vẻ ngoài của nó: nó là ca duy nhất phân biệt được bản
cài đúng với bản làm hỏng bảng preset dùng chung.

`sanitize_spec.lua` giữ nguyên. `state_spec`, `health_spec`, `wiring_spec` không
đổi — chúng vẫn tự khai backend riêng.

### 9. Tài liệu

- `README.md`: bảng Requirements liệt kê macism/im-select/im-select.exe; mục
  Custom backends nói về dạng chuỗi và `english`; đoạn "Windows không được dò tự
  động" ở dòng 112–118 phải viết lại vì nó vừa hết đúng.
- `doc/tongue.txt`: khối config (dòng 56) và mục preset (dòng 115).

## Kiểm chứng

| Hạng mục | Kiểm được thật? |
|---|---|
| `resolve` cả ba chuỗi OS, gồm Windows | có — prober tiêm được |
| deepcopy, validate-sau-khi-đè, lỗi tên preset | có |
| health in `note` | có, qua `health_spec` |
| Máy trạng thái không hồi quy | có, bộ test hiện tại |
| `macism` chạy thật trên máy này | **không** — chưa cài. `brew install laishulu/homebrew/macism` thì chạy được end-to-end |
| `im-select.exe` trên Windows thật | **không**, đúng như tiền lệ ở README:113 |

Điểm cuối phải nói thẳng trong README chứ không giấu: chuỗi dò Windows có test,
binary Windows thì không.
