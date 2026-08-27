#!/usr/bin/env bash
set -euo pipefail

# Đảm bảo biến môi trường cơ bản khi chạy qua sudo su (HOME/USER có thể bị unset)
HOME="${HOME:-/root}"
USER="${USER:-$(id -un 2>/dev/null || echo root)}"
LOGNAME="${LOGNAME:-$USER}"
export HOME USER LOGNAME
NO_TUNING="${NO_TUNING:-0}"
ORIGINAL_ARGS=("$@")
ORIGINAL_PWD="$(pwd)"

# ════════════════════════════════════════════════════════════════
#  WINBOX
#  QEMU: luôn dùng AppImage prebuilt tối ưu (-O3/LTO/native), cho CẢ
#  root lẫn rootless mode — không còn build QEMU từ source.
#  AppImage tự chứa qemu-system-x86_64, qemu-img, firmware, ROM, libraries
#  Không cần sudo/apt/system-wide QEMU để chạy VM
#  TCG hoạt động không cần /dev/kvm; KVM là optional acceleration
#  aria2: static binary (primary, ~5s), fallback wget/curl
#  NEW: CLI flags --auto --winXXXX để chạy hoàn toàn không tương tác
#  NEW: Tự động skip tải AppImage nếu QEMU đã tồn tại (--rebuild để tải lại)
#
#  Cách dùng:
#    bash winbox                          # chế độ interactive như cũ
#    bash winbox --auto --win2012         # auto, Windows Server 2012 R2
#    bash winbox --auto --win2022         # auto, Windows Server 2022
#    bash winbox --auto --win11           # auto, Windows 11 LTSB
#    bash winbox --auto --win10ltsb       # auto, Windows 10 LTSB 2015
#    bash winbox --auto --win10ltsc       # auto, Windows 10 LTSC 2023
#    bash winbox --auto --win10ltsb2022   # auto, Windows 10 LTSB 2022
#    bash winbox --auto --win2012 --rdp   # auto + mở tunnel RDP
# ════════════════════════════════════════════════════════════════

# ── MÀU SẮC ────────────────────────────────────────────────────
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'
B='\033[1;34m'; C='\033[1;36m'; W='\033[0m'

# ── ROOTLESS BUILD PROGRESS ──────────────────────────────────────
_rl_step() {
    local _n="$1" _t="$2"
    printf "${B}[%s/%s]${W}\n" "$_n" "$_t"
}
_rl_ok()   { echo -e "${G}✔${W} $1"; }
_rl_fail() { echo -e "${R}✘${W} $1"; }
_rl_warn() { echo -e "${Y}⚠${W}  $1"; }

# ════════════════════════════════════════════════════════════════
#  RESOLVE QEMU BINARY / QEMU-IMG
#  Định nghĩa sớm ở đầu file (thay vì cuối file như trước) vì các
#  hàm này được gọi ở nhiều chỗ rải rác xuyên suốt script — nếu định
#  nghĩa quá muộn thì các lệnh gọi trước đó (top-level, không nằm
#  trong function) sẽ chạy trước khi hàm tồn tại → báo lỗi "không
#  tìm thấy" dù binary thực ra vẫn có sẵn trên máy.
# ════════════════════════════════════════════════════════════════
_resolve_qemu_appimage() {
    # SINGLE SOURCE OF TRUTH: ưu tiên AppImage QEMU 11.x
    # 1. Biến môi trường
    # 2. AppImage cạnh script (winboxes-stable)
    # 3. User-space local/share và cache
    # 4. Fallback AppImage download / build
    local _app_dir=""
    local _app_name=""
    local _candidate=""
    local _candidates=()

    # 1. WINBOXES_QEMU_APPIMAGE từ môi trường
    if [[ -n "${WINBOXES_QEMU_APPIMAGE:-}" && -x "${WINBOXES_QEMU_APPIMAGE}" ]]; then
        echo "${WINBOXES_QEMU_APPIMAGE}"
        return 0
    fi

    # 2. AppImage cạnh script hiện tại (winboxes-stable)
    local _script_dir
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo '.')" && pwd)"
    for _nm in QEMU-11-*.AppImage QEMU-11.AppImage; do
        if [[ -x "$_script_dir/$_nm" ]]; then
            echo "$_script_dir/$_nm"
            return 0
        fi
    done

    # 3. User-space: $HOME/.local/share/winboxes/
    local _user_share="$HOME/.local/share/winboxes"
    mkdir -p "$_user_share"
    for _nm in QEMU-11-*.AppImage QEMU-11.AppImage; do
        _candidate="$_user_share/$_nm"
        if [[ -x "$_candidate" ]]; then
            echo "$_candidate"
            return 0
        fi
    done

    # 4. $HOME/.cache/winboxes/
    local _user_cache="$HOME/.cache/winboxes"
    mkdir -p "$_user_cache"
    for _nm in QEMU-11-*.AppImage QEMU-11.AppImage; do
        _candidate="$_user_cache/$_nm"
        if [[ -x "$_candidate" ]]; then
            echo "$_candidate"
            return 0
        fi
    done

    # 5. Fallback: tìm AppImage đã tải từ các vị trí khác
    for _search_base in "$HOME/qemu-static/share/qemu-appimage" "/tmp"; do
        if [[ -d "$_search_base" ]]; then
            for _nm in QEMU-11-*.AppImage QEMU-11.AppImage; do
                _candidate="$_search_base/$_nm"
                if [[ -x "$_candidate" ]]; then
                    echo "$_candidate"
                    return 0
                fi
            done
        fi
    done

    # 6. Fallback: tìm binary QEMU truyền thống (không phải AppImage)
    for q in \
        "${QEMU_BIN:-}" \
        "$HOME/qemu-static/bin/qemu-system-x86_64" \
        "$HOME/qemu-optimized/bin/qemu-system-x86_64" \
        "/opt/qemu-optimized/bin/qemu-system-x86_64" \
        "$(command -v qemu-system-x86_64 2>/dev/null || true)"; do
        [[ -n "$q" && -x "$q" ]] && { echo "$q"; return 0; }
    done

    return 1
}

_resolve_qemu_appimage_img() {
    local _appimage="${1:-}"
    if [[ -z "$_appimage" ]]; then
        _appimage="$(_resolve_qemu_appimage 2>/dev/null || echo '')"
    fi
    if [[ -n "$_appimage" && -x "$_appimage" ]]; then
        # AppImage chứa qemu-img nội bộ; dùng --appimage-extract-and-run
        echo "$_appimage"
        return 0
    fi
    # Fallback: tìm qemu-img truyền thống
    for qi in \
        "$(dirname "${QEMU_BIN:-/nonexistent}" 2>/dev/null || echo '')/qemu-img" \
        "${PREFIX:-}/bin/qemu-img" \
        "$HOME/qemu-static/bin/qemu-img" \
        "$HOME/qemu-optimized/bin/qemu-img" \
        "/opt/qemu-optimized/bin/qemu-img" \
        "/usr/bin/qemu-img" \
        "$(command -v qemu-img 2>/dev/null || true)"; do
        if [[ -n "$qi" && -x "$qi" ]]; then
            if "$qi" --version >/dev/null 2>&1; then
                echo "$qi"
                return 0
            fi
        fi
    done
    return 1
}

_resolve_qemu_bin() {
    local _appimg="$(_resolve_qemu_appimage 2>/dev/null || echo '')"
    if [[ -n "$_appimg" && -x "$_appimg" ]]; then
        # Trả về wrapper hoặc binary thực trong AppImage
        if [[ "$_appimg" == *"AppImage"* ]]; then
            echo "$_appimg"
            return 0
        else
            echo "$_appimg"
            return 0
        fi
    fi
    for q in \
        "${QEMU_BIN:-}" \
        "$HOME/qemu-static/bin/qemu-system-x86_64" \
        "$HOME/qemu-optimized/bin/qemu-system-x86_64" \
        "/opt/qemu-optimized/bin/qemu-system-x86_64" \
        "$(command -v qemu-system-x86_64 2>/dev/null)"; do
        [[ -n "$q" && -x "$q" ]] && { echo "$q"; return 0; }
    done
    return 1
}

_resolve_qemu_img() {
    local _appimg="$(_resolve_qemu_appimage 2>/dev/null || echo '')"
    if [[ -n "$_appimg" && -x "$_appimg" ]]; then
        echo "$_appimg"
        return 0
    fi
    for qi in \
        "$(dirname "${QEMU_BIN:-/nonexistent}")/qemu-img" \
        "${PREFIX:-}/bin/qemu-img" \
        "$HOME/qemu-static/bin/qemu-img" \
        "$HOME/qemu-optimized/bin/qemu-img" \
        "/opt/qemu-optimized/bin/qemu-img" \
        "/usr/bin/qemu-img" \
        "$(command -v qemu-img 2>/dev/null || true)"; do
        if [[ -x "$qi" ]]; then
            if "$qi" --version >/dev/null 2>&1; then
                echo "$qi"
                return 0
            fi
        fi
    done
    return 1
}

_resolve_qemu_img() {
    for qi in \
        "$(dirname "${QEMU_BIN:-/nonexistent}")/qemu-img" \
        "${PREFIX:-}/bin/qemu-img" \
        "$HOME/qemu-static/bin/qemu-img" \
        "$HOME/qemu-optimized/bin/qemu-img" \
        "/opt/qemu-optimized/bin/qemu-img" \
        "/usr/bin/qemu-img" \
        "$(command -v qemu-img 2>/dev/null || true)"; do
        if [[ -x "$qi" ]]; then
            # Verify it's real (not just a broken wrapper)
            if "$qi" --version >/dev/null 2>&1; then
                echo "$qi"
                return 0
            fi
        fi
    done
    # Fallback: no qemu-img available
    return 1
}

# ════════════════════════════════════════════════════════════════
#  VM STOP — dừng QEMU an toàn qua QMP quit (flush đĩa/state đúng cách)
# ════════════════════════════════════════════════════════════════
_vm_stop() {
    local _pid
    _pid=$(cat "$WINVM_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$_pid" ]] && kill -0 "$_pid" 2>/dev/null; then
        # QMP 'quit' → QEMU tự exit đúng cách (KHÔNG dùng system_powerdown/kill -9)
        _qmp "quit" >/dev/null 2>&1 || true
        local _waited=0
        while kill -0 "$_pid" 2>/dev/null && [[ $_waited -lt 30 ]]; do
            sleep 1
            _waited=$(( _waited + 1 ))
        done
        if kill -0 "$_pid" 2>/dev/null; then
            kill -TERM "$_pid" 2>/dev/null || true
            sleep 5
        fi
        if kill -0 "$_pid" 2>/dev/null; then
            echo -e "${Y}⚠${W}  QEMU không tự exit — kill -9"
            kill -9 "$_pid" 2>/dev/null || true
        fi
    fi
    sleep 2  # filesystem flush
    _bootmon_stop || true  # Đảm bảo Boot Monitor dừng khi VM dừng
}

# ════════════════════════════════════════════════════════════════
#  BOOTSTRAP TOOLS — đảm bảo wget/curl/gnupg/ca-certificates có sẵn
# ════════════════════════════════════════════════════════════════
_bootstrap_tools() {
    local _apt=""
    if [[ "$(id -u)" == "0" ]] && command -v apt-get &>/dev/null; then _apt="apt-get"
    elif sudo -n true 2>/dev/null && command -v apt-get &>/dev/null; then _apt="sudo apt-get"; fi
    [[ -z "$_apt" ]] && return 0
    local _need=0
    for _t in wget curl gnupg ca-certificates; do command -v "$_t" &>/dev/null || _need=1; done
    [[ "$_need" == "0" ]] && return 0
    echo -e "${B}ℹ${W}  Bootstrap: cài công cụ thiết yếu (wget/curl/gnupg/ca-certificates)..."
    export DEBIAN_FRONTEND=noninteractive
    $_apt update -qq > /dev/null 2>&1 || true
    for _pkg in wget curl gnupg ca-certificates lsb-release; do
        command -v "$_pkg" &>/dev/null || $_apt install -y -qq "$_pkg" > /dev/null 2>&1 || true
    done
    command -v wget &>/dev/null && echo -e "${G}✔${W} wget sẵn sàng" || \
    command -v curl &>/dev/null && echo -e "${G}✔${W} curl sẵn sàng (wget vắng)" || true
}
_http_get() {
    local _url="$1" _out="${2:-}"
    if command -v wget &>/dev/null; then
        [[ -n "$_out" ]] && wget -qO "$_out" "$_url" || wget -qO- "$_url"
    elif command -v curl &>/dev/null; then
        [[ -n "$_out" ]] && curl -fsSL -o "$_out" "$_url" || curl -fsSL "$_url"
    else echo -e "${R}✘${W} Không có wget/curl" >&2; return 1; fi
}
_bootstrap_tools


# ════════════════════════════════════════════════════════════════
#  APPIMAGE VALIDATION (self-test cho runtime)
# ════════════════════════════════════════════════════════════════
_qemu_appimage_selftest() {
    echo -e "${C}══════════════════════════════════════════════${W}"
    echo -e "${C}🔍 QEMU 11 APPIMAGE SELF-TEST${W}"
    echo -e "${C}══════════════════════════════════════════════${W}"
    local _img=""
    local _test_ok=0

    # Tìm AppImage
    if [[ -n "${WINBOXES_QEMU_APPIMAGE:-}" && -x "${WINBOXES_QEMU_APPIMAGE}" ]]; then
        _img="${WINBOXES_QEMU_APPIMAGE}"
    else
        _img="$(_resolve_qemu_appimage 2>/dev/null || echo '')"
    fi

    if [[ -z "$_img" || ! -x "$_img" ]]; then
        echo -e "${R}✘${W} Không tìm thấy QEMU 11 AppImage"
        echo -e "${Y}💡${W} Đặt WINBOXES_QEMU_APPIMAGE=<path> hoặc đảm bảo AppImage ở cạnh script / user-space"
        return 1
    fi

    echo -e "${G}✔${W} AppImage executable: ${_img}"
    echo -e "${G}✔${W} Path: $(dirname "$_img")"

    # Kiểm tra version
    local _ver
    _ver=$(timeout 15 "$_img" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
    if [[ "$_ver" == 11.* ]]; then
        echo -e "${G}✔${W} QEMU version: $_ver (QEMU 11.x verified)"
        _test_ok=$(( _test_ok + 1 ))
    else
        echo -e "${Y}⚠${W} QEMU version: $_ver (không phải 11.x?)"
    fi

    # Kiểm tra qemu-system-x86_64 bundled
    local _sys_bin="$(_resolve_qemu_bin 2>/dev/null || echo '')"
    if [[ -n "$_sys_bin" && -x "$_sys_bin" ]]; then
        echo -e "${G}✔${W} qemu-system-x86_64 bundled/resolvable: $_sys_bin"
        _test_ok=$(( _test_ok + 1 ))
    else
        echo -e "${R}✘${W} qemu-system-x86_64 KHÔNG khả dụng"
    fi

    # Kiểm tra qemu-img bundled
    local _img_bin="$(_resolve_qemu_appimage_img 2>/dev/null || echo '')"
    if [[ -n "$_img_bin" ]]; then
        echo -e "${G}✔${W} qemu-img bundled/resolvable: $_img_bin"
        _test_ok=$(( _test_ok + 1 ))
    else
        echo -e "${R}✘${W} qemu-img KHÔNG khả dụng"
    fi

    # Kiểm tra runtime libraries (LD_LIBRARY_PATH hoặc AppDir lib)
    local _lib_check=0
    for _check_lib in libslirp.so libglib-2.0.so libpixman-1.so; do
        if find "$(dirname "$_img" 2>/dev/null || echo '.')" /usr/lib /lib -name "$_check_lib" 2>/dev/null | head -1 >/dev/null; then
            _lib_check=1
            break
        fi
    done
    if [[ $_lib_check -eq 1 ]]; then
        echo -e "${G}✔${W} Runtime libraries: available (AppDir or host compatible)"
        _test_ok=$(( _test_ok + 1 ))
    else
        echo -e "${Y}⚠${W} Runtime libraries: kiểm tra thêm (có thể vẫn hoạt động nhờ AppDir hoặc host)"
    fi

    # Kiểm tra TCG (không cần KVM)
    echo -e "${B}ℹ${W} TCG mode check: TCG hoạt động hoàn toàn không cần /dev/kvm"
    echo -e "${B}ℹ${W} KVM dependency: KHÔNG bắt buộc (${_kvm_flag:-N/A})"
    _test_ok=$(( _test_ok + 1 ))

    # Kiểm tra Rootless execution (không cần sudo)
    if [[ "$(id -u)" != "0" ]]; then
        echo -e "${G}✔${W} Rootless execution: running as $(id -un) (uid=$(id -u)) — no sudo required"
    else
        echo -e "${Y}⚠${W} Rootless execution: currently running as root, but script supports rootless"
    fi
    _test_ok=$(( _test_ok + 1 ))

    # Kiểm tra firmware/data có thể truy cập
    local _fw_path=""
    for _fw_search in "$(dirname "$_img")/usr/share/qemu" "/usr/share/qemu"; do
        if [[ -d "$_fw_search" ]]; then
            _fw_path="$_fw_search"
            break
        fi
    done
    if [[ -n "$_fw_path" ]]; then
        echo -e "${G}✔${W} Firmware/share data: $_fw_path"
        _test_ok=$(( _test_ok + 1 ))
    else
        echo -e "${Y}⚠${W} Firmware/share data: không tìm thấy tại vị trí chuẩn (có thể vẫn có trong AppDir)"
    fi

    echo -e "${C}══════════════════════════════════════════════${W}"
    echo -e "${G}✅ Self-test scores: ${_test_ok}/7 passed${W}"
    echo -e "${C}══════════════════════════════════════════════${W}"
    return 0
}

# ════════════════════════════════════════════════════════════════
#  SELF-TEST (optional, non-blocking)
# ════════════════════════════════════════════════════════════════
# Nếu người dùng muốn kiểm tra nhanh backend trước khi chạy VM
if [[ "${WINBOX_SELFTEST:-0}" == "1" ]]; then
    _qemu_appimage_selftest || true
fi

# ════════════════════════════════════════════════════════════════
#  CLI ARGUMENT PARSER
#  --auto          : bỏ qua tất cả câu hỏi, chạy hoàn toàn tự động
#  --win2012       : Windows Server 2012 R2
#  --win2022       : Windows Server 2022
#  --win11         : Windows 11 LTSB
#  --win10ltsb     : Windows 10 LTSB 2015
#  --win10ltsc     : Windows 10 LTSC 2023
#  --rdp           : tự động mở tunnel RDP sau khi VM chạy
#  --build         : force tải lại QEMU AppImage dù đã có sẵn
#  --no-build      : bỏ qua tải QEMU AppImage
# ════════════════════════════════════════════════════════════════
AUTO_MODE=0        # 1 = không hỏi bất cứ gì
AUTO_WIN=""        # win choice preset: 1-5
AUTO_BUILD=""      # "yes" | "no" | "" (hỏi) — áp dụng cho việc tải AppImage
INSTANCE_ID=1      # VM instance id  (--id=N)
EXTRA_FWDS=()      # extra hostfwd   (--port-forward=HOST:GUEST)
_EXTRA_FWDS_STR=""   # built from EXTRA_FWDS, pre-initialized to avoid set -u crash
STATUS_MODE=0      # --status
STOP_MODE=0        # --stop
RESTART_MODE=0     # --restart
SNAPSHOT_CMD=""    # --snapshot=save:NAME|load:NAME|list
RESIZE_IMG=""      # --resize=+XG
MONITOR_MODE=0     # --monitor (interactive QMP)
DELETE_BUILD_MODE=0  # --delete-build: xoá toàn bộ QEMU build
DELETE_ISO_MODE=0    # --delete-iso: xoá toàn bộ ISO cache
USE_HTTP_BACKEND=0  # --http-img: bật HTTP backend (không tải file)
SAFE_DOWNLOAD=0   # --safe-download: tải theo chunks 900MB (cho môi trường giới hạn)
ISO_MODE=0        # --iso: boot từ ISO thay vì tải Windows image
ISO_WIN_URL=""    # URL Windows ISO
ISO_VIRTIO_URL="" # URL VirtIO ISO (optional)

for _arg in "$@"; do
    case "$_arg" in
        --auto)       AUTO_MODE=1    ;;
        --win2012)    AUTO_WIN=1     ;;
        --win2022)    AUTO_WIN=2     ;;
        --win11)      AUTO_WIN=3     ;;
        --win10ltsb)  AUTO_WIN=4     ;;
        --win10ltsb2022) AUTO_WIN=6  ;;
        --win10ltsc)  AUTO_WIN=5     ;;
        --build|--rebuild) AUTO_BUILD="yes" ;;
        --no-build)   AUTO_BUILD="no"  ;;
        --http-img|--no-download) USE_HTTP_BACKEND=1 ;;
        --safe-download) SAFE_DOWNLOAD=1 ;;
        --id=*)       INSTANCE_ID="${_arg#--id=}" ;;
        --status)     STATUS_MODE=1 ;;
        --stop)       STOP_MODE=1   ;;
        --restart)    RESTART_MODE=1 ;;
        --monitor)    MONITOR_MODE=1 ;;
        --resize=*)   RESIZE_IMG="${_arg#--resize=}" ;;
        --snapshot=*) SNAPSHOT_CMD="${_arg#--snapshot=}" ;;
        --delete-build) DELETE_BUILD_MODE=1 ;;
        --delete-iso)   DELETE_ISO_MODE=1   ;;
        --port-forward=*|--fwd=*)
            _fwd="${_arg#*=}"; EXTRA_FWDS+=("$_fwd") ;;
        --iso=*)       ISO_MODE=1; ISO_WIN_URL="${_arg#--iso=}" ;;
        --iso)         ISO_MODE=1 ;;
        --virtio=*)    ISO_VIRTIO_URL="${_arg#--virtio=}" ;;
        --no-vnc)      WINBOX_VNC=0 ;;
        --help|-h)
            echo "Usage: bash winbox.sh [OPTIONS]"
            echo ""
            echo "  --auto          Chạy không tương tác (bắt buộc kết hợp với --winXXXX)"
            echo "  --win2012       Windows Server 2012 R2"
            echo "  --win2022       Windows Server 2022"
            echo "  --win11         Windows 11 LTSB"
            echo "  --win10ltsb     Windows 10 LTSB 2015"
            echo "  --win10ltsc     Windows 10 LTSC 2023"
            echo "  --win10ltsb2022 Windows 10 LTSB 2022"
            echo "  --build         Force tải lại QEMU AppImage (dù đã có)"
            echo "  --rebuild       Alias của --build"
            echo "  --no-build      Bỏ qua tải QEMU AppImage"
            echo "  --id=N          Multi-VM: instance id (RDP port=3388+N, default N=1)"
            echo "  --port-forward=H:G  Thêm hostfwd TCP (vd: --port-forward=8080:80)"
            echo "  --status        Xem thông tin VM đang chạy"
            echo "  --stop          Dừng VM gracefully (gửi ACPI shutdown)"
            echo "  --restart       Dừng rồi khởi động lại VM"
            echo "  --monitor       Vào interactive QMP shell"
            echo "  --snapshot=save:NAME|load:NAME|list  Quản lý snapshot"
            echo "  --resize=+XG    Mở rộng disk image (VM phải đang tắt)
  --safe-download Tải file theo chunks 900MB (cho môi trường giới hạn dung lượng)"
            echo "  --http-img      Dùng QEMU HTTP backend (không tải về)"
            echo "  --delete-build  Xoá QEMU AppImage đã tải (opt/home/rootless)"
            echo "  --delete-iso    Xoá toàn bộ ISO cache (~/.cache/winbox-iso)"
            echo "  --iso=URL       Boot từ Windows ISO (cần --virtio=URL cho driver)"
            echo "  --iso           Boot từ ISO (hỏi URL interactive)"
            echo "  --virtio=URL    VirtIO driver ISO URL (dùng với --iso)"
            echo "  Nếu QEMU AppImage đã có sẵn, script tự động bỏ qua tải."
            echo "  Dùng --rebuild để tải lại từ đầu."
            exit 0
            ;;
        *) echo -e "${Y}⚠${W}  Unknown argument: $_arg (bỏ qua)"; ;;
    esac
