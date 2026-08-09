# WinBoxes Accelerator (wboxes) — Engineering Spec v2

> Bản cải tiến từ prompt gốc. Giữ nguyên toàn bộ ràng buộc kỹ thuật cốt lõi
> (rootless, không KVM, TCG/MTTCG-based, persistent workspace, benchmark
> bắt buộc, thứ tự release), nhưng được tổ chức lại theo từng phase rõ ràng,
> có checklist pass/fail cụ thể, và bổ sung yêu cầu build-system mới:
> `--enable-wboxes` và `--enable-vnc` phải là các configure flag thật của
> QEMU build, kèm code triển khai.

---

## 0. Vai trò & phạm vi

Bạn là Principal Engineer chuyên sâu QEMU / TCG / MTTCG / Dynamic Binary
Translation / JIT / compiler optimization / Linux kernel / performance
engineering. Nhiệm vụ: thiết kế và triển khai accelerator mới tên
**WinBoxes Accelerator (`wboxes`)** cho dự án WinBoxes, dựa trực tiếp trên
source hiện tại:

`https://raw.githubusercontent.com/assassin255/WinBoxes-Source/refs/heads/main/winboxes-stable-3-2.sh`

**Bước 0 bắt buộc:** đọc và phân tích source này trước khi sửa bất cứ gì —
xác định build flow, Rootless/Root/KVM/TCG/PGO/BOLT flow, cách tải `win.img`,
và runtime hiện tại.

---

## 1. Ràng buộc cứng (không thương lượng)

| # | Ràng buộc |
|---|-----------|
| 1 | `wboxes` chạy hoàn toàn userspace/rootless ở **runtime**: không root, sudo, `/dev/kvm`, KVM ioctl, VT-x/AMD-V, hypervisor, `CAP_SYS_ADMIN`, kernel module đặc biệt. |
| 2 | **Tuyệt đối không dùng KVM** ở bất kỳ bước runtime, benchmark, hay workaround nào — không fake KVM, không auto-fallback sang KVM, không dùng KVM làm baseline. |
| 3 | Build/dev/validation **được phép** dùng sudo/root nếu cần cài dependency — nhưng sản phẩm cuối cùng **bắt buộc** rootless. Thiếu root không phải lý do dừng dự án. |
| 4 | Không thay thế/loại bỏ TCG — luôn xây trên nền TCG/MTTCG. |
| 5 | Không embed LLVM, không embed Cranelift, không phụ thuộc runtime của chúng. Có thể tham khảo ý tưởng thuật toán. |
| 6 | Toàn bộ source, build tree, win.img, `.wboxes` cache, benchmark log **không được sống duy nhất trong `/tmp`** — phải nằm trong persistent workspace (`$HOME/WinBoxes`, `$HOME/.cache/winboxes`, v.v.). |
| 7 | AppImage cuối cùng không được yêu cầu sudo/root/KVM/system-wide install. |

---

## 2. Kiến trúc mục tiêu

```
Guest ISA → TCG Frontend → TCG IR → WinBoxes Optimizer → Improved TCG Backend → Host Machine Code
```

`-accel wboxes` phải là accelerator **thật** được QEMU nhận diện qua
`AccelClass`/`AccelOpsClass` (không phải wrapper shell giả lập). Wrapper
bash chỉ dùng cho build/config/runtime management, không phải implementation.

### CLI phải hỗ trợ đầy đủ:

- `-accel wboxes` ⇔ `-accel wboxes,mo=auto,file=auto` (mặc định)
- `-accel wboxes,mo=auto`
- `-accel wboxes,file=auto`
- `-accel wboxes,mo=0|1|2|3`
- `-accel wboxes,file=<path .wboxes>` (thủ công)
- Mọi tổ hợp `mo=` × `file=`

---

## 3. Memory Optimize (MO) — runtime optimizer, KHÔNG PHẢI PGO

- Hoạt động **trong lúc VM đang chạy**: không rebuild, không restart, không recompilation.
- `mo=auto` phải thật sự adaptive: tự chọn sampling frequency, hot-path
  threshold, optimization level, worker count, TB size, prefetch,
  speculative translation, cache strategy — dựa trên workload, CPU, RAM,
  hotness, translation overhead, memory pressure.