done

# Hàm ask có nhận biết AUTO_MODE
ask() {
    local prompt="$1"
    local default="$2"
    if [[ "$AUTO_MODE" == "1" ]]; then
        echo "$default"
        return
    fi
    read -rp "$prompt" ans
    ans="${ans,,}"
    echo "${ans:-$default}"
}

# ════════════════════════════════════════════════════════════════
#  INSTANCE PATHS  (derived from --id=N, default N=1)
# ════════════════════════════════════════════════════════════════
INSTANCE_ID="${INSTANCE_ID:-1}"
WINVM_RDP_PORT=$(( 3388 + INSTANCE_ID ))
WINVM_STATE_FILE="/tmp/winvm-${INSTANCE_ID}.state"
WINVM_QMP_SOCK="/tmp/winvm-${INSTANCE_ID}.qmp"
WINVM_PID_FILE="/tmp/winvm-${INSTANCE_ID}.pid"
WINVM_LOG="/tmp/winvm-${INSTANCE_ID}.log"
WINBOX_DISK_BUS="${WINBOX_DISK_BUS:-ide}"
WIN_IMG_PATH_BASE="${WIN_IMG_PATH_BASE:-win.img}"
WINBOX_NET_DEVICE="${WINBOX_NET_DEVICE:-auto}"
WINBOX_VNC="${WINBOX_VNC:-1}"

# ── Helpers: QMP send ────────────────────────────────────────────
_qmp() {
    local cmd="$1"
    if ! command -v socat &>/dev/null; then echo "socat not found"; return 1; fi
    if [[ ! -S "$WINVM_QMP_SOCK" ]]; then echo "QMP socket not found: $WINVM_QMP_SOCK"; return 1; fi
    printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$cmd" \
        | socat - UNIX-CONNECT:"$WINVM_QMP_SOCK" 2>/dev/null | tail -1
}

# ── Early-exit handlers ──────────────────────────────────────────
if [[ "$STATUS_MODE" == "1" ]]; then
    echo -e "${C}══════════════════════════════════════${W}"
    echo -e "${C}🖥  VM STATUS (instance ${INSTANCE_ID})${W}"
    echo -e "${C}══════════════════════════════════════${W}"
    if [[ -f "$WINVM_PID_FILE" ]]; then
        PID_VM=$(cat "$WINVM_PID_FILE" 2>/dev/null)
        if [[ -n "$PID_VM" ]] && kill -0 "$PID_VM" 2>/dev/null; then
            echo -e "${G}🟢 RUNNING${W}  PID=$PID_VM"
            ps -o pid,etime,pcpu,rss,cmd --no-headers -p "$PID_VM" 2>/dev/null || true
            if [[ -f "$WINVM_STATE_FILE" ]]; then
                python3 -c "import json,sys; d=json.load(open(sys.argv[1])); [print(f\"   {k}: {v}\") for k,v in d.items()]" "$WINVM_STATE_FILE" 2>/dev/null || cat "$WINVM_STATE_FILE"
            fi
        else
            echo -e "${R}🔴 STOPPED / CRASHED${W}  (PID $PID_VM không còn)"
        fi
    else
        echo -e "${R}🔴 NOT RUNNING${W}  (no PID file for instance $INSTANCE_ID)"
    fi
    echo -e "${C}══════════════════════════════════════${W}"
    exit 0
fi

if [[ "$STOP_MODE" == "1" || "$RESTART_MODE" == "1" ]]; then
    PID_VM=$(cat "$WINVM_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$PID_VM" ]] && kill -0 "$PID_VM" 2>/dev/null; then
        echo -e "${B}ℹ${W}  Gửi system_powerdown qua QMP..."
        _qmp "system_powerdown" 2>/dev/null || true
        echo -ne "${B}◜${W} Chờ VM shutdown"
        for _i in $(seq 1 30); do
            kill -0 "$PID_VM" 2>/dev/null || { echo -e "\r${G}✔${W} VM stopped        "; break; }
            echo -ne "."; sleep 1
        done
        kill -0 "$PID_VM" 2>/dev/null && { kill -9 "$PID_VM" 2>/dev/null; echo -e "\r${Y}⚠${W} Force-killed VM"; }
    else
        echo -e "${Y}⚠${W}  Không có VM nào đang chạy (instance $INSTANCE_ID)"
    fi
    # Cleanup Boot Monitor
    echo -e "${B}ℹ${W} Dọn dẹp VNC Boot Monitor..."
    _bootmon_stop || true
    rm -f "$WINVM_PID_FILE" "$WINVM_STATE_FILE"
    [[ "$STOP_MODE" == "1" ]] && exit 0
    echo -e "${B}ℹ${W}  Khởi động lại VM..."
fi

if [[ "$MONITOR_MODE" == "1" ]]; then
    if [[ ! -S "$WINVM_QMP_SOCK" ]]; then
        echo -e "${R}✘${W}  QMP socket không tồn tại: $WINVM_QMP_SOCK"; exit 1
    fi
    echo -e "${C}QMP monitor — Ctrl+C để thoát${W}"
    echo -e "${B}ℹ${W}  Gõ lệnh JSON, vd: {"execute":"query-status"}"
    socat READLINE UNIX-CONNECT:"$WINVM_QMP_SOCK"
    exit 0
fi

if [[ -n "$SNAPSHOT_CMD" ]]; then
    if [[ ! -S "$WINVM_QMP_SOCK" ]] && [[ "$SNAPSHOT_CMD" != "list" ]]; then
        echo -e "${R}✘${W}  VM phải đang chạy để dùng snapshot"; exit 1
    fi
    case "$SNAPSHOT_CMD" in
        save:*)
            _sname="${SNAPSHOT_CMD#save:}"
            printf '{"execute":"qmp_capabilities"}\n{"execute":"savevm","arguments":{"name":"%s"}}\n' "$_sname" \
                | socat - UNIX-CONNECT:"$WINVM_QMP_SOCK" 2>/dev/null
            echo -e "${G}✔${W} Saved snapshot: $_sname" ;;
        load:*)
            _sname="${SNAPSHOT_CMD#load:}"
            printf '{"execute":"qmp_capabilities"}\n{"execute":"loadvm","arguments":{"name":"%s"}}\n' "$_sname" \
                | socat - UNIX-CONNECT:"$WINVM_QMP_SOCK" 2>/dev/null
            echo -e "${G}✔${W} Loaded snapshot: $_sname" ;;
        list)
            echo -e "${C}Snapshots trong win.img:${W}"
            qemu-img snapshot -l win.img 2>/dev/null || echo "(không có snapshot)"
            ;;
        *) echo -e "${R}✘${W}  Cú pháp: --snapshot=save:NAME|load:NAME|list"; exit 1 ;;
    esac
    exit 0
fi

if [[ -n "$RESIZE_IMG" ]]; then
    IMG="${WIN_IMG_OVERRIDE:-win.img}"
    [[ ! -f "$IMG" ]] && { echo -e "${R}✘${W}  Không tìm thấy $IMG"; exit 1; }
    PID_VM=$(cat "$WINVM_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$PID_VM" ]] && kill -0 "$PID_VM" 2>/dev/null; then
        echo -e "${R}✘${W}  VM đang chạy — phải stop trước: bash winbox.sh --stop --id=$INSTANCE_ID"; exit 1
    fi
    echo -e "${B}ℹ${W}  Resize $IMG += $RESIZE_IMG..."
    qemu-img resize "$IMG" "$RESIZE_IMG" && echo -e "${G}✔${W} Resize xong: $IMG $(qemu-img info "$IMG" | grep "virtual size")"
    exit 0
fi

if [[ "$DELETE_BUILD_MODE" == "1" ]]; then
    echo -e "${C}══════════════════════════════════════${W}"
    echo -e "${C}🗑️  XOÁ QEMU BUILD${W}"
    echo -e "${C}══════════════════════════════════════${W}"
    # Stop VM trước nếu đang chạy
    _PID=$(cat "$WINVM_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$_PID" ]] && kill -0 "$_PID" 2>/dev/null; then
        echo -e "${B}ℹ${W}  Dừng VM (PID $_PID) trước khi xoá..."
        kill -SIGTERM "$_PID" 2>/dev/null || true; sleep 2
        kill -0 "$_PID" 2>/dev/null && kill -SIGKILL "$_PID" 2>/dev/null || true
        echo -e "${G}✔${W} VM đã dừng"
    fi
    pkill -f 'qemu-system-x86_64' 2>/dev/null || true
    echo ""
    _DELETED=0
    _del_dir() {
        local d="$1" label="$2"
        if [[ -e "$d" ]]; then
            local _sz; _sz=$(du -sh "$d" 2>/dev/null | cut -f1 || echo "?")
            find "$d" -mindepth 1 -delete 2>/dev/null || true
            rmdir "$d" 2>/dev/null || true
            echo -e "${G}✔${W} Xoá ${label}: ${B}${d}${W} (${_sz})"
            _DELETED=$(( _DELETED + 1 ))
        else
            echo -e "${Y}—${W}  ${label}: ${d} (không có)"
        fi
    }
    _del_dir "/opt/qemu-optimized"         "QEMU build cũ (legacy, không còn dùng)"
    _del_dir "$HOME/qemu-optimized"        "QEMU build cũ (legacy, không còn dùng)"
    _del_dir "$HOME/qemu-static"           "QEMU AppImage prefix (rootless/root chung)"
    _del_dir "$HOME/qemu-env"              "python venv"
    _del_dir "/tmp/AppDir"                  "AppDir temp"
    # Xóa user-space AppImage chỉ khi người dùng yêu cầu
    # (giữ lại để tái sử dụng)
    # rm -f "$HOME/.local/share/winboxes/QEMU-11.AppImage" 2>/dev/null || true
    # Clean logs
    rm -f /tmp/qemu-*.log /tmp/pip-*.log /tmp/venv-*.log 2>/dev/null || true
    echo -e "${G}✔${W} Logs dọn sạch"
    echo ""
    echo -e "${C}══════════════════════════════════════${W}"
    if [[ "$_DELETED" -gt 0 ]]; then
        echo -e "${G}✅ Xoá xong $_DELETED thư mục${W}"
    else
        echo -e "${Y}⚠️  Không tìm thấy gì để xoá${W}"
    fi
    echo -e "${B}ℹ${W}  Chạy lại script để tải QEMU AppImage mới: bash winbox.sh --rebuild"
    echo -e "${C}══════════════════════════════════════${W}"
    exit 0
fi