- Thành phần bắt buộc: Adaptive Sampling, Hot Path Detection, Branch Heat
  Map, Speculative Translation, Translation Prefetch, Translation
  Deduplication, Adaptive TB Size, Self-Cleaning Cache, Background
  Optimization/Translation/Cache Flush, Intelligent Cache Eviction.
- Chỉ optimize TB có giá trị (không profile mọi TB liên tục).
- Optimization pipeline nhẹ, tự hiện thực (không LLVM/Cranelift):
  Constant Folding/Propagation, Copy Propagation, DCE, Peephole, Strength
  Reduction, lightweight CSE, Instruction Combining, Redundant Move
  Elimination, Register/Instruction Selection improvements, Branch/Basic
  Block Layout, Fast/Cold Path split.
- Correctness > performance: optimization unsafe phải fallback ngay về TCG thường.

### `.wboxes` persistent profile (file=auto)

- Tự tìm/chọn cache phù hợp trong `$XDG_CACHE_HOME` / `$HOME/.cache/winboxes`.
- Validate bằng guest image hash, QEMU version, WinBoxes version, CPU
  features. Auto-invalidate nếu không tương thích, auto-tạo mới nếu chưa có.
- Không yêu cầu restart VM để MO bắt đầu hoạt động.

---

## 4. Multi-threading

- Tự động phát hiện CPU/core, tự bật MTTCG khi hỗ trợ, tự chọn worker
  count, cân bằng CPU, tránh oversubscription, tune affinity khi có lợi.
  Người dùng **không** cần thêm option.
- Worker roles (chỉ tạo khi cần): Translation, Optimization, Analysis,
  Prediction, Cache, Compression, Flush, Prefetch.
- Ưu tiên lock-free/MPSC/SPSC queue, giảm global mutex.
- Nếu MTTCG không khả dụng → fallback về TCG userspace an toàn nhất.
  **Không bao giờ fallback sang KVM.**

---

## 5. Rootless runtime & persistent workspace

- Không hard-code `/usr/local`, `/opt`, `/root`.
- Mọi dữ liệu runtime dùng `$HOME`, `$XDG_CACHE_HOME`, `$XDG_DATA_HOME`.
- Nếu `winboxes-stable-3-2.sh` có apt/sudo/setcap/`/dev/kvm` → tách khỏi
  Rootless Runtime, không biến thành dependency bắt buộc.
- Trước build/test dài hoặc thay đổi lớn: đảm bảo trạng thái source đã
  được lưu persistent. Sau sandbox restart: kiểm tra persistent workspace,
  khôi phục state, không tải/build lại thứ đã có nếu không cần.

---

## 6. Build & Validation pipeline (bắt buộc theo thứ tự)

1. Đọc + phân tích source gốc.
2. Xác định integration point thật trong QEMU (`accel/`, `AccelClass`, `AccelOpsClass`).
3. Tạo accelerator integration thật, build rootless.
4. Worker infrastructure.
5. MO / hot-path / cache.
6. TCG IR / codegen optimization.
7. Persistent `.wboxes`.
8. Build QEMU → tải **đúng** `win.img` (URL có sẵn trong source gốc) bằng `aria2c`, lưu vào persistent workspace.
9. Boot `win.img` bằng `-accel wboxes,mo=auto,file=auto`.
10. Xác nhận Windows **thực sự tới Lock Screen** (VNC/framebuffer/console detection — process còn sống KHÔNG tính là pass).
11. Benchmark bắt buộc: cùng QEMU build/host/img/hardware, baseline = `-accel tcg,thread=multi`. Đo thời gian tới Lock Screen, nhiều lần, báo cáo median/average, CPU%, RAM, translation latency, worker overhead.
    - Ngưỡng: ≥10% nhanh hơn = đạt tối thiểu, ≥20% tốt, ≥30% rất tốt. Chậm hơn TCG → không được tuyên bố thành công, phải tìm bottleneck và lặp lại.