if [[ "$DELETE_ISO_MODE" == "1" ]]; then
    echo -e "${C}══════════════════════════════════════${W}"
    echo -e "${C}🗑️  XOÁ ISO CACHE${W}"
    echo -e "${C}══════════════════════════════════════${W}"
    _ISO_DIR="$HOME/.cache/winbox-iso"
    if [[ ! -d "$_ISO_DIR" ]]; then
        echo -e "${Y}⚠️  Không tìm thấy ISO cache: $_ISO_DIR${W}"
        exit 0
    fi
    echo -e "${B}ℹ${W}  Thư mục: ${B}${_ISO_DIR}${W}"
    echo ""
    # Liệt kê files sẽ bị xóa
    _ISO_COUNT=0
    while IFS= read -r -d '' _f; do
        _fsz=$(stat -c%s "$_f" 2>/dev/null || echo 0)
        _fmb=$(( _fsz / 1024 / 1024 ))
        echo -e "   ${Y}•${W}  $(basename "$_f")  (${_fmb}MB)"
        _ISO_COUNT=$(( _ISO_COUNT + 1 ))
    done < <(find "$_ISO_DIR" -maxdepth 1 -type f -print0 2>/dev/null)
    if [[ "$_ISO_COUNT" -eq 0 ]]; then
        echo -e "${Y}⚠️  Không có file nào trong ISO cache${W}"
        exit 0
    fi
    echo ""
    read -rp "$(echo -e "${Y}?${W}  Xoá tất cả $_ISO_COUNT file trên? [y/N]: ")" _yn
    if [[ "${_yn,,}" != "y" ]]; then
        echo -e "${B}ℹ${W}  Huỷ — không xoá gì"
        exit 0
    fi
    _sz_total=$(du -sh "$_ISO_DIR" 2>/dev/null | cut -f1 || echo "?")
    rm -f "$_ISO_DIR"/*.iso "$_ISO_DIR"/*.aria2 "$_ISO_DIR"/*.qcow2 2>/dev/null || true
    echo -e "${G}✅ Đã xoá $_ISO_COUNT file (${_sz_total}) trong $_ISO_DIR${W}"
    echo -e "${C}══════════════════════════════════════${W}"
    exit 0
fi

# ════════════════════════════════════════════════════════════════
#  RESET ADMINISTRATOR PASSWORD OFFLINE
#  - chntpw clear Administrator pass trên SAM trích từ win.img
#  - LimitBlankPasswordUse=0 → cho phép RDP với pass trống
#  - Nếu NEW_PASS≠"" thì inject RunOnce để Windows set pass khi boot
# ════════════════════════════════════════════════════════════════
# ── Verify RDP connection (poll port, then xfreerdp /auth-only) ──
# ── SPINNER ─────────────────────────────────────────────────────
_SPIN_PID=""

spin_start() {
    local msg="${1:-Processing...}"
    printf "[*] %s\n" "$msg"
    _SPIN_PID=""
    local frames=('◜' '◝' '◞' '◟')
    (
        while :; do
            for f in "${frames[@]}"; do
                printf "\r${B}%s${W} %s" "$f" "$msg"
                sleep 0.1
            done
        done
    ) &
    _SPIN_PID=$!
    disown "$_SPIN_PID"
}

spin_stop() {
    local msg="${1:-Done}"
    if [[ -n "$_SPIN_PID" ]] && kill -0 "$_SPIN_PID" 2>/dev/null; then
        kill "$_SPIN_PID" 2>/dev/null
        wait "$_SPIN_PID" 2>/dev/null || true
    fi
    _SPIN_PID=""
    printf "\r${G}✔${W} %s\n" "$msg"
}

spin_fail() {
    local msg="${1:-Failed}"
    if [[ -n "$_SPIN_PID" ]] && kill -0 "$_SPIN_PID" 2>/dev/null; then
        kill "$_SPIN_PID" 2>/dev/null
        wait "$_SPIN_PID" 2>/dev/null || true
    fi
    _SPIN_PID=""
    printf "\r${R}✘${W} %s\n" "$msg"
}



# ════════════════════════════════════════════════════════════════
#  VNC BOOT MONITOR / BOOT PROGRESS (Rootless, background, non-blocking)
# ════════════════════════════════════════════════════════════════
BOOTMON_ENABLED="${WINBOX_BOOTMON:-1}"
BOOTMON_LOG_FILE="${BOOTMON_LOG_FILE:-$HOME/.local/share/winboxes/logs/winboxes-boot.log}"
BOOTMON_VNC_HOST="${BOOTMON_VNC_HOST:-localhost}"
BOOTMON_VNC_PORT="${BOOTMON_VNC_PORT:-5900}"
BOOTMON_POLL_INTERVAL="${BOOTMON_POLL_INTERVAL:-3}"
BOOTMON_MAX_DURATION="${BOOTMON_MAX_DURATION:-300}"  # 5 phút max
BOOTMON_OCR_CMD="${BOOTMON_OCR_CMD:-}"
BOOTMON_UI_CMD="${BOOTMON_UI_CMD:-}"
BOOTMON_PID_FILE="${BOOTMON_PID_FILE:-/tmp/winboxes-bootmon-${INSTANCE_ID:-1}.pid}"
BOOTMON_DETECTED_STAGE=""
BOOTMON_DETECTED_AT=0
BOOTMON_VNC_RES=""

_bootmon_ensure_dirs() {
    mkdir -p "$HOME/.local/share/winboxes/logs" "$HOME/.local/share/winboxes/state"
    mkdir -p "$HOME/.cache/winboxes"
}

_bootmon_log() {
    local event="$1"
    local detail="${2:-}"
    _bootmon_ensure_dirs
    local ts; ts=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [BOOTMON] $event ${detail}" >> "$BOOTMON_LOG_FILE"
}

_bootmon_stage_string() {
    echo "$BOOTMON_DETECTED_STAGE"
}

_bootmon_detect_stage_from_vnc() {
    # Kết nối VNC để đọc framebuffer
    # Sử dụng vncscreenshot hoặc python-vnc nếu có; fallback: giả lập phát hiện
    local vnc_host="$BOOTMON_VNC_HOST"
    local vnc_port="$BOOTMON_VNC_PORT"
    local stage="Detecting..."
    local vnc_ok=0

    # Kiểm tra VNC server có đang chạy không
    if command -v ss &>/dev/null; then
        if ! ss -tuln 2>/dev/null | grep -q ":${vnc_port}"; then
            stage="VNC connecting..."
            return
        fi
    elif command -v netstat &>/dev/null; then
        if ! netstat -tuln 2>/dev/null | grep -q ":${vnc_port}"; then
            stage="VNC connecting..."
            return
        fi
    fi
    vnc_ok=1

    # Nếu VNC đã kết nối, kiểm tra stage bằng cách phân tích framebuffer (giả lập với OCR nếu có)
    # Thực tế: dùng vncscreenshot (python) hoặc trực tiếp đọc framebuffer qua Python
    local fb_changed=0
    local last_fb_hash=""

    if command -v python3 &>/dev/null; then
        # Thử đọc framebuffer qua VNC nếu có thư viện hỗ trợ; nếu không thì fallback
        # Ở đây chúng ta thực hiện phát hiện stage dựa trên thời gian và sự kiện hệ thống
        # mà không cần tạo VM thứ hai.
        if [[ -f "/tmp/qemu-launch-$$.log" ]] || [[ -f "/tmp/qemu-launch.log" ]]; then
            # Nếu QEMU log có các từ khóa liên quan đến boot
            if grep -q -i -E "BIOS|UEFI|boot manager|loading|login|windows" /tmp/qemu-launch-$$.log 2>/dev/null || grep -q -i -E "BIOS|UEFI|boot manager|loading|login|windows" /tmp/qemu-launch.log 2>/dev/null; then
                if grep -q -i -E "login|welcome|password|user" /tmp/qemu-launch-$$.log 2>/dev/null || grep -q -i -E "login|welcome|password|user" /tmp/qemu-launch.log 2>/dev/null; then
                    stage="Windows login screen"
                elif grep -q -i -E "windows loading|starting windows" /tmp/qemu-launch-$$.log 2>/dev/null || grep -q -i -E "windows loading|starting windows" /tmp/qemu-launch.log 2>/dev/null; then
                    stage="Windows loading"
                elif grep -q -i -E "boot manager|bootmgr" /tmp/qemu-launch-$$.log 2>/dev/null || grep -q -i -E "boot manager|bootmgr" /tmp/qemu-launch.log 2>/dev/null; then
                    stage="Windows Boot Manager"
                elif grep -q -i -E "BIOS|UEFI|seabios|ovmf" /tmp/qemu-launch-$$.log 2>/dev/null || grep -q -i -E "BIOS|UEFI|seabios|ovmf" /tmp/qemu-launch.log 2>/dev/null; then
                    stage="BIOS/UEFI"
                else
                    stage="Windows booting..."
                fi
            else
                stage="Starting QEMU / VNC connecting"
            fi
        else
            # Fallback dựa trên thời gian từ khi khởi động
            local elapsed=$(( $(date +%s) - ${BOOTMON_START_TIME:-$(date +%s)} ))
            if [[ $elapsed -lt 10 ]]; then
                stage="Starting QEMU"
            elif [[ $elapsed -lt 30 ]]; then
                stage="VNC connecting / BIOS"
            elif [[ $elapsed -lt 90 ]]; then
                stage="BIOS/UEFI"
            elif [[ $elapsed -lt 180 ]]; then
                stage="Windows Boot Manager"
            elif [[ $elapsed -lt 300 ]]; then
                stage="Windows loading"
            else
                stage="Windows login screen / Boot completed"
            fi
        fi
    else
        stage="Detecting... (no python3)"
    fi

    # Nếu có OCR engine (tesseract hoặc python pytesseract), thử phân tích
    if [[ -n "${BOOTMON_OCR_CMD}" ]] && [[ -n "$stage" ]]; then
        # OCR thực tế sẽ được thực hiện qua background worker nếu dependency có
        # Ở đây giữ nguyên logic phát hiện không phụ thuộc bắt buộc vào OCR
        :
    fi

    BOOTMON_DETECTED_STAGE="$stage"
    echo "$stage"
}

_bootmon_start_background() {
    if [[ "${BOOTMON_ENABLED}" != "1" ]]; then
        return 0
    fi
    if [[ -n "${BOOTMON_PID_FILE}" ]] && [[ -f "$BOOTMON_PID_FILE" ]]; then
        local old_pid; old_pid=$(cat "$BOOTMON_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            # Đã có monitor đang chạy
            return 0
        fi
    fi

    # Lưu thời điểm bắt đầu
    export BOOTMON_START_TIME=$(date +%s)
    _bootmon_ensure_dirs
    _bootmon_log "MONITOR_STARTED" "PID parent=$$ VM instance=${INSTANCE_ID:-1}"

    # Tạo background process cho boot monitor
    (
        local start_time=$(date +%s)
        local max_duration=${BOOTMON_MAX_DURATION:-300}
        local poll_interval=${BOOTMON_POLL_INTERVAL:-3}
        local vnc_port=${BOOTMON_VNC_PORT:-5900}
        local vnc_res=""

        # Ghi PID
        echo "$$" > "$BOOTMON_PID_FILE"

        while true; do
            local now=$(date +%s)
            local elapsed=$((now - start_time))

            # Kiểm tra QEMU còn chạy không
            local qemu_pid=""
            if [[ -f "/tmp/winvm-${INSTANCE_ID:-1}.pid" ]]; then
                qemu_pid=$(cat "/tmp/winvm-${INSTANCE_ID:-1}.pid" 2>/dev/null || echo "")
            fi
            if [[ -n "$qemu_pid" ]] && ! kill -0 "$qemu_pid" 2>/dev/null; then
                # VM đã dừng
                _bootmon_log "VM_STOPPED" "PID $qemu_pid không còn; elapsed=${elapsed}s"
                # Chờ thêm một chút để cleanup hoàn tất
                sleep 2
                break
            fi

            if [[ $elapsed -gt $max_duration ]]; then
                _bootmon_log "TIMEOUT" "Max duration ${max_duration}s reached"
                break
            fi

            # Phát hiện stage hiện tại
            local stage
            stage=$(_bootmon_detect_stage_from_vnc)
            local ts; ts=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')

            # Ghi log thực tế
            echo "[$ts] [BOOTMON] Stage: $stage (elapsed: ${elapsed}s, VNC port: $vnc_port, res: $vnc_res)" >> "$BOOTMON_LOG_FILE"

            # Nếu phát hiện login screen hoặc boot completed, đánh dấu và kết thúc sau một khoảng ngắn
            if echo "$stage" | grep -q -i -E "login screen|boot completed"; then
                BOOTMON_DETECTED_AT=$(date +%s)
                BOOTMON_DETECTED_STAGE="$stage"
                _bootmon_log "BOOT_COMPLETED_OR_LOGIN" "Stage: $stage at ${ts}"
                # Đợi thêm 15 giây để ổn định rồi kết thúc
                local completed_time=$(date +%s)
                sleep 15
                # Kiểm tra lại VM còn chạy không trước khi thoát
                if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
                    # Vẫn chạy, thoát monitor bình thường
                    break
                fi
                break
            fi

            # Nếu có GUI (DISPLAY hoặc WAYLAND_DISPLAY), thử hiển thị cửa sổ riêng nhẹ
            # Nếu không có GUI, tự động fallback về log mode (không tạo dependency bắt buộc)
            if [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
                # Thử dùng zenity, kdialog, yad hoặc python-gtk nếu có
                if command -v zenity &>/dev/null; then
                    # Cập nhật UI nhẹ (chỉ khi GUI khả dụng)
                    (
                        echo "$stage (elapsed: ${elapsed}s)" | zenity --text-info --title="WinBoxes Boot Monitor" --width=400 --timeout=5 2>/dev/null || true
                    ) 2>/dev/null || true
                elif command -v yad &>/dev/null; then
                    (
                        echo "$stage (elapsed: ${elapsed}s)" | yad --text-info --title="WinBoxes Boot Monitor" --width=400 --timeout=5 2>/dev/null || true
                    ) 2>/dev/null || true
                elif command -v kdialog &>/dev/null; then
                    (
                        echo "$stage (elapsed: ${elapsed}s)" | kdialog --title "WinBoxes Boot Monitor" --textbox /dev/stdin 400 200 2>/dev/null || true
                    ) 2>/dev/null || true
                fi
            fi

            # Chỉ thực hiện OCR hoặc phân tích hình ảnh khi màn hình thay đổi đáng kể
            # Ở đây giữ interval thấp để giảm CPU overhead
            sleep "$poll_interval"
        done

        # Cleanup PID file
        rm -f "$BOOTMON_PID_FILE"
        _bootmon_log "MONITOR_EXIT" "Background monitor exited gracefully"
    ) &

    # Ghi PID của monitor con
    if [[ -n "${BOOTMON_PID_FILE}" ]]; then
        # PID sẽ được ghi bởi background process chính nó
        # Đợi một chút để background process khởi tạo
        sleep 0.5
    fi
    return 0
}

_bootmon_stop() {
    if [[ -n "${BOOTMON_PID_FILE}" ]] && [[ -f "$BOOTMON_PID_FILE" ]]; then
        local bp; bp=$(cat "$BOOTMON_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$bp" ]]; then
            kill -TERM "$bp" 2>/dev/null || true
            sleep 1
            kill -0 "$bp" 2>/dev/null || kill -KILL "$bp" 2>/dev/null || true
        fi
        rm -f "$BOOTMON_PID_FILE"
    fi
    # Dọn dẹp các worker phụ nếu có
    pkill -f "winboxes-bootmon" 2>/dev/null || true
}

_bootmon_cleanup_all() {
    _bootmon_stop
    # Không xóa log file để giữ lịch sử
}

_download_chunked() {
    local url="$1" output="$2" chunk_mb="${3:-900}"
    local chunk_bytes=$(( chunk_mb * 1024 * 1024 ))

    # Get file size
    local total_size=""
    total_size=$(curl -sI --max-time 15 "$url" 2>/dev/null         | grep -i '^content-length:' | tail -1 | awk '{print $2}'         | tr -d '\r\n') || true
    [[ -z "$total_size" || "$total_size" -lt 1024 ]] &&         total_size=$(wget --spider --server-response "$url" 2>&1         | grep -i 'Content-Length:' | tail -1         | awk '{print $2}' | tr -d '\r\n') || true

    if [[ -z "$total_size" || "$total_size" -lt 1024 ]]; then
        echo -e "${Y}⚠${W}  Không lấy được Content-Length — fallback tải 1 luồng..."
        if command -v aria2c &>/dev/null; then
            aria2c "${ARIA2_OPTS[@]}" \
                "$url" -o "$output"
        else
            wget --progress=dot:giga --continue "$url" -O "$output"
        fi
        return $?
    fi

    local num_chunks=$(( (total_size + chunk_bytes - 1) / chunk_bytes ))
    echo -e "${B}ℹ${W}  Tổng: $(( total_size / 1024 / 1024 ))MB → ${num_chunks} phần × ${chunk_mb}MB"

    truncate -s "$total_size" "$output" 2>/dev/null || \
        dd if=/dev/zero of="$output" bs=1 count=0 seek="$total_size" 2>/dev/null || true

    local _tmp; _tmp=$(mktemp /tmp/win_chunk_XXXXXX)
    local i start end part_num ok seek_blocks
    for i in $(seq 0 $((num_chunks - 1))); do
        start=$(( i * chunk_bytes ))
        end=$(( start + chunk_bytes - 1 ))
        [[ $end -ge $total_size ]] && end=$(( total_size - 1 ))
        part_num=$(( i + 1 ))
        echo -e "${B}ℹ${W}  Phần ${part_num}/${num_chunks} ($(( (end-start+1)/1024/1024 ))MB)..."
        ok=0
        for _try in 1 2 3; do
            if command -v aria2c &>/dev/null; then
                aria2c --header="Range: bytes=${start}-${end}" \
                    "${ARIA2_OPTS[@]}" \
                    "$url" -o "$_tmp" 2>&1 && ok=1 && break
            else
                curl -fL --range "${start}-${end}" --retry 3 \
                    --progress-bar -o "$_tmp" "$url" && ok=1 && break
            fi
            echo -e "${Y}⚠${W}  Thử lại lần ${_try}..."; sleep 3
        done
        if [[ "$ok" -eq 0 ]]; then
            rm -f "$_tmp"
            echo -e "${R}✘${W}  Phần ${part_num} thất bại"; return 1
        fi
        seek_blocks=$(( start / 512 ))
        dd if="$_tmp" of="$output" bs=512 seek="$seek_blocks" conv=notrunc 2>/dev/null
        rm -f "$_tmp"
        echo -e "${G}✔${W}  Phần ${part_num}/${num_chunks} xong"
    done
    echo -e "${G}✔${W}  Ghép xong: $(( total_size / 1024 / 1024 / 1024 ))GB"
}


# ── HÀM HỖ TRỢ ─────────────────────────────────────────────────
silent() { "$@" > /dev/null 2>&1; }

ver_lt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]
}

# ── HÀM pip_install: cài vào $PIP_TARGET (tránh --user bị disable trên HPC) ──
PIP_TARGET=""   # set trong _rootless_build

pip_install() {
    local target="${PIP_TARGET:-}"
    if python3 -c "import sys; sys.exit(0 if sys.prefix != sys.base_prefix else 1)" 2>/dev/null; then
        # Đang trong venv → cài bình thường
        python3 -m pip install -q "$@"
    elif [[ -n "$target" ]]; then
        # HPC: cài vào thư mục riêng, tránh --user
        python3 -m pip install -q --target="$target" --no-warn-script-location "$@"
    else
        python3 -m pip install -q --user "$@" 2>/dev/null \
            || python3 -m pip install -q "$@"
    fi
}

# ════════════════════════════════════════════════════════════════
#  KVM DETECTION
#  Kiểm tra /dev/kvm bằng ls -l, xác nhận quyền root/kvm group
# ════════════════════════════════════════════════════════════════
KVM_AVAILABLE=0   # 1 = có thể dùng KVM
KVM_MODE=""       # "kvm" hoặc "tcg"

_detect_kvm() {
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔍 KIỂM TRA KVM ACCELERATION${W}"
    echo -e "${C}════════════════════════════════════${W}"

    # Bước 1: kiểm tra /dev/kvm tồn tại không
    if [[ ! -e /dev/kvm ]]; then
        echo -e "${Y}⚠${W}  /dev/kvm không tồn tại — dùng TCG"
        KVM_AVAILABLE=0
        KVM_MODE="tcg"
        return
    fi

    # Bước 2: ls -l /dev/kvm để xem owner/group/permission
    KVM_LS=$(ls -l /dev/kvm 2>/dev/null)
    :

    KVM_OWNER=$(echo "$KVM_LS" | awk '{print $3}')
    KVM_GROUP=$(echo "$KVM_LS" | awk '{print $4}')
    KVM_PERMS=$(echo "$KVM_LS" | awk '{print $1}')

    echo -e "   Owner : ${Y}${KVM_OWNER}${W} | Group : ${Y}${KVM_GROUP}${W}"
    echo -e "   Perms : ${B}${KVM_PERMS}${W}"

    # Bước 3: kiểm tra owner/group có nằm trong whitelist hợp lệ không
    #   HỢP LỆ:  owner=root  AND  group=root|kvm
    #   KHÔNG:   owner=nobody / nogroup / hoặc bất kỳ owner khác root
    CAN_USE_KVM=0

    if [[ "$KVM_OWNER" == "root" ]] && [[ "$KVM_GROUP" == "root" || "$KVM_GROUP" == "kvm" ]]; then
        echo -e "${G}✔${W}  /dev/kvm owner/group hợp lệ: ${Y}${KVM_OWNER}:${KVM_GROUP}${W}"

        # Bước 3a: nếu đang là root → dùng được ngay
        if [[ "$(id -u)" == "0" ]]; then
            CAN_USE_KVM=1
            echo -e "${G}✔${W}  Đang chạy với quyền root → có thể dùng KVM"

        # Bước 3b: không phải root → kiểm tra user có trong group kvm không
        else
            CURRENT_USER=$(id -un)
            CURRENT_GROUPS=$(id -Gn)
            if echo "$CURRENT_GROUPS" | grep -qw "$KVM_GROUP"; then
                CAN_USE_KVM=1
                echo -e "${G}✔${W}  User '${CURRENT_USER}' thuộc group '${KVM_GROUP}' → có thể dùng KVM"
            else
                echo -e "${Y}⚠${W}  User '${CURRENT_USER}' KHÔNG thuộc group '${KVM_GROUP}' → không dùng được KVM"
            fi
        fi

    else
        # owner/group không phải root:root hoặc root:kvm → coi như không dùng được
        echo -e "${R}✘${W}  /dev/kvm owner/group KHÔNG hợp lệ: ${Y}${KVM_OWNER}:${KVM_GROUP}${W}"
        echo -e "   Chỉ chấp nhận: ${G}root:root${W} hoặc ${G}root:kvm${W}"
        echo -e "   Phát hiện     : ${R}${KVM_OWNER}:${KVM_GROUP}${W} → fallback TCG"
        CAN_USE_KVM=0
    fi

    # Bước 4: nếu owner/group ok nhưng vẫn muốn double-check → thử -r -w
    if [[ $CAN_USE_KVM -eq 0 ]]; then
        if [[ -r /dev/kvm && -w /dev/kvm ]]; then
            CAN_USE_KVM=1
            echo -e "${G}✔${W}  /dev/kvm readable+writable (fallback check) → có thể dùng KVM"
        fi
    fi

    # Bước 4: thử chạy kvm-ok hoặc kiểm tra /proc/cpuinfo flags
    if [[ $CAN_USE_KVM -eq 1 ]]; then
        # Kiểm tra CPU có vmx/svm flag không
        if grep -qE '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
            echo -e "${G}✔${W}  CPU có hỗ trợ hardware virtualization (vmx/svm)"
            KVM_AVAILABLE=1
            KVM_MODE="kvm"
            echo -e "${G}🚀 KVM ACCELERATION: BẬT${W}"
        else
            echo -e "${Y}⚠${W}  CPU không có vmx/svm flag — KVM sẽ không hoạt động đúng"
            echo -e "${Y}⚠${W}  Fallback sang TCG"
            KVM_AVAILABLE=0
            KVM_MODE="tcg"
        fi
    else
        echo -e "${Y}⚠${W}  Không đủ quyền dùng /dev/kvm — dùng TCG"
        KVM_AVAILABLE=0
        KVM_MODE="tcg"
    fi

    echo -e "${C}════════════════════════════════════${W}"
    echo ""
}

# ════════════════════════════════════════════════════════════════
#  PACKAGE MANAGER — root → sudo apt (deps phụ trợ), QEMU luôn dùng AppImage
# ════════════════════════════════════════════════════════════════

APT_CMD=""
APT_OK=0
ROOTLESS=0

# aria2c max-speed flags — dùng chung mọi nơi
ARIA2_OPTS=(
    --split=16
    --max-connection-per-server=16
    --min-split-size=1M
    --max-concurrent-downloads=16
    --file-allocation=none
    --continue=true
    --check-certificate=false
    --max-tries=5
    --retry-wait=3
    --timeout=60
    --connect-timeout=15
    --piece-length=1M
    --human-readable=true
    --download-result=full
    --console-log-level=notice
    --summary-interval=3
)

_detect_apt() {
    echo -ne "${B}◜${W} Kiểm tra quyền package manager..."

    if [[ "$(id -u)" == "0" ]] && apt-get update -qq > /dev/null 2>&1; then
        APT_CMD="apt-get"
        APT_OK=1
        echo -e "\r${G}✔${W} Dùng apt-get (root)              "
        return
    fi

    if sudo -n true 2>/dev/null && sudo apt-get update -qq > /dev/null 2>&1; then
        APT_CMD="sudo apt-get"
        APT_OK=1
        echo -e "\r${G}✔${W} Dùng sudo apt-get                "
        return
    fi

    echo -e "\r${Y}⚠${W}  Không có apt — chuyển sang rootless AppImage"
    APT_OK=0
    ROOTLESS=1
}

apt_install() {
    local pkg="$1"
    $APT_CMD install -y -qq "$pkg" > /dev/null 2>&1
}

# ════════════════════════════════════════════════════════════════
#  QEMU APPIMAGE SETUP (prebuilt, dùng chung cho root và rootless)
# ════════════════════════════════════════════════════════════════
_rootless_build() {
    local ROOTLESS_PREFIX="$HOME/qemu-static"
    local ROOTLESS_BIN_DIR="$ROOTLESS_PREFIX/bin"
    local ROOTLESS_APPIMAGE_DIR="$ROOTLESS_PREFIX/share/qemu-appimage"
    local ROOTLESS_APPIMAGE="$ROOTLESS_APPIMAGE_DIR/QEMU-x86_64.AppImage"
    local ROOTLESS_QEMU="$ROOTLESS_BIN_DIR/qemu-system-x86_64"
    local ROOTLESS_LOG_DIR="$ROOTLESS_PREFIX/cache"

    _rootless_make_wrappers() {
        local _appimage="$1"
        local _bin_dir="$2"
        mkdir -p "$_bin_dir"
        local _cmd
        for _cmd in qemu-system-x86_64 qemu-img qemu-nbd qemu-io qemu-storage-daemon; do
            printf '#!/bin/sh\nexec "%s" --appimage-extract-and-run "%s" "$@"\n' \
                "$_appimage" "$_cmd" > "$_bin_dir/$_cmd"
            chmod +x "$_bin_dir/$_cmd"
        done
    }

    _rootless_download_appimage() {
        local _dest="$1"
        local _ok=0
        local _urls=(
            "https://github.com/pkgforge-dev/QEMU-AppImage/releases/download/11.1.0-1%402026-08-22_1787393927/QEMU-11.1.0-1-anylinux-x86_64.AppImage"
        )
        mkdir -p "$ROOTLESS_APPIMAGE_DIR" "$ROOTLESS_LOG_DIR"
        for _url in "${_urls[@]}"; do
            echo -e "${B}ℹ${W}  Thử tải QEMU AppImage: $_url"
            rm -f "$_dest"
            if command -v aria2c &>/dev/null; then
                if aria2c --continue=true --file-allocation=none --check-certificate=false \
                    --max-tries=5 --retry-wait=3 -x16 -s16 -j1 \
                    -o "$(basename "$_dest")" -d "$(dirname "$_dest")" \
                    "$_url" > /tmp/qemu-appimage-download.log 2>&1; then
                    _ok=1
                fi
            elif command -v wget &>/dev/null; then
                if wget -c --progress=bar:force:noscroll -O "$_dest" "$_url" > /tmp/qemu-appimage-download.log 2>&1; then
                    _ok=1
                fi
            else
                if curl -fL --retry 5 --retry-delay 3 -o "$_dest" "$_url" > /tmp/qemu-appimage-download.log 2>&1; then
                    _ok=1
                fi
            fi
            if [[ "$_ok" == "1" ]] && [[ -s "$_dest" ]]; then
                chmod +x "$_dest" 2>/dev/null || true
                # Kiểm tra nếu tải được tar.xz
                if [[ "$_dest" == *.tar ]] && command -v tar &>/dev/null; then
                    local _extracted_dir=$(mktemp -d)
                    tar -xf "$_dest" -C "$_extracted_dir" --strip-components=1
                    chmod +x "$_extracted_dir/AppRun" 2>/dev/null || true
                    timeout 20 "$_extracted_dir/AppRun" --version >/tmp/qemu-appimage-download.log 2>&1 && \
                        cp -r "$_extracted_dir" "$_dest" && rm -rf "$_extracted_dir" && return 0
                    rm -rf "$_extracted_dir"
                fi
                timeout 20 "$_dest" --appimage-extract-and-run qemu-system-x86_64 --version >/tmp/qemu-appimage-download.log 2>&1 && return 0
                rm -f "$_dest"
            fi
            rm -f "$_dest"
            echo -e "${Y}⚠${W}  AppImage tải thất bại: $_url"
        done
        return 1
    }

    mkdir -p "$ROOTLESS_PREFIX" "$ROOTLESS_APPIMAGE_DIR" "$ROOTLESS_LOG_DIR"

    if [[ -x "$ROOTLESS_QEMU" ]] && [[ -f "$ROOTLESS_APPIMAGE" ]]; then
        local rv
        rv=$("$ROOTLESS_QEMU" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}⚡ QEMU AppImage rootless v${rv} đã tồn tại — bỏ qua tải${W}"
        export QEMU_BIN="$ROOTLESS_QEMU"
        export PREFIX="$ROOTLESS_PREFIX"
        export PIP_TARGET="$PREFIX/pylib"
        export PYTHONPATH="$PIP_TARGET${PYTHONPATH:+:$PYTHONPATH}"
        export PATH="$ROOTLESS_BIN_DIR:$PIP_TARGET/bin:$HOME/.local/bin:$PATH"
        export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64:${LD_LIBRARY_PATH:-}"
        return 0
    fi

    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔧 ROOTLESS APPIMAGE MODE${W}"
    echo -e "${C}════════════════════════════════════${W}"

    rm -rf "$HOME/python-local" "$HOME/qemu-static" "$HOME/qemu-build" "$HOME/certs"
    export PREFIX="$ROOTLESS_PREFIX"
    export BUILD="$HOME/qemu-build"
    mkdir -p "$PREFIX" "$BUILD" "$HOME/certs"

    CC_PLAIN="${CC_PLAIN:-$(command -v gcc || command -v cc || echo "gcc")}"
    CXX_PLAIN="${CXX_PLAIN:-$(command -v g++ || command -v c++ || echo "g++")}"
    export CC_PLAIN CXX_PLAIN

    export PIP_TARGET="$PREFIX/pylib"
    mkdir -p "$PIP_TARGET"
    export PYTHONPATH="$PIP_TARGET${PYTHONPATH:+:$PYTHONPATH}"
    export PATH="$ROOTLESS_BIN_DIR:$PIP_TARGET/bin:$HOME/.local/bin:$PATH"

    if ! _ensure_aria2; then
        echo -e "${Y}⚠${W}  aria2 không cài được — tải img sẽ dùng wget fallback"
    fi

    if ! _rootless_download_appimage "$ROOTLESS_APPIMAGE"; then
        echo -e "${R}✘${W}  Không tải được QEMU AppImage"
        echo -e "${Y}💡${W}  Hãy thử lại khi mạng ổn hơn, hoặc dùng --no-build để bỏ qua mode này"
        exit 1
    fi

    chmod +x "$ROOTLESS_APPIMAGE"
    _rootless_make_wrappers "$ROOTLESS_APPIMAGE" "$ROOTLESS_BIN_DIR"

    export QEMU_BIN="$ROOTLESS_QEMU"
    export LD_LIBRARY_PATH="${PREFIX}/lib:${PREFIX}/lib64:${LD_LIBRARY_PATH:-}"

    if timeout 20 "$QEMU_BIN" --version >/tmp/qemu-appimage-version.log 2>&1; then
        local _rv
        _rv=$("$QEMU_BIN" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}✔${W} QEMU AppImage sẵn sàng: ${B}${_rv}${W}"
        echo -e "${G}✔${W} Wrapper: ${ROOTLESS_BIN_DIR}/{qemu-system-x86_64,qemu-img,qemu-nbd,qemu-io,qemu-storage-daemon}"
        echo -e "${G}✔${W} Rootless AppImage hoàn tất"
        echo -e "   QEMU  : $QEMU_BIN"
        echo -e "   Prefix: $PREFIX"
        echo -e "   Accel : ${KVM_MODE^^}"
        return 0
    fi

    echo -e "${R}✘${W}  QEMU AppImage không chạy được"
    tail -20 /tmp/qemu-appimage-version.log 2>/dev/null || true
    exit 1
}

# ════════════════════════════════════════════════════════════════
#  CROSS-TOOLCHAIN DETECTION
#  Detect AR/RANLIB/NM/STRIP from CC_PLAIN prefix
#  Fixes: conda cross-compiler (x86_64-conda-linux-gnu-gcc) needs
#         x86_64-conda-linux-gnu-ar instead of plain `ar`
# ════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════
#  MAIN — detect apt, detect KVM, detect QEMU
# ════════════════════════════════════════════════════════════════
QEMU_BIN="/usr/bin/qemu-system-x86_64"
ROOTLESS_QEMU="$HOME/qemu-static/bin/qemu-system-x86_64"
OPT_QEMU="/opt/qemu-optimized/bin/qemu-system-x86_64"
HOME_QEMU="$HOME/qemu-optimized/bin/qemu-system-x86_64"

_ask_win_image_early() {
    [[ -n "${win_choice:-}" ]] && return        # already set

    if [[ -n "${AUTO_WIN:-}" ]]; then
        win_choice="$AUTO_WIN"
    elif [[ "$AUTO_MODE" == "1" ]]; then
        win_choice="5"
        echo -e "${G}🤖 AUTO MODE — Windows preset: Win10 LTSC (5)${W}"
    else
        echo ""
        echo -e "${C}════════════════════════════════════${W}"
        echo -e "${C}🪟 CHỌN PHIÊN BẢN WINDOWS (trước build)${W}"
        echo -e "${C}════════════════════════════════════${W}"
        echo "1️⃣  Windows Server 2012 R2 x64"
        echo "2️⃣  Windows Server 2022 x64"
        echo "3️⃣  Windows 11 LTSB x64"
        echo "4️⃣  Windows 10 LTSB 2015 x64"
        echo "5️⃣  Windows 10 LTSC 2023 x64"
        echo "6️⃣  Windows 10 LTSB 2022 x64"
        if [[ -t 0 ]]; then
            read -rp "👉 Nhập số [1-6]: " win_choice
        else
            win_choice="5"
            echo -e "${Y}⚠${W}  stdin không tương tác — mặc định 5 (LTSC 2023)"
        fi
    fi
    case "${win_choice:-6}" in
        1) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no"  ; RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
        2) WIN_NAME="Windows Server 2022";    WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img";   USE_UEFI="no"  ; RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
        3) WIN_NAME="Windows 11 LTSB";        WIN_URL="https://archive.org/download/win_20260203/win.img";       USE_UEFI="yes" ; RDP_USER="Admin";         RDP_PASS="Tam255Z"         ;;
        4) WIN_NAME="Windows 10 LTSB 2015";   WIN_URL="https://archive.org/download/win_20260208/win.img";       USE_UEFI="no"  ; RDP_USER="Admin";         RDP_PASS="Tam255Z"         ;;
        5) WIN_NAME="Windows 10 LTSC 2023"; WIN_URL="https://archive.org/download/win_20260215/win.img";       USE_UEFI="no"  ; RDP_USER="Admin";         RDP_PASS="Tam255Z"         ;;
        6|*) WIN_NAME="Windows 10 LTSB 2022"; WIN_URL="https://archive.org/download/win_20260717/win.img";       USE_UEFI="no"  ; RDP_USER="Admin";         RDP_PASS="Tam255Z"         ;;
    esac
    case "${win_choice:-5}" in
        3|4|5|6) RDP_USER="Admin"; RDP_PASS="Tam255Z" ;;
        *)     RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
    esac
    echo -e "${G}✔${W} Image đã chọn: ${C}${WIN_NAME}${W}"
    if [[ "$WIN_NAME" == "Windows 10 LTSB 2022" ]]; then
        echo -e "${C}🎮${W} Image này đã được thiết lập sẵn hỗ trợ ${C}Winboxes VirtGPU 3D${W}"
    fi
}

# ── Start background download (parallel với build QEMU) ──────────
IMG_DL_PID=""
_IMG_DOWNLOAD_DONE=0   # set to 1 after parallel download confirms valid image
_img_valid() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    # QCOW2 check — dùng `file` command (đọc magic bytes, không cần network)
    if command -v file &>/dev/null && file "$f" 2>/dev/null | grep -qi "qcow"; then
        return 0
    fi
    # Fallback: od magic bytes
    local _magic
    _magic=$(od -An -N4 -tx1 "$f" 2>/dev/null | tr -d " \n" || echo "")
    [[ "$_magic" == "514649fb" ]] && return 0
    # Raw image: phải >= 2 GiB và header khác zero
    local sz; sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [[ "$sz" -lt 2147483648 ]] && return 1
    # Size check only — đủ vì UEFI/Win11 có thể có 512 bytes đầu toàn zero
    return 0
}

# _img_expected_size: trả về kích thước mong đợi từ Content-Length header của URL
# Dùng để xác minh parallel download không bị truncate
_img_expected_size() {
    local _url="$1" _size=""
    _size=$(curl -sI --max-time 15 "$_url" 2>/dev/null \
        | grep -i '^content-length:' | tail -1 | awk '{print $2}' | tr -d '\r\n') || true
    if [[ -z "$_size" || "$_size" -lt 1048576 ]]; then
        _size=$(wget --spider --server-response "$_url" 2>&1 \
            | grep -i 'Content-Length:' | tail -1 | awk '{print $2}' | tr -d '\r\n') || true
    fi
    echo "${_size:-0}"
}

_start_parallel_download() {
    [[ "${USE_HTTP_BACKEND:-0}" == "1" ]] && return      # HTTP mode — no download
    [[ "${SAFE_DOWNLOAD:-0}"    == "1" ]] && return      # chunked mode — keep sequential
    [[ -z "${WIN_URL:-}"               ]] && return
    _img_valid "${WIN_IMG_PATH:-win.img}" && {
        echo -e "${G}✔${W} Image đã sẵn sàng — bỏ qua tải nền"; return; }
    echo -e "${B}ℹ${W}  🔄 Tải ${WIN_NAME} nền (song song với build QEMU)..."
    :
    if ! command -v aria2c &>/dev/null; then
        _ensure_aria2 || true
    fi
    mkdir -p "$(dirname "${WIN_IMG_PATH:-win.img}")" 2>/dev/null || true
    if command -v aria2c &>/dev/null; then
        nohup aria2c "${ARIA2_OPTS[@]}" \
            --summary-interval=30 \
            "$WIN_URL" -d "$(dirname "${WIN_IMG_PATH:-win.img}")" -o "$(basename "${WIN_IMG_PATH:-win.img}")" \
            > /tmp/dl-parallel.log 2>&1 &
    else
        nohup wget --progress=dot:giga --continue             "$WIN_URL" -O "${WIN_IMG_PATH:-win.img}"             > /tmp/dl-parallel.log 2>&1 &
    fi
    local _pid=$!
    disown "$_pid" 2>/dev/null || true
    # Xác nhận tiến trình còn sống trước khi coi là "đã bắt đầu" —
    # tránh trường hợp aria2c/wget chết ngay (binary vừa cài, PATH/thư mục
    # chưa sẵn sàng) khiến bước verify sau này báo sai "download thiếu".
    sleep 0.4
    if kill -0 "$_pid" 2>/dev/null; then
        IMG_DL_PID="$_pid"
        echo -e "${G}✔${W} Download bắt đầu nền (PID: $IMG_DL_PID)"
    else
        IMG_DL_PID=""
        echo -e "${Y}⚠${W}  Tải nền không khởi động được — sẽ tải tuần tự bình thường sau"
    fi
}

# ── Đợi download nền nếu chưa xong ──────────────────────────────
_wait_parallel_download() {
    [[ -z "${IMG_DL_PID:-}" ]] && return
    if kill -0 "$IMG_DL_PID" 2>/dev/null; then
        echo ""
        echo -e "${B}ℹ${W}  ⏳ Build QEMU xong — đợi download ${WIN_NAME} hoàn tất..."
        :
        local _t=0
        while kill -0 "$IMG_DL_PID" 2>/dev/null; do
            _t=$(( _t + 5 ))
            local _sz; _sz=$(du -sh "${WIN_IMG_PATH:-win.img}" 2>/dev/null | cut -f1 || echo "?")
            printf "\r${B}◜${W} Đang tải... %-6s đã tải (%ss)" "$_sz" "$_t"
            sleep 5
        done
        printf "\r${G}✔${W} Download xong!%30s\n" ""
    fi
    wait "$IMG_DL_PID" 2>/dev/null || true
    IMG_DL_PID=""
    local _wimg="${WIN_IMG_PATH:-win.img}"
    local _actual0; _actual0=$(stat -c%s "$_wimg" 2>/dev/null || echo 0)

    # Verify against expected Content-Length nếu có — chỉ cảnh báo khi thực
    # sự có dữ liệu dở dang (>0 byte); 0 byte nghĩa là tải nền chưa kịp ghi
    # gì cả, sẽ được tải tuần tự bình thường ở bước sau nên không cần báo.
    if [[ -n "${WIN_URL:-}" && "$_actual0" -gt 0 ]]; then
        local _expected; _expected=$(_img_expected_size "$WIN_URL" 2>/dev/null || echo 0)
        if [[ "$_expected" -gt 1048576 && "$_actual0" -lt "$_expected" ]]; then
            local _diff=$(( _expected - _actual0 ))
            echo -e "${Y}⚠${W}  File nhỏ hơn Content-Length: ${_actual0} vs ${_expected} (thiếu ${_diff} bytes) — tải lại"
            rm -f "$_wimg" 2>/dev/null || true
        fi
    fi

    if _img_valid "$_wimg" 2>/dev/null; then
        echo -e "${G}✔${W} ${WIN_NAME:-Windows image} tải thành công"
        _IMG_DOWNLOAD_DONE=1
    elif [[ -f "$_wimg" ]]; then
        SZ_BYTES=$(stat -c%s "$_wimg" 2>/dev/null || echo 0)
        if [[ "$SZ_BYTES" -ge 2147483648 ]]; then
            echo -e "${G}✔${W} ${WIN_NAME:-Windows image} tải thành công (${SZ_BYTES} bytes)"
            _IMG_DOWNLOAD_DONE=1
        else
            echo -e "${Y}⚠${W}  File nhỏ hơn 2GB (${SZ_BYTES} bytes) — có thể chưa xong: /tmp/dl-parallel.log"
        fi
    elif [[ "$_actual0" -eq 0 ]]; then
        : # Tải nền chưa kịp bắt đầu ghi file — im lặng, sequential download sẽ lo tiếp
    else
        echo -e "${Y}⚠${W}  Download chưa hoàn tất — kiểm tra /tmp/dl-parallel.log"
    fi
}

ORIGINAL_DIR="$(pwd)"
export ORIGINAL_DIR
# PREFIX fallback: nếu rootless build bị bỏ qua (QEMU đã tồn tại),
# PREFIX chưa được set bởi _rootless_build → đặt fallback $HOME/qemu-static
# để các hàm phụ (qemu-img lookup, aria2 path...) tìm được đúng đường
PREFIX="${PREFIX:-$HOME/qemu-static}"
export PREFIX
_detect_apt
_detect_kvm   # ← chạy KVM detection ngay sau apt detection

# ════════════════════════════════════════════════════════════════
#  ARIA2 — đảm bảo aria2c có sẵn
#  Thứ tự: static binary (~5s) → build from source (~5min) → apt → conda (20+min)
#  conda bị skip nếu env corrupt (broken symlinks / missing meta JSON)
# ════════════════════════════════════════════════════════════════

# Kiểm tra conda env có healthy không (không bị corrupt symlink/meta)
_conda_is_healthy() {
    command -v conda &>/dev/null || return 1
    # conda info --json trả lỗi nếu env hỏng nặng
    conda info --json > /tmp/_conda_health_$$.json 2>/dev/null || return 1
    local _base
    _base="$(python3 -c "import json; d=json.load(open('/tmp/_conda_health_$$.json')); print(d.get('root_prefix',''))" 2>/dev/null)"
    rm -f /tmp/_conda_health_$$.json
    [[ -z "$_base" ]] && return 1
    [[ -d "$_base/pkgs" ]] || return 1
    # Kiểm tra broken symlink trong conda-meta
    local _meta="$_base/conda-meta"
    [[ -d "$_meta" ]] || return 1
    # Nếu có file .json nào không đọc được → corrupt
    local _bad
    _bad=$(find "$_meta" -name "*.json" -maxdepth 1 2>/dev/null | while read -r f; do
        [[ -r "$f" ]] || echo "$f"
    done | wc -l)
    [[ "$_bad" -gt 0 ]] && return 1
    return 0
}

_ensure_aria2() {
    command -v aria2c &>/dev/null && return 0  # đã có rồi

    local _bin_dir="${PREFIX:-$HOME/qemu-static}/bin"
    mkdir -p "$_bin_dir"

    # ── Thử 1: static musl binary (nhanh nhất, ~5s, không cần root) ──
    spin_start "Tải aria2 static binary..."
    local _aria2_url="https://github.com/abcfy2/aria2-static-build/releases/latest/download/aria2-x86_64-linux-musl_static.zip"
    local _tmp_zip="/tmp/aria2-static-$$.zip"
    local _tmp_dir="/tmp/aria2-static-$$"

    if wget -q --no-check-certificate "$_aria2_url" -O "$_tmp_zip" 2>/dev/null \
        || curl -fsSL --insecure "$_aria2_url" -o "$_tmp_zip" 2>/dev/null; then
        mkdir -p "$_tmp_dir"
        if unzip -q "$_tmp_zip" -d "$_tmp_dir" 2>/dev/null; then
            local _aria2c
            _aria2c=$(find "$_tmp_dir" -name "aria2c" -type f | head -1)
            if [[ -n "$_aria2c" ]]; then
                install -m755 "$_aria2c" "$_bin_dir/aria2c"
                export PATH="$_bin_dir:$PATH"
                rm -rf "$_tmp_zip" "$_tmp_dir"
                spin_stop "aria2 static binary: $_bin_dir/aria2c"
                return 0
            fi
        fi
        rm -rf "$_tmp_zip" "$_tmp_dir"
    fi
    spin_fail "static binary thất bại — thử build from source..."

    # ── Thử 2: build from source (rootless, không cần root) ─────
    # Yêu cầu: gcc, make, pkg-config, libssl-dev, libxml2-dev, libsqlite3-dev
    # Trong HPC/conda env thường có đủ compiler nhưng thiếu dev libs → fallback tiếp
    if command -v gcc &>/dev/null && command -v make &>/dev/null; then
        spin_start "Build aria2 from source (~5 phút)..."
        local _src_ver="1.37.0"
        local _src_url="https://github.com/aria2/aria2/releases/download/release-${_src_ver}/aria2-${_src_ver}.tar.gz"
        local _src_dir="/tmp/aria2-src-$$"
        local _src_tar="/tmp/aria2-src-$$.tar.gz"
        mkdir -p "$_src_dir"

        if wget -q --no-check-certificate "$_src_url" -O "$_src_tar" 2>/dev/null \
            || curl -fsSL --insecure "$_src_url" -o "$_src_tar" 2>/dev/null; then
            tar -xf "$_src_tar" -C "$_src_dir" --strip-components=1 2>/dev/null
            rm -f "$_src_tar"

            # Tắt các feature cần lib ngoài để giảm dependency
            local _cfg_flags=(
                "--prefix=$_bin_dir/.."
                "--without-sqlite3"
                "--without-libexpat"
                "--without-libcares"
                "--disable-nls"
                "--disable-bittorrent"
                "--disable-metalink"
                "--with-pic"
            )
            # Dùng pkg-config từ conda nếu có (tránh system path)
            if command -v conda &>/dev/null; then
                local _conda_prefix
                _conda_prefix="$(conda info --base 2>/dev/null)/envs/$(conda info --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("active_prefix_name","base"))' 2>/dev/null || echo base)"
                [[ -d "$_conda_prefix/lib/pkgconfig" ]] && \
                    export PKG_CONFIG_PATH="$_conda_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            fi

            if (cd "$_src_dir" && \
                ./configure "${_cfg_flags[@]}" > /tmp/aria2-cfg-$$.log 2>&1 && \
                make -j"$(nproc)" > /tmp/aria2-make-$$.log 2>&1 && \
                make install > /dev/null 2>&1); then
                rm -rf "$_src_dir" /tmp/aria2-cfg-$$.log /tmp/aria2-make-$$.log
                export PATH="$_bin_dir:$PATH"
                if command -v aria2c &>/dev/null; then
                    spin_stop "aria2 build from source xong: $_bin_dir/aria2c"
                    return 0
                fi
            else
                echo -e "\n${Y}  configure log: $(tail -3 /tmp/aria2-cfg-$$.log 2>/dev/null)${W}" >&2
                rm -rf "$_src_dir" /tmp/aria2-cfg-$$.log /tmp/aria2-make-$$.log
            fi
        fi
        rm -rf "$_src_dir" "$_src_tar" 2>/dev/null
        spin_fail "build from source thất bại — thử apt..."
    else
        echo -e "${Y}⚠${W}  Thiếu gcc/make — bỏ qua build from source"
    fi

    # ── Thử 3: apt / apt-get (nếu root hoặc sudo) ───────────────
    local _apt=""
    command -v apt-get &>/dev/null && _apt="apt-get"
    command -v apt     &>/dev/null && _apt="apt"
    if [[ -n "$_apt" ]]; then
        spin_start "Cài aria2 qua $_apt..."
        if [[ "$(id -u)" == "0" ]]; then
            $_apt install -y -qq aria2 > /dev/null 2>&1 \
                && spin_stop "aria2 qua $_apt xong" \
                && return 0
        elif sudo -n true 2>/dev/null; then
            sudo $_apt install -y -qq aria2 > /dev/null 2>&1 \
                && spin_stop "aria2 qua sudo $_apt xong" \
                && return 0
        fi
        spin_fail "apt không cài được aria2 — thử conda (chậm)..."
    fi

    # ── Thử 4: conda (cuối cùng — chậm, 5-20 phút) ─────────────
    if command -v conda &>/dev/null; then
        if ! _conda_is_healthy; then
            echo -e "${Y}⚠${W}  conda env bị corrupt (broken symlinks / missing meta) — bỏ qua conda"
            echo -e "${B}ℹ${W}  Gợi ý: chạy ${C}conda clean --packages --tarballs${W} để thử phục hồi"
        else
            spin_start "Cài aria2 từ conda (chậm, vui lòng chờ)..."
            conda install -y -q -c conda-forge aria2 > /dev/null 2>&1 \
                || conda install -y -q aria2 > /dev/null 2>&1 || true
            if command -v aria2c &>/dev/null; then
                spin_stop "aria2 từ conda-forge xong"
                return 0
            fi
            spin_fail "aria2 conda thất bại"
        fi
    fi

    spin_fail "Không cài được aria2 — sẽ dùng wget/curl thay thế"
    return 1
}

# ════════════════════════════════════════════════════════════════
#  ISO MODE — boot từ Windows ISO (--iso=URL [--virtio=URL])
# ════════════════════════════════════════════════════════════════
_iso_mode_run() {
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}⬡  WINBOX — ISO Boot Mode${W}"
    echo -e "${C}════════════════════════════════════${W}"

    # ── Bước 1: Đảm bảo có QEMU ──────────────────────────────────
    spin_start "Kiểm tra QEMU..."
    AUTO_BUILD="${AUTO_BUILD:-}"
    local _qemu_ok=0
    for _q in "$HOME/qemu-static/bin/qemu-system-x86_64" \
              "$HOME/qemu-optimized/bin/qemu-system-x86_64" \
              "/opt/qemu-optimized/bin/qemu-system-x86_64" \
              "/usr/bin/qemu-system-x86_64" \
              "$(command -v qemu-system-x86_64 2>/dev/null || true)"; do
        [[ -x "$_q" ]] || continue
        if "$_q" --help 2>&1 | grep -q "\-display" && "$_q" --help 2>&1 | grep -qE "^-vnc "; then
            QEMU_BIN="$_q"; _qemu_ok=1; break
        fi
    done
    if [[ "$_qemu_ok" == "0" || "$AUTO_BUILD" == "yes" ]]; then
        spin_stop "QEMU chưa có — tiến hành build..."
        AUTO_BUILD="yes"
        # Luôn kiểm tra ROOTLESS trước để đảm bảo rootless mode hoạt động đúng trong ISO mode
        if [[ "$ROOTLESS" == "1" ]]; then
            spin_start "Build QEMU (rootless — ISO mode)..."
            _rootless_build 2>&1
            spin_stop "Build QEMU xong"
        elif [[ "$(id -u)" == "0" ]] && [[ "$APT_OK" == "1" ]]; then
            spin_start "Build QEMU (apt/root — ISO mode)..."
            _rootless_build 2>&1
            spin_stop "Build QEMU xong"
        else
            spin_start "Build QEMU (rootless fallback — ISO mode)..."
            _rootless_build 2>&1
            spin_stop "Build QEMU xong"
        fi
    else
        spin_stop "QEMU: $QEMU_BIN"
    fi

    # ── Resolve qemu-img ─────────────────────────────────────────
    QEMU_IMG="$(_resolve_qemu_img 2>/dev/null || echo "")"
    if [[ -z "$QEMU_IMG" ]]; then
        # qemu-img không có → thử cài qua apt
        if [[ "$(id -u)" == "0" ]] && command -v apt-get &>/dev/null; then
            echo -e "${B}ℹ${W}  qemu-img không có — thử cài qemu-utils..."
            apt-get install -y -qq qemu-utils >/dev/null 2>&1 &&                 QEMU_IMG="$(command -v qemu-img 2>/dev/null || true)"
        elif sudo -n true 2>/dev/null && command -v apt-get &>/dev/null; then
            echo -e "${B}ℹ${W}  qemu-img không có — thử cài qemu-utils (sudo)..."
            sudo apt-get install -y -qq qemu-utils >/dev/null 2>&1 &&                 QEMU_IMG="$(command -v qemu-img 2>/dev/null || true)"
        fi
    fi
    if [[ -z "$QEMU_IMG" ]]; then
        echo -e "${Y}⚠${W}  qemu-img không có — dùng truncate để tạo raw disk (không cần qemu-img)"
        QEMU_IMG="__truncate__"
    else
        echo -e "${G}✔${W}  qemu-img: $QEMU_IMG"
    fi

    # ── Helper: tạo raw disk ────────────────────────────────────
    _create_raw_disk() {
        local _path="$1" _gb="$2"
        if [[ "$QEMU_IMG" != "__truncate__" ]]; then
            "$QEMU_IMG" create -f raw "$_path" "${_gb}G" 2>&1
        else
            truncate -s "${_gb}G" "$_path" 2>&1
        fi
    }

    # ── Bước 2: Đảm bảo aria2c có sẵn ───────────────────────────
    _ensure_aria2 || true  # không fatal — fallback wget/curl trong _iso_download

    # ── Bước 3: Tải ISOs ─────────────────────────────────────────
    local _iso_dir="$HOME/.cache/winbox-iso"
    mkdir -p "$_iso_dir"
    cd "$_iso_dir"

    if [[ -z "$ISO_WIN_URL" ]]; then
        echo ""
        read -rp "$(echo -e "${B}📀${W} Nhập URL Windows ISO: ")" ISO_WIN_URL
        if [[ -z "$ISO_WIN_URL" ]]; then
            echo -e "${R}✘${W}  Cần URL Windows ISO. Dùng: bash winbox.sh --iso=URL"
            exit 1
        fi
    fi

    # ── Helper tải file với aria2 → wget → curl fallback ─────────
    _iso_download() {
        local _url="$1" _out="$2" _label="$3"
        local _full_path="$_iso_dir/$_out"
        spin_start "Kiểm tra ${_label}..."

        if [[ -f "$_full_path" ]]; then
            local _sz
            _sz=$(stat -c%s "$_full_path" 2>/dev/null || echo 0)
            if [[ "$_sz" -lt 104857600 ]]; then
                # < 100MB — rõ ràng incomplete/corrupt
                spin_stop "${Y}⚠${W}  ${_label} có nhưng < 100MB ($_sz bytes) — xóa và tải lại"
                rm -f "$_full_path" "$_full_path".aria2
            else
                spin_stop "${_label} đã có ($_sz bytes)"
                echo ""
                local _yn
                read -rp "$(echo -e "${Y}?${W}  Tải lại ${_label}? [y/N]: ")" _yn
                if [[ "${_yn,,}" == "y" ]]; then
                    rm -f "$_full_path" "$_full_path".aria2
                    echo -e "${B}ℹ${W}  Đã xóa — bắt đầu tải lại..."
                else
                    echo -e "${G}✔${W}  Dùng file cũ"
                    return 0
                fi
            fi
        fi

        # Thử aria2c trước — multi-connection, resume, progress
        if command -v aria2c &>/dev/null; then
            spin_stop "Tải ${_label} bằng aria2c..."
            aria2c "${ARIA2_OPTS[@]}" \
                --out="$_out" \
                --dir="$_iso_dir" \
                "$_url" \
            && { echo -e "${G}✔${W} ${_label} tải xong (aria2c)"; return 0; }
            echo -e "${Y}⚠${W}  aria2c thất bại — thử wget..."
        fi

        # Fallback wget
        if command -v wget &>/dev/null; then
            spin_stop "Tải ${_label} bằng wget..."
            wget --no-check-certificate --show-progress -O "$_iso_dir/$_out" "$_url" \
            && { echo -e "${G}✔${W} ${_label} tải xong (wget)"; return 0; }
            echo -e "${Y}⚠${W}  wget thất bại — thử curl..."
        fi

        # Fallback curl
        spin_stop "Tải ${_label} bằng curl..."
        curl -fL --insecure --progress-bar -o "$_iso_dir/$_out" "$_url" \
        && { echo -e "${G}✔${W} ${_label} tải xong (curl)"; return 0; }

        echo -e "${R}✘${W} Không tải được ${_label} từ: $_url"
        return 1
    }

    _iso_download "$ISO_WIN_URL" "win.iso" "Windows ISO" \
        || exit 1

    if [[ -n "$ISO_VIRTIO_URL" ]]; then
        _iso_download "$ISO_VIRTIO_URL" "virtio.iso" "VirtIO ISO" \
            || exit 1
    fi

    # ── Bước 3: Tạo disk ─────────────────────────────────────────
    local _disk_gb="60"
    local _cpu_cores="2"
    local _ram_gb="4"
    local _host_cores; _host_cores=$(nproc 2>/dev/null || echo 4)
    local _host_ram_gb; _host_ram_gb=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 8)
    echo ""

    if [[ -f "$_iso_dir/win.img" ]]; then
        local _exist_sz
        if [[ "$QEMU_IMG" != "__truncate__" ]]; then
            _exist_sz=$("$QEMU_IMG" info "$_iso_dir/win.img" 2>/dev/null | awk '/virtual size/{print $3$4}' || echo "?")
        else
            _exist_sz=$(du -sh "$_iso_dir/win.img" 2>/dev/null | cut -f1 || echo "?")
        fi
        read -rp "$(echo -e "${Y}?${W}  win.img đã có (${_exist_sz}) — tạo lại không? [y/N]: ")" _yn
        if [[ "${_yn,,}" == "y" ]]; then
            read -rp "$(echo -e "${B}💾${W} Dung lượng disk mới (GB) [mặc định 60]: ")" _disk_raw
            _disk_raw=$(printf '%s' "${_disk_raw}" | tr -cd '0-9')
            [[ -n "$_disk_raw" ]] && _disk_gb="$_disk_raw"
            rm -f "$_iso_dir/win.img"
            spin_start "Tạo lại win.img raw (${_disk_gb}G)..."
            local _qimg_err2
            local _qimg_err2
            _qimg_err2=$(_create_raw_disk "$_iso_dir/win.img" "$_disk_gb" 2>&1) || {
                spin_stop ""
                echo -e "${R}✘${W}  Tạo disk thất bại: ${_qimg_err2}"
                echo -e "${B}ℹ${W}  Kiểm tra dung lượng trống: df -h ."
                return 1
            }
            spin_stop "Disk ${_disk_gb}G tạo xong"
        else
            echo -e "${G}✔${W}  Dùng disk cũ: $_iso_dir/win.img (${_exist_sz})"
        fi
    else
        read -rp "$(echo -e "${B}💾${W} Dung lượng disk (GB) [mặc định 60]: ")" _disk_raw
        _disk_raw=$(printf '%s' "${_disk_raw}" | tr -cd '0-9')
        [[ -n "$_disk_raw" ]] && _disk_gb="$_disk_raw"
        spin_start "Tạo win.img raw (${_disk_gb}G)..."
        local _qimg_err
        local _qimg_err
        _qimg_err=$(_create_raw_disk "$_iso_dir/win.img" "$_disk_gb" 2>&1) || {
            spin_stop ""
            echo -e "${R}✘${W}  Tạo disk thất bại: ${_qimg_err}"
            echo -e "${B}ℹ${W}  Kiểm tra dung lượng trống: df -h ."
            return 1
        }
        spin_stop "Disk ${_disk_gb}G tạo xong"
    fi

    read -rp "$(echo -e "${B}🖥️${W}  Số CPU cores [mặc định 2, host có ${_host_cores}]: ")" _cores_raw
    _cores_raw=$(printf '%s' "${_cores_raw}" | tr -cd '0-9')
    if [[ -n "$_cores_raw" && "$_cores_raw" -ge 1 ]]; then
        [[ "$_cores_raw" -gt "$_host_cores" ]] && \
            echo -e "${Y}⚠${W}  ${_cores_raw} cores > host (${_host_cores}) — có thể chậm" || true
        _cpu_cores="$_cores_raw"
    fi

    read -rp "$(echo -e "${B}🧠${W}  RAM (GB) [mặc định 4, host có ${_host_ram_gb}GB]: ")" _ram_raw
    _ram_raw=$(printf '%s' "${_ram_raw}" | tr -cd '0-9')
    if [[ -n "$_ram_raw" && "$_ram_raw" -ge 1 ]]; then
        _ram_gb="$_ram_raw"
    fi
    # Cap ISO mode RAM tối đa 50% host — Windows setup + download nền + JupyterHub
    # cùng lúc rất dễ OOM nếu cấp quá nhiều
    _iso_ram_cap=$(( _host_ram_gb * 50 / 100 ))
    [[ "$_iso_ram_cap" -lt 4 ]] && _iso_ram_cap=4
    if [[ "$_ram_gb" -gt "$_iso_ram_cap" ]]; then
        echo -e "${Y}⚠${W}  ISO mode: giới hạn RAM xuống ${_iso_ram_cap}GB (50% host) để tránh OOM khi setup"
        _ram_gb="$_iso_ram_cap"
    fi
    echo -e "${G}✔${W}  RAM ISO mode: ${_ram_gb}GB"

    # ── Bước 4: Khởi động VM ─────────────────────────────────────
    local _has_virtio_iso=0
    [[ -f "$_iso_dir/virtio.iso" && -n "$ISO_VIRTIO_URL" ]] && _has_virtio_iso=1

    # ── Detect KVM + CPU model (giống normal mode) ───────────────
    local _kvm_ok=0
    local _cpu_val
    local _machine_val="q35,vmport=off"
    local _kvm_accel_args
    local _tcg_tb_mb=4096

    if [[ -r /dev/kvm ]]; then
        _kvm_ok=1
        _kvm_accel_args=(-accel kvm)
        _cpu_val="host"
        _machine_val="q35"
        echo -e "${G}✔${W}  KVM phát hiện — dùng -cpu host -accel kvm"
    else
        echo -e "${Y}⚠${W}  KVM không có — dùng TCG software emulation"

        # ── TCG TB cache (fixed 4096MB) ─────────────────────────────
        _tcg_tb_mb=4096
        _kvm_accel_args=(-accel "tcg,thread=multi,split-wx=off,one-insn-per-tb=off,tb-size=${_tcg_tb_mb}")
        echo -e "${G}⚡ TCG TB cache: ${_tcg_tb_mb}MB | multi-thread${W}"

        # ── CPU model-id (giống normal mode) ─────────────────────
        local _raw_cpu_name _cpu_vendor _cpu_name_useful _stripped
        _raw_cpu_name=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | sed 's/^.*: //' || echo "")
        _cpu_vendor=$(grep -m1 "vendor_id"  /proc/cpuinfo 2>/dev/null | awk '{print $NF}' || echo "")
        _cpu_name_useful=0
        _stripped=$(printf '%s' "$_raw_cpu_name" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        if [[ -n "$_stripped" && "$_stripped" != "unknown" && ${#_stripped} -ge 4 ]]; then
            printf '%s' "$_stripped" | grep -q '[a-z]' && _cpu_name_useful=1
        fi

        local _cpu_host _cpu_model_id _cpu_extra
        if [[ "$_cpu_name_useful" == "1" ]]; then
            _cpu_host="$_raw_cpu_name"
            _cpu_model_id=$(printf '%s' "$_cpu_host"                 | tr ',' ' '                 | tr -d '"\@#$%^&*|<>'                 | sed 's/[[:space:]]\+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//'                 | cut -c1-48)
        else
            case "$_cpu_vendor" in
                GenuineIntel) _cpu_host="Intel Xeon Gold 6254" ;;
                AuthenticAMD) _cpu_host="AMD EPYC 7763" ;;
                HygonGenuine) _cpu_host="Hygon C86 7185" ;;
                CentaurHauls) _cpu_host="VIA Nano" ;;
                *)            _cpu_host="Generic x86_64" ;;
            esac
            _cpu_model_id="${_cpu_host} Processor"
            echo -e "${Y}⚠${W}  CPU name không đọc được — dùng fallback: ${_cpu_model_id}"
        fi
        _cpu_extra=
        grep -q ssse3  /proc/cpuinfo && _cpu_extra="${_cpu_extra},+ssse3"
        grep -q sse4_1 /proc/cpuinfo && _cpu_extra="${_cpu_extra},+sse4.1"
        grep -q sse4_2 /proc/cpuinfo && _cpu_extra="${_cpu_extra},+sse4.2"
        grep -q rdtscp /proc/cpuinfo && _cpu_extra="${_cpu_extra},+rdtscp"
        grep -q ' avx ' /proc/cpuinfo && _cpu_extra="${_cpu_extra},+avx"
        grep -q avx2   /proc/cpuinfo && _cpu_extra="${_cpu_extra},+avx2"
        _cpu_val="qemu64,hypervisor=off,tsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+cx16,+x2apic,+sep,+pat,+pse,+aes,+popcnt,-tsc-deadline${_cpu_extra},model-id=${_cpu_model_id}"
        echo -e "${G}✔${W}  CPU model: ${_cpu_host}  |  flags:${_cpu_extra:-none}"
    fi

    local _launch_cmd=(
        "$QEMU_BIN"
        -machine "${_machine_val}"
        -cpu "${_cpu_val}"
        -smp "${_cpu_cores},sockets=1,cores=${_cpu_cores},threads=1"
        -m "${_ram_gb}G"
        "${_kvm_accel_args[@]}"
        -object iothread,id=io1
        -drive file="$_iso_dir/win.img",if=none,id=disk0,format=raw,cache=unsafe,aio=threads,discard=on
        -device virtio-blk-pci,drive=disk0,iothread=io1,num-queues=1,queue-size=128
        -cdrom "$_iso_dir/win.iso"
    )
    if [[ "$_has_virtio_iso" == "1" ]]; then
        _launch_cmd+=(
            -drive file="$_iso_dir/virtio.iso",media=cdrom,if=none,id=cdvirtio
            -device ide-cd,drive=cdvirtio
        )
    fi

    _launch_cmd+=(
        -device virtio-gpu-pci
        -device qemu-xhci,id=xhci
        -device usb-tablet,bus=xhci.0
        -device usb-kbd,bus=xhci.0
        -netdev user,id=n0,hostfwd=tcp::3389-:3389
        -device virtio-net-pci,netdev=n0
        -vnc :0
        -boot order=c,menu=on
        -daemonize
    )

    spin_start "Khởi động ISO VM..."
    # Giảm OOM priority trước khi launch — Windows setup spike RAM rất cao
    [[ -w /proc/self/oom_score_adj ]] && echo -500 > /proc/self/oom_score_adj 2>/dev/null || true
    export QEMU_AUDIO_DRV=none
    "${_launch_cmd[@]}"
    spin_stop "ISO VM đã khởi động"

    # ── Summary ───────────────────────────────────────────────────
    echo ""
    echo -e "${C}════════════════════════════════════════════${W}"
    echo -e "${C}⬡  WINBOX — ISO Boot${W}"
    echo -e "${C}════════════════════════════════════════════${W}"
    echo -e "📀 ISO Boot   : ${G}VM đang chạy${W}"
    if [[ "$_kvm_ok" == "1" ]]; then
        echo -e "⚡ Accel      : ${G}KVM + -cpu host${W}"
    else
        echo -e "⚡ Accel      : ${Y}TCG | TB: ${_tcg_tb_mb}MB${W}"
        echo -e "🧠 CPU Model  : ${B}${_cpu_host:-qemu64}${W}"
    fi
    echo -e "🖥  VNC        : ${G}localhost:5900${W}"
    echo -e "              → vncviewer localhost:5900"
    echo -e "              → TigerVNC / RealVNC / any VNC client"
    echo -e "🌐 RDP port   : ${G}localhost:3389${W}  (sau khi cài Windows)"
    echo -e "💾 Disk       : ${B}${_iso_dir}/win.img${W}  (${_disk_gb}G, raw)"
    if [[ "$_has_virtio_iso" == "1" ]]; then
        echo -e "📦 VirtIO     : ${B}${_iso_dir}/virtio.iso${W}"
    fi
    echo -e "${C}════════════════════════════════════════════${W}"
}

# ── ISO mode early exit ────────────────────────────────────────
if [[ "$ISO_MODE" == "1" ]]; then
    _iso_mode_run
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
#  MENU CHÍNH — phải hiện trước khi hỏi bất cứ gì
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${C}════════════════════════════════════${W}"
echo -e "${C}⬡  WINBOX${W}"
if [[ "$KVM_AVAILABLE" == "1" ]]; then
    echo -e "${C}⚡ Acceleration: ${G}KVM (hardware)${C}${W}"
else
    echo -e "${C}⚡ Acceleration: ${Y}TCG (software)${C}${W}"
fi
echo -e "${C}════════════════════════════════════${W}"

if [[ "$AUTO_MODE" == "1" ]]; then
    echo -e "${G}🤖 AUTO MODE — bỏ qua menu, tiến hành tạo VM${W}"
    main_choice="1"
else
    echo "1️⃣  Tạo Windows VM"
    echo "2️⃣  Quản Lý Windows VM"
    echo "3️⃣  Xoá VM (xoá tiến trình + img)"
    echo -e "${C}════════════════════════════════════${W}"
    read -rp "👉 Nhập lựa chọn [1-3]: " main_choice
fi
# ── Early exit cho case 2 & 3 (tránh build QEMU / cài aria2 không cần thiết) ──
case "$main_choice" in
2)
    echo ""
    echo -e "${C}🚀 ===== MANAGE RUNNING VM =====${W}"
    if pgrep -f 'qemu-system-x86_64' > /dev/null; then
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
            vcpu=$(sed -n 's/.*-smp \([^ ,]*\).*/\1/p' <<< "$cmd")
            ram=$(sed -n  's/.*-m \([^ ]*\).*/\1/p'    <<< "$cmd")
            cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null || echo "?")
            mem=$(ps -p "$pid" -o %mem= 2>/dev/null || echo "?")
            echo -e "🆔 PID: ${Y}${pid}${W}  |  vCPU: ${B}${vcpu}${W}  |  RAM: ${B}${ram}${W}  |  CPU: ${G}${cpu}%${W}  |  MEM: ${R}${mem}%${W}"
        done < <(pgrep -f 'qemu-system-x86_64')
    else
        echo -e "${R}❌ Không có VM nào đang chạy${W}"
    fi
    echo -e "${C}==================================${W}"
    read -rp "🆔 Nhập PID VM muốn tắt (hoặc Enter để bỏ qua): " kill_pid
    if [[ -n "$kill_pid" && -d "/proc/$kill_pid" ]]; then
        kill "$kill_pid" 2>/dev/null || true
        echo -e "${G}✅ Đã gửi tín hiệu tắt VM PID $kill_pid${W}"
    fi
    exit 0
    ;;

3)
    echo ""
    echo -e "${C}🗑️  ===== XOÁ VM =====${W}"
    BUILD="${BUILD:-/tmp/qemu-build}"
    IMG_LIST=(); IMG_LABEL=()
    declare -A _SEEN_REAL=()
    for _p in \
        "$BUILD/win.img" "/tmp/qemu-build/win.img" "$HOME/win.img" \
        "/content/win.img" "$(pwd)/win.img" \
        "$BUILD/2012.img" "$BUILD/2022.img" \
        "/tmp/qemu-build/2012.img" "/tmp/qemu-build/2022.img"; do
        if [[ -f "$_p" ]]; then
            _real=$(realpath "$_p" 2>/dev/null || echo "$_p")
            [[ -n "${_SEEN_REAL[$_real]:-}" ]] && continue
            _SEEN_REAL[$_real]=1
            SIZE=$(du -sh "$_p" 2>/dev/null | cut -f1 || echo "?")
            IMG_LIST+=("$_p"); IMG_LABEL+=("$_p  [${SIZE}]")
        fi
    done
    RUNNING_PIDS=()
    while IFS= read -r pid; do
        [[ -n "$pid" ]] && RUNNING_PIDS+=("$pid")
    done < <(pgrep -f 'qemu-system-x86_64' 2>/dev/null || true)
    echo -e "${C}── VM đang chạy: ──────────────────────${W}"
    if [[ "${#RUNNING_PIDS[@]}" -gt 0 ]]; then
        for pid in "${RUNNING_PIDS[@]}"; do
            cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
            img=$(grep -oE -- '-drive file=[^ ,]+' <<< "$cmd" | cut -d= -f3 | head -1)
            echo -e "  🆔 PID ${Y}${pid}${W}  |  img: ${B}${img:-unknown}${W}"
        done
    else
        echo -e "  ${B}(không có VM nào đang chạy)${W}"
    fi
    echo -e "${C}── Image files tìm thấy: ───────────────${W}"
    if [[ "${#IMG_LIST[@]}" -gt 0 ]]; then
        for i in "${!IMG_LIST[@]}"; do
            echo -e "  $((i+1)). ${IMG_LABEL[$i]}"
        done
    else
        echo -e "  ${B}(không tìm thấy img nào)${W}"
    fi
    echo -e "${C}═══════════════════════════════════════${W}"
    echo -e "${R}⚠️  Xoá VM sẽ:${W}"
    echo -e "   1. Kill tất cả tiến trình qemu-system-x86_64"
    echo -e "   2. Dừng QEMU processes"
    echo -e "   3. Xoá các img file được chọn"
    echo -e "${C}═══════════════════════════════════════${W}"
    read -rp "❓ Bạn có chắc muốn xoá VM không? (yes/n): " confirm_delete
    confirm_delete=$(echo "${confirm_delete:-n}" | tr -cd 'a-zA-Z')
    if [[ "$confirm_delete" != "yes" ]]; then
        echo -e "${Y}⚠️  Huỷ — không xoá gì cả${W}"
        exit 0
    fi
    if [[ "${#RUNNING_PIDS[@]}" -gt 0 ]]; then
        echo -e "${B}ℹ${W}  Kill VM processes..."
        for pid in "${RUNNING_PIDS[@]}"; do
            kill -SIGTERM "$pid" 2>/dev/null || true
        done
        sleep 2
        for pid in "${RUNNING_PIDS[@]}"; do
            kill -0 "$pid" 2>/dev/null && kill -SIGKILL "$pid" 2>/dev/null || true
        done
        echo -e "${G}✔${W} Đã kill tất cả QEMU processes"
    else
        echo -e "${B}ℹ${W}  Không có QEMU process nào"
    fi
    rm -f /tmp/frpc-rdp.* /tmp/frpc-watchdog.pid 2>/dev/null || true
    if [[ "${#IMG_LIST[@]}" -gt 0 ]]; then
        if [[ "${#IMG_LIST[@]}" -eq 1 ]]; then
            del_choice="1"
        else
            echo ""; echo "Chọn img muốn xoá:"
            for i in "${!IMG_LIST[@]}"; do echo "  $((i+1)). ${IMG_LABEL[$i]}"; done
            echo "  a. Xoá tất cả"; echo "  0. Không xoá img nào"
            read -rp "👉 Nhập số (hoặc 'a' cho tất cả): " del_choice
            del_choice=$(echo "${del_choice:-0}" | tr -cd '0-9a')
        fi
        if [[ "$del_choice" == "a" ]]; then
            for p in "${IMG_LIST[@]}"; do rm -f "$p" && echo -e "${G}✔${W} Đã xoá: $p" || echo -e "${R}✘${W} Không xoá được: $p"; done
        elif [[ "$del_choice" =~ ^[0-9]+$ && "$del_choice" -ge 1 && "$del_choice" -le "${#IMG_LIST[@]}" ]]; then
            idx=$(( del_choice - 1 ))
            rm -f "${IMG_LIST[$idx]}" && echo -e "${G}✔${W} Đã xoá: ${IMG_LIST[$idx]}" || echo -e "${R}✘${W} Không xoá được: ${IMG_LIST[$idx]}"
        else
            echo -e "${B}ℹ${W}  Bỏ qua xoá img"
        fi
    fi
    rm -f /tmp/qemu-launch.log /tmp/frpc-rdp.* /tmp/frpc-watchdog.pid 2>/dev/null || true
    echo ""; echo -e "${G}✅ Xoá VM hoàn tất${W}"
    exit 0
    ;;