12. Chỉ sau khi Direct Boot PASS + Benchmark PASS → đóng gói AppImage.
13. Test chính AppImage trong rootless environment sạch (không sudo) → Lock Screen PASS → benchmark lại.

### Final release checklist

- [ ] Build PASS
- [ ] Direct QEMU boot PASS
- [ ] Windows Lock Screen PASS
- [ ] wboxes benchmark PASS (≥10%)
- [ ] TCG MTTCG baseline PASS
- [ ] AppImage build PASS
- [ ] AppImage rootless execution PASS
- [ ] AppImage Windows Lock Screen PASS
- [ ] AppImage benchmark PASS

---

## 7. **MỚI:** Build-system flags `--enable-wboxes` và `--enable-vnc`

Yêu cầu bổ sung: QEMU `configure` phải public hai flag thật, dùng được ở
build time:

```
./configure --enable-wboxes --enable-vnc ...
./configure --disable-wboxes --disable-vnc ...
```

### 7.1 `--enable-vnc`

QEMU upstream **đã có sẵn** `vnc` như một `meson` feature option (không
cần code mới) — nó chỉ cần được bắt buộc bật trong build script của
WinBoxes vì `wboxes` dùng VNC để detect Lock Screen ở bước 6.10. Trong
`meson_options.txt` của QEMU đã có:

```meson
option('vnc', type: 'feature', value: 'auto',
       description: 'VNC server')
```

→ Việc cần làm chỉ là: trong script build của WinBoxes, thêm kiểm tra bắt
buộc và fail sớm nếu VNC không khả dụng, vì pipeline validation (bước 6.10)
phụ thuộc vào nó:

```bash
# winboxes build script — enforce VNC availability
if ! meson introspect "$BUILD_DIR" --buildoptions 2>/dev/null \
      | grep -q '"name": "vnc".*"value": "enabled"'; then
  echo "[wboxes] ERROR: QEMU build must be configured with --enable-vnc" >&2
  echo "[wboxes] VNC is required for Lock Screen detection in the boot/benchmark pipeline." >&2
  exit 1
fi
```

### 7.2 `--enable-wboxes` (flag mới — cần code)

Đây là accelerator mới nên cần đăng ký một **feature option mới** trong
build system của QEMU, tương tự cách `--enable-tcg` / `--enable-kvm` được
định nghĩa.

**Bước 1 — `meson_options.txt` (root QEMU source):**

```meson
option('wboxes', type: 'feature', value: 'auto',
       description: 'WinBoxes Accelerator (wboxes): rootless, TCG-based ' +
                     'runtime optimizer with adaptive Memory Optimize (MO) ' +
                     'and persistent .wboxes profile cache')
```

**Bước 2 — `meson.build` (root), đăng ký subdir và config define:**

```meson
wboxes = get_option('wboxes') \
    .disable_auto_if(not have_system) \
    .require(targetos != 'windows',
             error_message: 'wboxes is only supported on POSIX hosts')

config_all_accel += {'CONFIG_WBOXES': wboxes.allowed()}
config_host_data.set('CONFIG_WBOXES', wboxes.allowed())

if wboxes.allowed()
  subdir('accel/wboxes')
endif
```

**Bước 3 — `accel/meson.build`, thêm nhánh accelerator mới:**

```meson
specific_ss.add(when: 'CONFIG_TCG', if_true: files('accel-common.c'))
if config_all_accel['CONFIG_WBOXES']
  subdir('wboxes')
endif
```

**Bước 4 — `accel/wboxes/meson.build` (thư mục mới):**

```meson
wboxes_ss = ss.source_set()
wboxes_ss.add(files(
  'wboxes-accel-ops.c',   # AccelOpsClass implementation
  'wboxes-accel.c',       # AccelClass / TYPE_WBOXES_ACCEL registration
  'wboxes-mo.c',          # Memory Optimize runtime engine
  'wboxes-cache.c',       # .wboxes persistent profile load/validate/save
  'wboxes-worker.c',      # worker pool (translation/opt/prefetch/etc.)
))
specific_ss.add_all(when: 'CONFIG_WBOXES', if_true: wboxes_ss)
```