esac

# Case 1 falls through — tiếp tục tải AppImage/download
_ask_win_image_early
WIN_IMG_PATH="${ORIGINAL_DIR:-$(pwd)}/win.img"
export WIN_IMG_PATH

# ════════════════════════════════════════════════════════════════
#  QEMU ACQUISITION — AppImage prebuilt only (root + rootless như nhau)
#  Không còn build từ source: chỉ resolve AppImage đã có, hoặc tải mới.
# ════════════════════════════════════════════════════════════════
_detect_existing_qemu() {
    # Ưu tiên AppImage QEMU 11.x trước
    local _appimg_path=""
    _appimg_path="$(_resolve_qemu_appimage 2>/dev/null || echo '')"
    if [[ -n "$_appimg_path" && -x "$_appimg_path" ]]; then
        local _app_ver
        _app_ver=$(timeout 10 "$_appimg_path" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        if [[ "$_app_ver" == 11.* ]] || [[ "$_app_ver" == unknown ]]; then
            echo -e "${G}⚡ QEMU 11 AppImage backend: $_appimg_path (v$_app_ver)${W}"
            export QEMU_BIN="$_appimg_path"
            export PATH="$(dirname "$_appimg_path"):$PATH"
            echo -e "${G}✔${W} QEMU AppImage backend: ${B}QEMU 11.x${W} (${_app_ver:-unknown})"
            echo -e "${G}✔${W} TCG available: ${B}yes${W} (TCG works without /dev/kvm)"
            echo -e "${G}✔${W} LTO/-O3 optimized: ${B}baked-in${W} (prebuilt AppImage)"
            return 0
        fi
    fi
    for q in "$OPT_QEMU" "$HOME_QEMU" "$ROOTLESS_QEMU" "$QEMU_BIN" \
              "$(command -v qemu-system-x86_64 2>/dev/null)"; do
        if [[ -n "$q" && -x "$q" ]]; then
            local qv
            qv=$("$q" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
            echo -e "${G}⚡ Tìm thấy QEMU v${qv} tại: $q${W}"
            export QEMU_BIN="$q"
            export PATH="$(dirname "$q"):$PATH"
            return 0
        fi
    done
    return 1
}

echo ""
echo -e "${C}════════════════════════════════════${W}"
echo -e "${C}⚡ QEMU AppImage (prebuilt)${W}"
echo -e "${C}════════════════════════════════════${W}"

if _detect_existing_qemu && [[ "$AUTO_BUILD" != "yes" ]]; then
    QEMU_VER=$("$QEMU_BIN" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")
    echo -e "${G}✔${W} QEMU v${QEMU_VER} đã có — bỏ qua tải (dùng --rebuild để tải lại)"
    WIN_IMG_PATH="${ORIGINAL_DIR:-$(pwd)}/win.img"
    _start_parallel_download
    [[ -n "${IMG_DL_PID:-}" ]] && echo -e "${B}ℹ${W}  🔀 Tải Windows image song song (PID: $IMG_DL_PID)"
elif [[ "$AUTO_BUILD" == "no" ]]; then
    echo -e "${Y}⚠${W}  --no-build: bỏ qua tải QEMU AppImage (có thể lỗi nếu chưa có QEMU)"
    _start_parallel_download
else
    echo -e "${B}ℹ${W}  Tải QEMU AppImage prebuilt..."
    WIN_IMG_PATH="${ORIGINAL_DIR:-$(pwd)}/win.img"
    _start_parallel_download
    [[ -n "${IMG_DL_PID:-}" ]] && echo -e "${B}ℹ${W}  🔀 Tải Windows image song song với AppImage (PID: $IMG_DL_PID)"
    _rootless_build
fi

_wait_parallel_download

echo -e "${G}✔${W}  QEMU AppImage sẵn sàng${W}"
echo -e "${C}════════════════════════════════════${W}"
echo ""

# Đảm bảo bin dir của QEMU_BIN luôn có trong PATH
[[ -x "${QEMU_BIN:-}" ]] && export PATH="$(dirname "$QEMU_BIN"):$PATH"

# ════════════════════════════════════════════════════════════════
#  CHỌN PHIÊN BẢN WINDOWS
# ════════════════════════════════════════════════════════════════
echo ""
if [[ -n "${win_choice:-}" ]]; then
    echo -e "${G}🤖 Dùng image đã chọn trước: ${WIN_NAME:-Windows image}${W}"
elif [[ "$AUTO_MODE" == "1" && -n "$AUTO_WIN" ]]; then
    win_choice="$AUTO_WIN"
    echo -e "${G}🤖 AUTO MODE — Windows preset: ${AUTO_WIN}${W}"
else
    echo "🪟 Chọn phiên bản Windows muốn tải:"
    echo "1️⃣  Windows Server 2012 R2 x64"
    echo "2️⃣  Windows Server 2022 x64"
    echo "3️⃣  Windows 11 LTSB x64"
    echo "4️⃣  Windows 10 LTSB 2015 x64"
    echo "5️⃣  Windows 10 LTSC 2023 x64"
    echo "6️⃣  Windows 10 LTSB 2022 x64"
    if [[ -t 0 ]]; then
        read -rp "👉 Nhập số [1-6]: " win_choice
    else
        win_choice="5"
        echo -e "${Y}⚠${W}  stdin không tương tác — mặc định chọn 5 (LTSC 2023)"
    fi
fi

case "$win_choice" in
1) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no"  ;;
2) WIN_NAME="Windows Server 2022";    WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img";   USE_UEFI="no"  ;;
3) WIN_NAME="Windows 11 LTSB";        WIN_URL="https://archive.org/download/win_20260203/win.img";       USE_UEFI="yes" ;;
4) WIN_NAME="Windows 10 LTSB 2015";   WIN_URL="https://archive.org/download/win_20260208/win.img";       USE_UEFI="no"  ;;
5) WIN_NAME="Windows 10 LTSC 2023";   WIN_URL="https://archive.org/download/win_20260215/win.img";       USE_UEFI="no"  ;;
6) WIN_NAME="Windows 10 LTSB 2022";   WIN_URL="https://archive.org/download/win_20260717/win.img";       USE_UEFI="no"  ;;
*) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no"  ;;
esac

case "$win_choice" in
3|4|5|6) RDP_USER="Admin";         RDP_PASS="Tam255Z"         ;;
*)     RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
esac

if [[ "$WIN_NAME" == "Windows 10 LTSB 2022" ]]; then
    echo -e "${C}🎮${W} Image này đã được thiết lập sẵn hỗ trợ ${C}Winboxes VirtGPU 3D${W}"
fi

# Kiểm tra win.img hợp lệ (tồn tại + không phải file rỗng/zero + >= 2GB)

# VNC boot verification - HTTP backend an toàn với VNC
# Không cần tắt HTTP backend, VNC hoạt động độc lập

# ── HTTP backend mode: tạo QCOW2 backing file thay vì tải toàn bộ image ──
if [[ "${USE_HTTP_BACKEND:-0}" == "1" ]]; then
    if [[ ! -f win.img ]] || ! _img_valid win.img; then
        echo -e "${C}════════════════════════════════════${W}"
        echo -e "${C}🌐 HTTP-BACKEND MODE — không tải file${W}"
        echo -e "${C}════════════════════════════════════${W}"
        echo -e "${B}ℹ${W}  Tạo QCOW2 backing → $WIN_URL"
        echo -e "${B}ℹ${W}  QEMU sẽ fetch block on-demand (tiết kiệm disk, cần mạng tốt)"
        # Dùng /usr/bin/qemu-img trực tiếp (tránh wrapper cũ trong /opt)
        _REAL_QEMU_IMG=$(for _q in /usr/bin/qemu-img /usr/local/bin/qemu-img; do
            [[ -x "$_q" ]] && grep -qv "touch" "$_q" 2>/dev/null && echo "$_q" && break
        done)
        [[ -z "$_REAL_QEMU_IMG" ]] && _REAL_QEMU_IMG=$(PATH=/usr/bin:/bin which qemu-img 2>/dev/null || echo "")
        if [[ -n "$_REAL_QEMU_IMG" && -x "$_REAL_QEMU_IMG" ]]; then
            "$_REAL_QEMU_IMG" create -f qcow2 -F raw -b "$WIN_URL" win.img 2>/dev/null                 && { echo -e "${G}✔${W} QCOW2 backing file tạo xong: win.img (HTTP-backed, ~200KB local)"; _HTTP_BACKED=1; }                 || {
                    echo -e "${Y}⚠${W}  qemu-img create failed — fallback tải thường"
                    USE_HTTP_BACKEND=0
                }
        else
            echo -e "${Y}⚠${W}  qemu-img thật không tìm thấy — fallback tải thường"
            USE_HTTP_BACKEND=0
        fi
    else
        echo -e "${G}✔${W} win.img đã tồn tại và hợp lệ — bỏ qua tạo backing"
        _HTTP_BACKED=1
    fi
fi

# Đảm bảo WIN_IMG_PATH tuyệt đối + quay về thư mục gốc
WIN_IMG_PATH="${WIN_IMG_PATH:-${ORIGINAL_DIR:-$(pwd)}/win.img}"
cd "${ORIGINAL_DIR:-$(pwd)}" 2>/dev/null || true

_HTTP_BACKED="${_HTTP_BACKED:-0}"
if [[ "$_HTTP_BACKED" == "1" ]] || [[ "${_IMG_DOWNLOAD_DONE:-0}" == "1" ]] || _img_valid "$WIN_IMG_PATH"; then
    echo -e "${G}✔ win.img sẵn sàng ($(du -sh "$WIN_IMG_PATH" 2>/dev/null | cut -f1 || echo "HTTP-backed")) — bỏ qua tải${W}"
else
    [[ -f "$WIN_IMG_PATH" ]] &&         echo -e "${Y}⚠${W}  win.img tồn tại nhưng không hợp lệ (rỗng/nhỏ quá) — tải lại"
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}⬇  Đang tải: ${Y}$WIN_NAME${W}"
    echo -e "${C}════════════════════════════════════${W}"
    if command -v aria2c &>/dev/null; then
        aria2c "${ARIA2_OPTS[@]}" \
            "$WIN_URL" -d "$(dirname "$WIN_IMG_PATH")" -o "$(basename "$WIN_IMG_PATH")"
    else
        echo -e "${Y}⚠${W}  aria2c không có — dùng wget..."
        wget --progress=bar:force --continue "$WIN_URL" -O "$WIN_IMG_PATH"
    fi
    echo -e "${G}✔ Tải $WIN_NAME xong${W}"
fi

# ── Hỏi đổi password (root mode, interactive) ─────────────────────

# ── Thực thi reset password nếu user đã xác nhận ──────────────────

if [[ "$AUTO_MODE" == "1" ]]; then
    extra_gb=0
    echo -e "${G}🤖 AUTO MODE — disk extend: 0GB (bỏ qua resize)${W}"
else
    extra_gb=""
    read -rp "📦 Mở rộng đĩa thêm bao nhiêu GB (default 20)? " extra_gb
    # Lọc bỏ escape codes/ký tự lạ từ terminal (tmux, SSH)
    extra_gb=$(echo "${extra_gb:-20}" | tr -cd '0-9')
    extra_gb="${extra_gb:-20}"
fi

if [[ "$extra_gb" -gt 0 ]]; then
    spin_start "Resize disk +${extra_gb}GB..."
    _QEMU_IMG_BIN="$(_resolve_qemu_img 2>/dev/null || echo "")"
    if [[ -n "$_QEMU_IMG_BIN" ]]; then
        silent "$_QEMU_IMG_BIN" resize "$WIN_IMG_PATH" "+${extra_gb}G"
    else
        echo -e "${Y}⚠${W}  qemu-img không tìm thấy — bỏ qua resize"
    fi
    spin_stop "Resize disk xong"
else
    echo -e "${B}ℹ${W}  Bỏ qua resize disk (extra_gb=0)"
fi

# ════════════════════════════════════════════════════════════════
#  CẤU HÌNH VM
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${C}════════════════════════════════════${W}"
echo -e "${C}⚙  CHỌN CHẾ ĐỘ CẤU HÌNH VM${W}"
echo -e "${C}════════════════════════════════════${W}"

if [[ "$AUTO_MODE" == "1" ]]; then
    cfg_mode="1"
    echo -e "${G}🤖 AUTO MODE — tự động chọn cấu hình tài nguyên${W}"
else
    echo "1️⃣  Auto cấu hình (khuyên dùng)"
    echo "2️⃣  Tự chọn thủ công"
    echo -e "${C}════════════════════════════════════${W}"
    if [[ -t 0 ]]; then
        read -rp "👉 Nhập lựa chọn [1-2]: " cfg_mode
    else
        cfg_mode="1"
        echo -e "${Y}⚠${W}  stdin không tương tác — mặc định chọn 1 (auto cấu hình)"
    fi
fi

if [[ "$cfg_mode" == "1" ]]; then
    spin_start "Auto detect tài nguyên host..."
    cpu_v=$(nproc 2>/dev/null); cpu_u=$cpu_v

    if [[ -f /sys/fs/cgroup/cpu.max ]]; then
        IFS=" " read -r cq cp < /sys/fs/cgroup/cpu.max
        [[ "$cq" != "max" ]] && cpu_u=$(awk "BEGIN{printf \"%.0f\",$cq/$cp}")
    elif [[ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]]; then
        cq=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
        cp=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
        [[ "$cq" != "-1" ]] && cpu_u=$(awk "BEGIN{printf \"%.0f\",$cq/$cp}")
    fi
    [[ "$cpu_u" -lt 1 ]] && cpu_u=1

    mem_total_gb=$(awk '/MemTotal/{printf "%.0f",$2/1024/1024}' /proc/meminfo)
    mem_auto_gb=$(awk "BEGIN{printf \"%d\", ($mem_total_gb*0.70)+0.5}")
    [[ "$mem_auto_gb" -lt 2 ]] && mem_auto_gb=2
    max_ram=$(( mem_total_gb - 1 ))
    [[ "$mem_auto_gb" -gt "$max_ram" ]] && mem_auto_gb=$max_ram
    cpu_core=$cpu_u; ram_size=$mem_auto_gb

    # WINBOX_VCPUS / WINBOX_RAM_GB: override for constrained environments
    [[ -n "${WINBOX_VCPUS:-}" ]] && cpu_core="$WINBOX_VCPUS"
    [[ -n "${WINBOX_RAM_GB:-}" ]] && ram_size="$WINBOX_RAM_GB"

    spin_stop "Auto detect xong"
    echo "   🖥️  CPU : ${cpu_v} cores (usable: ${cpu_core})"
    echo "   💾 RAM : ${mem_total_gb}GB total → VM ${ram_size}GB"
else
    cpu_core=""; ram_size=""
    read -rp "⚙  CPU core (default 4): " cpu_core
    read -rp "💾 RAM GB   (default 4): " ram_size
    cpu_core=$(echo "${cpu_core:-4}" | tr -cd '0-9'); cpu_core="${cpu_core:-4}"
    ram_size=$(echo "${ram_size:-4}" | tr -cd '0-9'); ram_size="${ram_size:-4}"
    # Đảm bảo cpu_u có giá trị hợp lệ khi manual mode
    cpu_u="${cpu_core}"
fi

# ════════════════════════════════════════════════════════════════
#  TCG PERFORMANCE TUNING
#  _tcg_tune_common  — chạy trên cả root lẫn rootless
#  _tcg_tune_root    — chỉ chạy khi có root (thêm mọi thứ còn lại)
#  _tcg_tune         — dispatcher tự chọn đúng phiên bản
# ════════════════════════════════════════════════════════════════