**Bước 5 — đăng ký accelerator type (`accel/wboxes/wboxes-accel.c`),
theo đúng pattern QEMU dùng cho `accel/tcg/tcg-all.c`:**

```c
#include "qemu/osdep.h"
#include "qemu/accel.h"
#include "sysemu/accel-ops.h"
#include "hw/boards.h"
#include "qapi/error.h"

static int wboxes_accel_init(AccelState *as, MachineState *ms)
{
    /* Reuse TCG's execution engine; wboxes never replaces TCG,
     * it wraps/augments TB translation & codegen via wboxes-mo.c. */
    if (!tcg_enabled_check_prereqs(&error_fatal)) {
        return -1;
    }
    wboxes_mo_init(ms);        /* starts MO runtime, worker pool */
    wboxes_cache_autoload();   /* file=auto profile resolution   */
    return 0;
}

static void wboxes_accel_class_init(ObjectClass *oc, void *data)
{
    AccelClass *ac = ACCEL_CLASS(oc);
    ac->name = "wboxes";
    ac->init_machine = wboxes_accel_init;
    ac->allowed = &wboxes_allowed;
    ac->gdbstub_supported_sstep_flags = wboxes_gdbstub_sstep_flags;
}

static const TypeInfo wboxes_accel_type = {
    .name = ACCEL_CLASS_NAME("wboxes"),
    .parent = TYPE_ACCEL,
    .class_init = wboxes_accel_class_init,
};

static void wboxes_type_init(void)
{
    type_register_static(&wboxes_accel_type);
}
type_init(wboxes_type_init);
```

**Bước 6 — parse `mo=`/`file=` options.** QEMU accelerators nhận options
qua `-accel wboxes,key=val` tự động thành `QemuOpts` cho group `"accel"`;
thêm trong `wboxes-accel-ops.c`:

```c
static void wboxes_accel_ops_init(AccelOpsClass *ops)
{
    ops->create_vcpu_thread = tcg_start_vcpu_thread; /* reuse TCG vCPU loop */
    ops->handle_interrupt   = tcg_handle_interrupt;
}

/* Called from vl.c during -accel option parsing */
void wboxes_parse_accel_opts(QemuOpts *opts)
{
    const char *mo   = qemu_opt_get(opts, "mo");   /* auto|0|1|2|3 */
    const char *file = qemu_opt_get(opts, "file");  /* auto|<path> */

    wboxes_config.mo_mode = mo ? wboxes_parse_mo(mo) : WBOXES_MO_AUTO;
    wboxes_config.cache_path = file
        ? (g_strcmp0(file, "auto") == 0 ? NULL : g_strdup(file))
        : NULL;  /* NULL => auto-resolve in wboxes_cache_autoload() */
}
```

**Bước 7 — build script (WinBoxes side) truyền flag qua đúng configure:**

```bash
./configure \
  --target-list=x86_64-softmmu \
  --enable-tcg \
  --enable-vnc \
  --enable-wboxes \
  --disable-kvm \
  --prefix="$HOME/.local/winboxes"
```

**Bước 8 — CI guard:** build phải fail nếu `CONFIG_WBOXES` không bật khi
target là rootless release build:

```bash
if ! grep -q '^CONFIG_WBOXES=y' "$BUILD_DIR/config-host.mak"; then
  echo "[wboxes] FATAL: build did not enable wboxes accelerator." >&2
  exit 1
fi
```

> Ghi chú: tên file/hàm ở trên là khung tham chiếu theo đúng convention
> hiện có của QEMU (`accel/tcg/tcg-all.c`, `accel/qtest/qtest.c`) — khi
> triển khai thật, cần đối chiếu chính xác API của phiên bản QEMU đang
> dùng (`AccelOpsClass`, `AccelClass` có thể khác field giữa các version).

---

## 8. Development strategy (không cần hỏi lại phase)

Tự động chuyển phase sau khi phase hiện tại pass validation. Chỉ báo cáo
blocker khi có kernel/container restriction thật sự không thể workaround
bằng userspace. Production-quality code: không placeholder, không TODO
giả, không skeleton rồi tuyên bố hoàn thành. Mọi optimization phải có lý
do kỹ thuật + benchmark đi kèm.