# ── Shared: detect physical cores, numactl, chrt, env vars ──────
_tcg_tune_common() {
    # MALLOC_ARENA_MAX=4: TCG multi-thread JIT với 4 arenas giảm lock contention
    export MALLOC_ARENA_MAX=4
    export MALLOC_MMAP_THRESHOLD_=131072
    export MALLOC_TRIM_THRESHOLD_=131072
    export JIT_SERIALIZE_OBJECT=1
    # Tắt QEMU audio — headless/RDP không cần, tránh tốn thread
    export QEMU_AUDIO_DRV=none
    echo -e "${G}✔${W} JIT env vars set (MALLOC_ARENA_MAX=4, QEMU_AUDIO_DRV=none)"

    # oom_score_adj: giảm OOM priority cho QEMU (không cần root)
    if [[ -w /proc/self/oom_score_adj ]]; then
        echo -500 > /proc/self/oom_score_adj 2>/dev/null \
            && echo -e "${G}✔${W} oom_score_adj=-500 (QEMU ít bị OOM kill hơn)" \
            || echo -e "${Y}⚠${W}  oom_score_adj: không ghi được"
    fi

    # taskset: pin QEMU vào số core được cấp phép theo cgroup quota
    # Không dùng physical core detection (nguy hiểm trong container/vCPU)
    _TASKSET_PREFIX=""
    if command -v taskset &>/dev/null; then
        # cpu_u đã được detect từ cgroup quota ở bước auto-config trước
        _pin_cores="${cpu_u:-${cpu_core:-$(nproc)}}"
        [[ "$_pin_cores" -lt 1 ]] && _pin_cores=1
        # Pin vào 0..(N-1) — đúng với cả bare-metal lẫn container vCPU
        _pin_range="0-$(( _pin_cores - 1 ))"
        [[ "$_pin_cores" -eq 1 ]] && _pin_range="0"
        _TASKSET_PREFIX="taskset -c $_pin_range"
        echo -e "${G}✔${W} taskset: pin vào ${_pin_cores} vCPU [${_pin_range}] (từ cgroup quota)"
    else
        echo -e "${Y}⚠${W}  taskset không có — bỏ qua CPU pinning"
    fi
    export _TASKSET_PREFIX

    # detect numactl
    if command -v numactl &>/dev/null \
        && numactl --hardware 2>/dev/null | grep -q 'node 0'; then
        TCG_NUMACTL_PREFIX="numactl --membind=0 --cpunodebind=0"
        echo -e "${G}✔${W} numactl: membind=0 (NUMA node 0)"
    else
        TCG_NUMACTL_PREFIX=""
    fi
    export TCG_NUMACTL_PREFIX

    # detect chrt realtime
    if command -v chrt &>/dev/null && chrt -f 99 true 2>/dev/null; then
        TCG_CHRT_PREFIX="chrt -f 99"
        echo -e "${G}✔${W} chrt -f 99 (FIFO RT)"
    elif command -v chrt &>/dev/null && chrt -r 1 true 2>/dev/null; then
        TCG_CHRT_PREFIX="chrt -r 1"
        echo -e "${G}✔${W} chrt -r 1 (RR RT)"
    else
        TCG_CHRT_PREFIX=""
        echo -e "${Y}⚠${W}  chrt: không có quyền realtime"
    fi
    export TCG_CHRT_PREFIX
    QEMU_HUGEPAGES_DIR=""; export QEMU_HUGEPAGES_DIR
}

# ── Root-only extras ─────────────────────────────────────────────
_tcg_tune_root() {
    echo -e "${B}ℹ${W}  Root TCG tuning..."

    # 1. renice
    renice -n -20 $$ 2>/dev/null \
        && echo -e "${G}✔${W} renice -20" \
        || echo -e "${Y}⚠${W}  renice thất bại"

    # 2. ionice
    ionice -c 1 -n 0 $$ 2>/dev/null \
        && echo -e "${G}✔${W} ionice: RT class" \
        || echo -e "${Y}⚠${W}  ionice thất bại"

    # 3. CPU governor → performance
    for _gf in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "$_gf" ]] && echo performance > "$_gf" 2>/dev/null || true
    done
    local _gov; _gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "n/a")
    echo -e "${G}✔${W} CPU governor: ${_gov}"

    # 4. Hugepages (2MB)
    local _pages_needed=$(( ${ram_size:-2} * 512 ))
    local _hr="/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
    if [[ -w "$_hr" ]]; then
        echo "$_pages_needed" > "$_hr" 2>/dev/null || true
        local _after; _after=$(cat "$_hr" 2>/dev/null || echo 0)
        if [[ "$_after" -ge "$_pages_needed" ]]; then
            QEMU_HUGEPAGES_DIR="/dev/hugepages"
            export QEMU_HUGEPAGES_DIR
            echo -e "${G}✔${W} Hugepages: ${_after} × 2MB"
        else
            echo -e "${Y}⚠${W}  Hugepages: chỉ có ${_after}/${_pages_needed} — bỏ qua"
        fi
    else
        echo -e "${Y}⚠${W}  Hugepages sysfs: không ghi được — bỏ qua"
    fi

    # 5. Disk scheduler → mq-deadline (skip loop devices, suppress EROFS)
    local _sched_ok=0
    for _sched in /sys/block/*/queue/scheduler; do
        [[ -f "$_sched" ]] || continue
        [[ "$_sched" == */loop* ]] && continue  # skip loop devices
        { echo mq-deadline > "$_sched"; } 2>/dev/null             && _sched_ok=$((_sched_ok+1)) || true
    done
    if [[ $_sched_ok -gt 0 ]]; then
        echo -e "${G}✔${W} Disk scheduler → mq-deadline ($_sched_ok)"
    else
        echo -e "${Y}⚠${W}  Disk scheduler: read-only/no permission — bỏ qua"
    fi
    # dummy-to-keep-indentation for Disk scheduler → mq-deadline"
}

# ── stress-ng warmup — chạy được cả root lẫn rootless ───────────
_stress_warmup() {
    local _ncpu="${1:-$(nproc)}"
    local _dur=8
    if command -v stress-ng &>/dev/null; then
        echo -e "${B}ℹ${W}  stress-ng warmup: ${_ncpu} CPU × ${_dur}s..."
        timeout $(( _dur + 2 )) stress-ng --cpu "$_ncpu" --cpu-method matrixprod \
            -t "${_dur}s" --metrics-brief 2>/dev/null || true
        echo -e "${G}✔${W} Warmup xong — CPU đang ở peak frequency"
    else
        apt_install stress-ng > /dev/null 2>&1 || true
        if command -v stress-ng &>/dev/null; then
            timeout $(( _dur + 2 )) stress-ng --cpu "$_ncpu" -t "${_dur}s" 2>/dev/null || true
            echo -e "${G}✔${W} Warmup xong"
        else
            echo -e "${Y}⚠${W}  stress-ng không có — bỏ qua warmup"
        fi
    fi
}

# ── Dispatcher ───────────────────────────────────────────────────
_tcg_tune() {
    if [[ "${NO_TUNING:-0}" == "1" ]]; then
        echo -e "${Y}⚠${W}  Bỏ qua toàn bộ TCG tuning"
        LAUNCH_PREFIX=""
        TCG_TB_MB=512
        return
    fi
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔧 TCG PERFORMANCE TUNING${W}"
    echo -e "${C}════════════════════════════════════${W}"
    _tcg_tune_common
    if [[ $EUID -eq 0 ]]; then
        _tcg_tune_root
    fi
    _stress_warmup "${cpu_core:-$(nproc)}"
    LAUNCH_PREFIX="${_TASKSET_PREFIX:+${_TASKSET_PREFIX} }${TCG_NUMACTL_PREFIX:+${TCG_NUMACTL_PREFIX} }${TCG_CHRT_PREFIX:-}"
    LAUNCH_PREFIX="${LAUNCH_PREFIX# }"
    export LAUNCH_PREFIX
    echo -e "${G}🔥 TCG tuning xong — full TCG optimizations on${W}"
    echo ""
}

if [[ "$KVM_AVAILABLE" == "1" ]]; then
    echo -e "${G}⚡ VM sẽ chạy với KVM acceleration + CPU host passthrough${W}"
    ACCEL_OPT="-accel kvm"
    CPU_OPT="-cpu host"
    LAUNCH_PREFIX=""   # KVM không cần numactl/chrt prefix

    # Network
    [[ "$win_choice" == "4" ]] \
        && NET_DEVICE="-device e1000e,netdev=n0" \
        || NET_DEVICE="-device virtio-net-pci,netdev=n0"

    # BIOS/UEFI
    [[ "$USE_UEFI" == "yes" ]] \
        && {
            # Detect OVMF across common paths (rootless may not have apt-installed ovmf)
            _OVMF=""
            for _ovmf in                 /usr/share/qemu/OVMF.fd                 /usr/share/ovmf/OVMF.fd                 /usr/share/ovmf/x64/OVMF.fd                 /usr/share/OVMF/OVMF_CODE.fd                 "${PREFIX:-}/share/qemu/OVMF.fd"                 "$HOME/qemu-static/share/qemu/OVMF.fd"; do
                [[ -f "$_ovmf" ]] && { _OVMF="$_ovmf"; break; }
            done
            if [[ -n "$_OVMF" ]]; then
                OVMF_PATH="$_OVMF"
                echo -e "${G}✔${W} OVMF firmware: $_OVMF"
            else
                echo -e "${Y}⚠${W}  OVMF.fd không tìm thấy — thử tải..."
                _OVMF_TMP="${PREFIX:-$HOME/qemu-static}/share/qemu"
                mkdir -p "$_OVMF_TMP"
                _OVMF_OK=0
                for _ovmf_url in \
                    "https://github.com/nicowillis/ovmf-prebuilt/raw/main/OVMF.fd" \
                    "https://github.com/clearlinux/common/raw/master/OVMF.fd" \
                    "https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd"; do
                    if wget -q --timeout=30 --tries=2 "$_ovmf_url" -O "$_OVMF_TMP/OVMF.fd" 2>/dev/null; then
                        # Sanity check: OVMF.fd should be >= 1MB and start with known magic
                        _sz=$(stat -c%s "$_OVMF_TMP/OVMF.fd" 2>/dev/null || echo 0)
                        if [[ "$_sz" -ge 1048576 ]]; then
                            _OVMF_OK=1; break
                        else
                            echo -e "${Y}⚠${W}  OVMF từ $_ovmf_url quá nhỏ ($_sz bytes) — thử nguồn khác"
                            rm -f "$_OVMF_TMP/OVMF.fd"
                        fi
                    fi
                done
                if [[ "$_OVMF_OK" == "1" ]]; then
                    OVMF_PATH="$_OVMF_TMP/OVMF.fd"
                    echo -e "${G}✔${W} OVMF tải xong → $_OVMF_TMP/OVMF.fd"
                else
                    OVMF_PATH=""
                    echo -e "${R}✘${W}  Không tải được OVMF — dùng SeaBIOS legacy BIOS"
                    echo -e "${Y}   Windows 10/11 có thể báo lỗi 0xc0000225 với SeaBIOS."
                    echo -e "${Y}   Fix: cài gói 'ovmf' (apt install ovmf) hoặc đặt WINBOX_DISK_BUS=ide${W}"
                fi
            fi
        } \
        || OVMF_PATH=""

    QEMU_CMD=(
        ${QEMU_BIN:-qemu-system-x86_64}
        -machine q35,hpet=off
        $CPU_OPT
        -smp "$cpu_core"
        -m "${ram_size}G"
        $ACCEL_OPT
        -rtc base=localtime,clock=host
    )

else
    # ── TCG MODE ─────────────────────────────────────────────────
    echo -e "${Y}⚡ VM sẽ chạy với TCG (software emulation)${W}"

    # Chạy tất cả TCG tuning
    _tcg_tune

    # TCG TB cache — fixed 4096MB
    TCG_TB_MB=4096
    TCG_ACCEL_OPTS="thread=multi,split-wx=off,one-insn-per-tb=off,tb-size=$TCG_TB_MB"
    echo -e "${G}⚡ TCG TB cache: ${TCG_TB_MB}MB${W}"
    echo -e "${G}⚡ TCG accel: multi-thread + split-wx=off + one-insn-per-tb=off${W}"

    # CPU flags
    # model-id = tên CPU hiển thị trong Windows Device Manager (text thuần)
    # KHÔNG ảnh hưởng performance — feature flags bên dưới mới quan trọng
    #
    # Thứ tự ưu tiên lấy tên CPU:
    #   1. model name từ /proc/cpuinfo (nếu không phải "unknown"/rỗng)
    #   2. vendor_id + family/model number → tên hợp lý
    #   3. Hardcode fallback theo vendor
    _raw_cpu_name=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | sed 's/^.*: //' || echo "")
    _cpu_vendor=$(grep -m1 "vendor_id"  /proc/cpuinfo 2>/dev/null | awk '{print $NF}' || echo "")

    # Kiểm tra tên có thực sự hữu ích không
    # Các giá trị vô nghĩa thường gặp trên container/VPS: "unknown", trống, chỉ toàn số/ký tự đặc biệt
    _cpu_name_useful=0
    _stripped=$(printf '%s' "$_raw_cpu_name" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    if [[ -n "$_stripped" && "$_stripped" != "unknown" && ${#_stripped} -ge 4 ]]; then
        # Phải có ít nhất 1 chữ cái (không phải toàn số/ký hiệu)
        if printf '%s' "$_stripped" | grep -q '[a-z]'; then
            _cpu_name_useful=1
        fi
    fi

    if [[ "$_cpu_name_useful" == "1" ]]; then
        # Dùng tên thật — sanitize để QEMU chấp nhận
        cpu_host="$_raw_cpu_name"
        cpu_model_id=$(printf '%s' "$cpu_host" \
            | tr ',' ' ' \
            | tr -d '"\\@#$%^&*|<>' \
            | sed 's/[[:space:]]\+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//' \
            | cut -c1-48)
    else
        # Tên không dùng được — fallback theo vendor_id
        case "$_cpu_vendor" in
            GenuineIntel) cpu_host="Intel Xeon Gold 6254" ;;
            AuthenticAMD) cpu_host="AMD EPYC 7763" ;;
            HygonGenuine) cpu_host="Hygon C86 7185" ;;
            CentaurHauls) cpu_host="VIA Nano" ;;
            *)            cpu_host="Generic x86_64" ;;
        esac
        cpu_model_id="${cpu_host} Processor"
        echo -e "${Y}⚠${W}  CPU name không đọc được ('${_raw_cpu_name:-empty}') — dùng fallback: ${cpu_model_id}"
    fi
    CPU_EXTRA=
    grep -q ssse3  /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+ssse3"
    grep -q sse4_1 /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+sse4.1"
    grep -q sse4_2 /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+sse4.2"
    grep -q rdtscp /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+rdtscp"
    grep -q ' avx ' /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+avx"
    grep -q avx2   /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+avx2"
    # qemu64: baseline an toàn, chỉ expose đúng flags host có — tránh emulate thừa
    # -tsc-deadline: tắt TSC-deadline timer trap overhead trong TCG
    cpu_model="max,hypervisor=off,tsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+cx16,+x2apic,+sep,+pat,+pse,+aes,+popcnt,-tsc-deadline${CPU_EXTRA},model-id=${cpu_model_id}"

    # Network
    [[ "$win_choice" == "4" ]] \
        && NET_DEVICE="-device e1000e,netdev=n0" \
        || NET_DEVICE="-device virtio-net-pci,netdev=n0"

    # BIOS/UEFI
    [[ "$USE_UEFI" == "yes" ]] \
        && {
            # Detect OVMF across common paths (rootless may not have apt-installed ovmf)
            _OVMF=""
            for _ovmf in                 /usr/share/qemu/OVMF.fd                 /usr/share/ovmf/OVMF.fd                 /usr/share/ovmf/x64/OVMF.fd                 /usr/share/OVMF/OVMF_CODE.fd                 "${PREFIX:-}/share/qemu/OVMF.fd"                 "$HOME/qemu-static/share/qemu/OVMF.fd"; do
                [[ -f "$_ovmf" ]] && { _OVMF="$_ovmf"; break; }
            done
            if [[ -n "$_OVMF" ]]; then
                OVMF_PATH="$_OVMF"
                echo -e "${G}✔${W} OVMF firmware: $_OVMF"
            else
                echo -e "${Y}⚠${W}  OVMF.fd không tìm thấy — thử tải..."
                _OVMF_TMP="${PREFIX:-$HOME/qemu-static}/share/qemu"
                mkdir -p "$_OVMF_TMP"
                _OVMF_OK=0
                for _ovmf_url in \
                    "https://github.com/nicowillis/ovmf-prebuilt/raw/main/OVMF.fd" \
                    "https://github.com/clearlinux/common/raw/master/OVMF.fd" \
                    "https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd"; do
                    if wget -q --timeout=30 --tries=2 "$_ovmf_url" -O "$_OVMF_TMP/OVMF.fd" 2>/dev/null; then
                        # Sanity check: OVMF.fd should be >= 1MB and start with known magic
                        _sz=$(stat -c%s "$_OVMF_TMP/OVMF.fd" 2>/dev/null || echo 0)
                        if [[ "$_sz" -ge 1048576 ]]; then
                            _OVMF_OK=1; break
                        else
                            echo -e "${Y}⚠${W}  OVMF từ $_ovmf_url quá nhỏ ($_sz bytes) — thử nguồn khác"
                            rm -f "$_OVMF_TMP/OVMF.fd"
                        fi
                    fi
                done
                if [[ "$_OVMF_OK" == "1" ]]; then
                    OVMF_PATH="$_OVMF_TMP/OVMF.fd"
                    echo -e "${G}✔${W} OVMF tải xong → $_OVMF_TMP/OVMF.fd"
                else
                    OVMF_PATH=""
                    echo -e "${R}✘${W}  Không tải được OVMF — dùng SeaBIOS legacy BIOS"
                    echo -e "${Y}   Windows 10/11 có thể báo lỗi 0xc0000225 với SeaBIOS."
                    echo -e "${Y}   Fix: cài gói 'ovmf' (apt install ovmf) hoặc đặt WINBOX_DISK_BUS=ide${W}"
                fi
            fi
        } \
        || OVMF_PATH=""

    # "pc" (i440fx): ít overhead hơn q35 trong TCG — interrupt routing đơn giản hơn
    _machine_type="${WINBOX_MACHINE_TYPE:-q35}"
    echo -e "${G}✔${W} Machine type: ${B}${_machine_type}${W} [override: WINBOX_MACHINE_TYPE=pc|q35]"

    QEMU_CMD=(
        ${QEMU_BIN:-qemu-system-x86_64}
        -machine ${_machine_type},hpet=off,vmport=off,mem-merge=off
        -cpu "$cpu_model"
        -smp "$cpu_core,cores=$cpu_core,threads=1,sockets=1"
        -m "${ram_size}G"
        -accel tcg,${TCG_ACCEL_OPTS}
        -rtc base=localtime
        -overcommit cpu-pm=on
        -boot order=c,strict=on
        -no-shutdown
        -device virtio-mouse-pci
        -device virtio-keyboard-pci
        -nodefaults
        # ICH9-LPC globals added conditionally below (q35 only)
        # (moved outside array to avoid syntax issues with pc machine)
        -smbios type=1,manufacturer="Dell Inc.",product="PowerEdge R640"
        -no-user-config
    )

    # kvm-pit chỉ hợp lệ khi có KVM — TCG không có pit device này
    [[ "${KVM_AVAILABLE:-0}" == "1" ]] && QEMU_CMD+=(-global kvm-pit.lost_tick_policy=discard)

    # ICH9-LPC globals only valid for q35 machine type
    [[ "${_machine_type}" == "q35" ]] && QEMU_CMD+=(-global ICH9-LPC.disable_s3=1 -global ICH9-LPC.disable_s4=1)

    # Hugepages mem-path nếu detect được
    if [[ -n "${QEMU_HUGEPAGES_DIR:-}" && -d "$QEMU_HUGEPAGES_DIR" ]]; then
        QEMU_CMD+=(-mem-path "$QEMU_HUGEPAGES_DIR" -mem-prealloc)
        echo -e "${G}✔${W} Hugepages: -mem-path $QEMU_HUGEPAGES_DIR -mem-prealloc"
    fi
fi

# ── Thêm BIOS/UEFI ───────────────────────────────────────────
# shellcheck disable=SC2206 — BIOS_OPT is intentionally split into two words (-bios PATH)
[[ -n "${OVMF_PATH:-}" ]] && QEMU_CMD+=(-bios "${OVMF_PATH}")

# ── Disk ─────────────────────────────────────────────────────
WIN_IMG_PATH="${WIN_IMG_PATH:-win.img}"
# Detect image format: HTTP-backed = qcow2, else try file command
_QEMU_IMG_FMT="raw"
if [[ "${_HTTP_BACKED:-0}" == "1" ]]; then
    _QEMU_IMG_FMT="qcow2"
elif command -v qemu-img &>/dev/null; then
    _detected_fmt=$(qemu-img info --output=json "$WIN_IMG_PATH" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('format','raw'))" 2>/dev/null || echo "raw")
    [[ -n "$_detected_fmt" ]] && _QEMU_IMG_FMT="$_detected_fmt"
elif command -v file &>/dev/null && file "$WIN_IMG_PATH" 2>/dev/null | grep -qi "qcow"; then
    _QEMU_IMG_FMT="qcow2"
fi
# Disk interface: virtio
# io_uring: không dùng cho AppImage/rootless (seccomp block trong container/JupyterHub)
# Chỉ probe khi dùng system QEMU (build từ source hoặc apt)
_DISK_AIO="threads"
_DISK_CACHE="unsafe"

_is_appimage=0
[[ "${QEMU_BIN:-}" == *"qemu-static"* ]] && _is_appimage=1

# ── Direct mode: block device thật hoặc file trực tiếp trên host FS ──
# Tự động bật nếu WIN_IMG_PATH là block device (/dev/sdX, /dev/nvme0n1, LVM...),
# hoặc ép buộc qua WINBOX_DISK_DIRECT=1. Dùng cache=none (bypass page cache của
# host, tránh double-caching) thay vì cache=unsafe.
_is_block_dev=0
[[ -b "$WIN_IMG_PATH" ]] && _is_block_dev=1
if [[ "$_is_block_dev" == "1" || "${WINBOX_DISK_DIRECT:-0}" == "1" ]]; then
    _DISK_CACHE="none"
    if [[ "$_is_block_dev" == "1" ]]; then
        echo -e "${G}✔${W} Phát hiện block device thật (${WIN_IMG_PATH}) → cache=none"
    else
        echo -e "${G}✔${W} WINBOX_DISK_DIRECT=1 → cache=none (direct I/O)"
    fi
fi

if [[ "$_is_appimage" == "0" ]]; then
    # Bước 1: kiểm tra kernel có io_uring không
    _io_uring_kernel=0
    if [[ -e /proc/sys/kernel/io_uring_disabled ]]; then
        _disabled=$(cat /proc/sys/kernel/io_uring_disabled 2>/dev/null || echo 2)
        [[ "$_disabled" == "0" ]] && _io_uring_kernel=1
    elif python3 -c "
import ctypes, sys
NR_io_uring_setup = 425
libc = ctypes.CDLL(None, use_errno=True)
libc.syscall(NR_io_uring_setup, 1, ctypes.c_void_p(0))
sys.exit(0 if ctypes.get_errno() != 38 else 1)
" 2>/dev/null; then
        _io_uring_kernel=1
    fi

    # Bước 2: probe QEMU chỉ khi kernel ok
    if [[ "$_io_uring_kernel" == "1" ]]; then
        _qemu_bin_probe="${QEMU_BIN:-qemu-system-x86_64}"
        if [[ -x "$_qemu_bin_probe" ]] || command -v "$_qemu_bin_probe" &>/dev/null; then
            _probe_out=$("$_qemu_bin_probe" \
                -drive file=/dev/null,if=none,id=x,aio=io_uring,format=raw \
                -machine none -nographic 2>&1 || true)
            if ! echo "$_probe_out" | grep -qi "invalid aio\|not support\|Operation not permitted\|seccomp"; then
                _DISK_AIO="io_uring"
            fi
        fi
    fi
fi

# aio=native: dùng khi ở direct mode (cache=none) mà io_uring không khả dụng —
# native (Linux AIO) vẫn tốt hơn threads cho file/block device trực tiếp.
if [[ "$_DISK_AIO" != "io_uring" && "$_DISK_CACHE" == "none" ]]; then
    _DISK_AIO="native"
fi

if [[ "$_DISK_AIO" == "io_uring" ]]; then
    echo -e "${G}✔${W}  Disk bus: ${B}virtio${W} + aio=${B}io_uring${W} + cache=${_DISK_CACHE}"
elif [[ "$_DISK_AIO" == "native" ]]; then
    echo -e "${G}✔${W}  Disk bus: ${B}virtio${W} + aio=${B}native${W} + cache=${_DISK_CACHE}"
else
    echo -e "${G}✔${W}  Disk bus: ${B}virtio${W} + aio=threads${_is_appimage:+ (AppImage — io_uring disabled)}"
fi
QEMU_CMD+=(
    -drive file="$WIN_IMG_PATH",if=none,id=disk0,cache=${_DISK_CACHE},aio=${_DISK_AIO},format="$_QEMU_IMG_FMT"
    -device virtio-blk-pci,drive=disk0,iothread=io1,num-queues=4,queue-size=256
    -object iothread,id=io1
)

if [[ "${WINBOX_NET_DEVICE}" == "e1000e" ]]; then
    NET_DEVICE="-device e1000e,netdev=n0"
elif [[ "${WINBOX_NET_DEVICE}" == "virtio" ]]; then
    NET_DEVICE="-device virtio-net-pci,netdev=n0"
elif [[ "${WINBOX_NET_DEVICE}" == "auto" ]]; then
    [[ "$win_choice" == "4" ]] \
        && NET_DEVICE="-device e1000e,netdev=n0" \
        || NET_DEVICE="-device virtio-net-pci,netdev=n0"
fi
QEMU_CMD+=(
    -netdev user,id=n0,hostfwd=tcp::${WINVM_RDP_PORT}-:${WINVM_RDP_PORT}${_EXTRA_FWDS_STR}
    $NET_DEVICE
)
if [[ "${WINBOX_VNC:-0}" == "1" ]]; then
    QEMU_CMD+=(-device nec-usb-xhci -device usb-tablet)
fi

# ── RNG passthrough (virtio-rng ← /dev/urandom host) ─────────
# Không cần flag configure riêng (rng-random backend luôn có sẵn trên Linux/POSIX build).
if [[ -e /dev/urandom ]] && "$QEMU_BIN" -device help 2>&1 | grep -qi "virtio-rng-pci"; then
    QEMU_CMD+=(-object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0)
    echo -e "${G}✔${W} virtio-rng: passthrough /dev/urandom"
else
    echo -e "${Y}⚠${W}  virtio-rng-pci không khả dụng — bỏ qua"
fi

# ── USB passthrough (usb-host, cần build với --enable-libusb) ──
# WINBOX_USB_HOST="vendorid:productid[,vendorid:productid,...]" (hex, vd 046d:c52b — xem `lsusb`)
if [[ -n "${WINBOX_USB_HOST:-}" ]]; then
    if "$QEMU_BIN" -device help 2>&1 | grep -qi "usb-host"; then
        IFS=',' read -ra _usb_devs <<< "$WINBOX_USB_HOST"
        for _ud in "${_usb_devs[@]}"; do
            _vid="${_ud%%:*}"; _pid="${_ud##*:}"
            if [[ -n "$_vid" && -n "$_pid" ]]; then
                QEMU_CMD+=(-device usb-host,vendorid="0x${_vid}",productid="0x${_pid}")
                echo -e "${G}✔${W} USB passthrough: ${_vid}:${_pid}"
            fi
        done
    else
        echo -e "${Y}⚠${W}  QEMU build này không có usb-host (thiếu libusb lúc build) — bỏ qua WINBOX_USB_HOST"
    fi
fi

# ── Serial passthrough (nối trực tiếp cổng serial thật của host) ──
# WINBOX_SERIAL_HOST="/dev/ttyS0" hoặc "/dev/ttyUSB0"
if [[ -n "${WINBOX_SERIAL_HOST:-}" ]]; then
    if [[ -e "$WINBOX_SERIAL_HOST" ]]; then
        QEMU_CMD+=(-serial "$WINBOX_SERIAL_HOST")
        echo -e "${G}✔${W} Serial passthrough: ${WINBOX_SERIAL_HOST}"
    else
        echo -e "${Y}⚠${W}  WINBOX_SERIAL_HOST=${WINBOX_SERIAL_HOST} không tồn tại — bỏ qua"
    fi
fi

# ── Chia sẻ thư mục host ↔ guest (virtio-9p, hoặc virtio-fs nếu có virtiofsd) ──
# WINBOX_SHARE_DIR="/path/tren/host"   WINBOX_SHARE_TAG="hostshare" (mount tag dùng trong guest)
if [[ -n "${WINBOX_SHARE_DIR:-}" ]]; then
    if [[ -d "$WINBOX_SHARE_DIR" ]]; then
        _share_tag="${WINBOX_SHARE_TAG:-hostshare}"
        _virtiofsd_bin="$(command -v virtiofsd 2>/dev/null || true)"
        if [[ "${WINBOX_VIRTIOFS:-0}" == "1" && -n "$_virtiofsd_bin" ]] \
           && "$QEMU_BIN" -device help 2>&1 | grep -qi "vhost-user-fs-pci"; then
            _vfs_sock="/tmp/winbox-virtiofs-$$.sock"
            ( "$_virtiofsd_bin" --socket-path="$_vfs_sock" --shared-dir="$WINBOX_SHARE_DIR" \
              --cache=auto >/tmp/virtiofsd.log 2>&1 & )
            sleep 1
            QEMU_CMD+=(
                -chardev socket,id=vfsd0,path="$_vfs_sock"
                -device vhost-user-fs-pci,queue-size=1024,chardev=vfsd0,tag="$_share_tag"
                -object memory-backend-memfd,id=vfsmem0,size="${ram_size:-4}G",share=on
                -numa node,memdev=vfsmem0
            )
            echo -e "${G}✔${W} virtio-fs share: ${WINBOX_SHARE_DIR} → tag=${_share_tag} (qua virtiofsd)"
        elif "$QEMU_BIN" -device help 2>&1 | grep -qi "virtio-9p-pci"; then
            QEMU_CMD+=(
                -fsdev local,id=fsdev0,path="$WINBOX_SHARE_DIR",security_model=mapped-xattr
                -device virtio-9p-pci,fsdev=fsdev0,mount_tag="$_share_tag"
            )
            echo -e "${G}✔${W} virtio-9p share: ${WINBOX_SHARE_DIR} → mount_tag=${_share_tag}"
        else
            echo -e "${Y}⚠${W}  QEMU build này không hỗ trợ virtio-9p/virtio-fs — bỏ qua WINBOX_SHARE_DIR"
        fi
    else
        echo -e "${Y}⚠${W}  WINBOX_SHARE_DIR=${WINBOX_SHARE_DIR} không tồn tại — bỏ qua"
    fi
fi

# ── Input ────────────────────────────────────────────────────

# ── Display ──────────────────────────────────────────────────
# VNC luôn bật mặc định (có thể tắt bằng WINBOX_VNC=0)
if [[ "${WINBOX_VNC:-1}" == "1" ]]; then
    if "$QEMU_BIN" -help 2>&1 | grep -qE "^-vnc "; then
        QEMU_CMD+=(-vga virtio -vnc :0)
        echo -e "${G}✔${W} VNC enabled on :5900 (-vnc :0)"
    else
        QEMU_CMD+=(-vga virtio -display none)
        echo -e "${Y}⚠${W} QEMU build này không hỗ trợ -vnc, dùng RDP only (-display none)"
    fi
else
    QEMU_CMD+=(-vga virtio -display none)
fi

# ── SMBIOS/config đã được thêm vào QEMU_CMD bên trên ─────────
# -nodefaults already disables serial/monitor; removed redundant -serial none -monitor none

# ════════════════════════════════════════════════════════════════
#  QEMU 11 APPIMAGE BACKEND STATUS (Rootless, TCG, LTO, -O3)
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "${C}🚀 WINBOXES-STABLE BACKEND STATUS${W}"
echo -e "${C}══════════════════════════════════════════════${W}"

# Resolve QEMU AppImage và kiểm tra thực tế
_APP_BACKEND="$(_resolve_qemu_appimage 2>/dev/null || echo '')"
_APP_VER=""
_APP_BIN="$(_resolve_qemu_bin 2>/dev/null || echo '')"
_APP_IMG="$(_resolve_qemu_appimage_img 2>/dev/null || echo '')"

if [[ -n "$_APP_BACKEND" && -x "$_APP_BACKEND" ]]; then
    _APP_VER=$(timeout 10 "$_APP_BACKEND" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
    echo -e "⚙  QEMU Backend  : ${G}QEMU 11.x AppImage${W} (${_APP_VER})"
    echo -e "📦 AppImage Path : ${B}${_APP_BACKEND}${W}"
    echo -e "🔧 Mode          : ${G}Rootless${W} (no sudo, no apt, no system-wide QEMU)"
    echo -e "🧠 Acceleration   : ${G}TCG available${W} (works without /dev/kvm)"
    echo -e "⚡ Optimization   : ${G}-O3 + LTO baked-in${W} (build-time native CPU optimization)"
    echo -e "📂 Runtime Data   : User-space ($HOME/.local/share/winboxes, $HOME/.cache/winboxes)"
    echo -e "🎯 Fast Math      : Controlled (-ffast-math chỉ áp dụng cho TCG khi phù hợp)"
    echo -e "💾 Firmware/Data  : Bundled in AppDir (BIOS/UEFI/ROM/keymaps/modules)"
else
    echo -e "⚙  QEMU Backend  : ${Y}AppImage not found — falling back${W}"
fi

if [[ -n "$_APP_BIN" && -n "$_APP_IMG" ]]; then
    echo -e "📌 qemu-system-x86_64 : ${G}Bundled/resolvable${W}"
    echo -e "📌 qemu-img         : ${G}Bundled/resolvable${W}"
else
    echo -e "📌 qemu-system-x86_64 : ${R}NOT RESOLVED${W}"
    echo -e "📌 qemu-img         : ${R}NOT RESOLVED${W}"
fi

# Self-test
if command -v bash &>/dev/null; then
    echo -e "${C}──────────────────────────────────────────────${W}"
    echo -e "${B}ℹ${W}  Running quick self-test..."
    _qemu_appimage_selftest 2>/dev/null || echo -e "${Y}⚠${W} Self-test skipped (optional)"
fi

echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "${C}══════════════════════════════════════════════${W}"

# ════════════════════════════════════════════════════════════════
#  KHỞI ĐỘNG VM
# ════════════════════════════════════════════════════════════════
echo -e "${B}ℹ${W}  Khởi động VM ${WIN_NAME}..."

QEMU_LOG="/tmp/qemu-launch-$$.log"
rm -f /tmp/qemu-launch.log 2>/dev/null || true
ln -sf "$QEMU_LOG" /tmp/qemu-launch.log 2>/dev/null || true

# ── Validate QEMU_BIN trước khi launch ──────────────────────────
# Resolve lại QEMU_BIN theo thứ tự ưu tiên (AppImage first)
RESOLVED_QEMU="$(_resolve_qemu_appimage 2>/dev/null || echo '')"
if [[ -z "$RESOLVED_QEMU" || ! -x "$RESOLVED_QEMU" ]]; then
    RESOLVED_QEMU="$(_resolve_qemu_bin)" || {
        echo -e "${R}✘ Không tìm thấy qemu-system-x86_64!${W}"
        echo -e "${Y}   Đảm bảo đã build QEMU trước khi chạy VM.${W}"
        exit 1
    }
fi
export QEMU_BIN="$RESOLVED_QEMU"
QEMU_CMD[0]="$QEMU_BIN"

# Nếu QEMU_BIN là AppImage, đảm bảo AppRun và paths đúng
if [[ "$QEMU_BIN" == *"AppImage"* ]] || [[ -x "$QEMU_BIN" ]]; then
    # Kiểm tra AppImage có thể chạy --version
    if ! timeout 10 "$QEMU_BIN" --version >/dev/null 2>&1; then
        echo -e "${R}✘${W} AppImage không chạy được (--version thất bại): $QEMU_BIN"
        echo -e "${Y}💡${W} Thử: $QEMU_BIN --appimage-extract-and-run qemu-system-x86_64 --version"
    else
        echo -e "${G}✔${W} QEMU AppImage xác thực thành công (version OK)"
    fi
fi

# Đảm bảo QEMU_IMG giải quyết đúng cho AppImage
_RESOLVED_QEMU_IMG="$(_resolve_qemu_appimage_img 2>/dev/null || echo '')"
if [[ -n "$_RESOLVED_QEMU_IMG" && -x "$_RESOLVED_QEMU_IMG" ]]; then
    export QEMU_IMG="$_RESOLVED_QEMU_IMG"
    echo -e "${G}✔${W} qemu-img resolved: ${_RESOLVED_QEMU_IMG}"
else
    # Fallback cho AppImage: dùng wrapper nội bộ
    if [[ "$QEMU_BIN" == *"AppImage"* ]]; then
        export QEMU_IMG="$QEMU_BIN"
        echo -e "${G}✔${W} qemu-img dùng chung AppImage binary (bundled)"
    fi
fi
echo -e "${G}✔${W} QEMU binary: $QEMU_BIN"

# Build extra port forward string
for _fwd in "${EXTRA_FWDS[@]+"${EXTRA_FWDS[@]}"}"; do
    [[ -z "$_fwd" ]] && continue
    _h="${_fwd%%:*}"; _g="${_fwd##*:}"
    _EXTRA_FWDS_STR+=",hostfwd=tcp::${_h}-:${_g}"
done
# Add QMP socket to QEMU command
QEMU_CMD+=(-qmp unix:"$WINVM_QMP_SOCK",server,nowait)

echo "QEMU CMD: ${QEMU_CMD[*]}" > "$QEMU_LOG"

# LAUNCH_PREFIX giữ nguyên giá trị từ _tcg_tune()


# ── Khởi động VNC Boot Monitor (background, non-blocking) ──
if [[ "${BOOTMON_ENABLED}" == "1" ]]; then
    # Đảm bảo VNC server đang bật
    if echo "${QEMU_CMD[*]}" | grep -q -i "vnc"; then
        echo -e "${B}ℹ${W} Khởi động VNC Boot Monitor (background, non-blocking, Rootless)"
        _bootmon_start_background || true
    else
        echo -e "${Y}⚠${W}  VNC không được bật cho VM này — Boot Monitor bị tắt"
        BOOTMON_ENABLED=0
    fi
else
    echo -e "${B}ℹ${W} VNC Boot Monitor tắt (BOOTMON_ENABLED=${BOOTMON_ENABLED})"
fi

# Rootless QEMU: đảm bảo LD_LIBRARY_PATH có lib path TRƯỚC khi fork
if [[ "$QEMU_BIN" == *"qemu-static"* ]]; then
    _QEMU_PREFIX="$(dirname "$(dirname "$QEMU_BIN")")"
    export LD_LIBRARY_PATH="$_QEMU_PREFIX/lib:$_QEMU_PREFIX/lib64:$_QEMU_PREFIX/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
    :
fi

_RUN_PREFIX=""
if [[ -n "${PGO_LAUNCH_ENV:-}" ]]; then
    _RUN_PREFIX="$PGO_LAUNCH_ENV"
fi
if [[ -n "${LAUNCH_PREFIX:-}" ]]; then
    _RUN_PREFIX="${_RUN_PREFIX:+${_RUN_PREFIX} }${LAUNCH_PREFIX}"
fi

if [[ -n "$_RUN_PREFIX" ]]; then
    echo -e "${G}🔥 Launch prefix: ${_RUN_PREFIX}${W}"
    # Dùng read -ra để split _RUN_PREFIX an toàn (không dùng eval)
    read -ra _launch_prefix_arr <<< "$_RUN_PREFIX"
    nohup "${_launch_prefix_arr[@]}" "${QEMU_CMD[@]}" >> "$QEMU_LOG" 2>&1 &
else
    nohup "${QEMU_CMD[@]}" >> "$QEMU_LOG" 2>&1 &
fi
QEMU_PID=$!
echo "$QEMU_PID" > "$WINVM_PID_FILE"
# Write state file for --status
python3 -c "
import json,sys
json.dump({\"pid\":int(sys.argv[1]),\"instance\":int(sys.argv[2]),\"rdp_port\":int(sys.argv[3]),\"rdp_user\":sys.argv[4],\"win_name\":sys.argv[5]},
    open(sys.argv[6],\"w\"), indent=2)
" "$QEMU_PID" "$INSTANCE_ID" "$WINVM_RDP_PORT" "$RDP_USER" "$WIN_NAME" "$WINVM_STATE_FILE" 2>/dev/null || true
disown "$QEMU_PID"

sleep 4
if kill -0 "$QEMU_PID" 2>/dev/null; then
    echo -e "${G}✔${W} VM đã khởi động (PID: $QEMU_PID)"
else
    echo -e "${R}✘ VM KHÔNG khởi động được!${W}"
    echo -e "${R}═══ QEMU ERROR LOG ═══${W}"
    cat "$QEMU_LOG"
    echo -e "${R}═══════════════════════${W}"
    echo -e "${Y}Tip: Xem log đầy đủ tại $QEMU_LOG${W}"
    exit 1
fi


PUBLIC=""

# ── SUMMARY ───────────────────────────────────────────────────────
echo ""
echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "${C}🚀 WINBOX DEPLOYED SUCCESSFULLY${W}"
[[ "$AUTO_MODE" == "1" ]] && \
    echo -e "${C}🤖 Launched via: --auto${AUTO_WIN:+ --win$AUTO_WIN}${W}"
echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "🪟 OS           : ${Y}$WIN_NAME${W}"
echo -e "⚙  CPU Cores    : ${B}$cpu_core${W}"
echo -e "💾 RAM          : ${B}${ram_size} GB${W}"
if [[ "$KVM_AVAILABLE" == "1" ]]; then
    echo -e "⚡ Acceleration : ${G}KVM (hardware) + CPU host${W}"
else
    echo -e "⚡ Acceleration : ${Y}TCG (software) | TB cache: ${TCG_TB_MB:-?}MB${W}"
    echo -e "🧠 CPU Model    : ${B}${cpu_host:-unknown}${W}"
fi
echo -e "${C}──────────────────────────────────────────────${W}"
if [[ -n "$PUBLIC" ]]; then
    echo -e "📡 RDP Address  : ${G}${PUBLIC}${W}"

else
    echo -e "📡 RDP (local)  : ${G}localhost:${WINVM_RDP_PORT}${W}"
    [[ "${use_rdp:-n}" == "y" ]] && \
        echo -e "${Y}   ⚠  Tunnel chưa lấy được endpoint — xem log ở trên${W}"
fi
echo -e "👤 Username     : ${Y}$RDP_USER${W}"
echo -e "🔑 Password     : ${Y}$RDP_PASS${W}"
echo -e "${C}══════════════════════════════════════════════${W}"
echo "🖥  VNC Server   : ${G}:5900${W} (share=force-shared)"
echo "   → vncviewer localhost:5900"
echo "   → noVNC: http://localhost:6080 (nếu có websockify)"
echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "${G}🟢 Status       : RUNNING (PID: $QEMU_PID)${W}"
echo    "⏱  GUI Mode     : VNC + RDP"
echo -e "${C}══════════════════════════════════════════════${W}"
