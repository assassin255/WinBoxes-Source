# Prompt triển khai `-accel nir` cho QEMU

Hãy triển khai `-accel nir` cho QEMU, trong đó NIR = **No Intermediate Representation**, là một **Direct-Mapping DBT JIT** chuyên biệt cho `x86-64 Guest → x86-64 Host`, hoạt động hoàn toàn trong Linux userspace/rootless, container, JupyterLab, VPS và HPC không có KVM/VT-x/AMD-V.

## Kiến trúc cốt lõi

Fast path phải đi theo:

`Guest x86-64 → decode/classify → direct host x86-64 mapping → native code cache → execute`

NIR **không tạo TCG IR hoặc IR trung gian mới** trong fast path. NIR không thay thế TCG mà dùng TCG làm universal fallback cho instruction, CPU state, memory, MMIO, privileged operation hoặc exception không thể direct-map chính xác.

Chỉ kích hoạt Direct Mapping khi Guest và Host cùng `x86-64`; kiến trúc khác phải fallback TCG. Không phá hoặc loại bỏ `-accel tcg`, KVM, Xen, HVF hoặc các backend hiện có.

Tận dụng infrastructure QEMU hiện có như x86 decoder, CPUState, TB/code cache, memory/SoftMMU, TLB, exception/interrupt handling, invalidation và threading thay vì rewrite toàn bộ CPU subsystem.

## Direct DBT

Implement các kỹ thuật Direct DBT phù hợp:

- Direct instruction mapping.
- Lazy translation.
- Translation/code cache.
- TB lookup và cache.
- Direct block chaining.
- Indirect branch target caching.
- RET/return-address fast path.
- Register mapping và register liveness.
- Lazy CPU-state synchronization.
- Native EFLAGS forwarding/lazy flags khi semantics cho phép.
- Fast-path/slow-path dispatch.
- Inline RAM/TLB fast path.
- Guest-base/direct-offset mapping khi an toàn.
- Partial evaluation/context specialization.
- Redundant-state elimination.
- Self-modifying-code detection/invalidation.
- Precise Guest-PC/Host-PC exception mapping.
- Adaptive hot-block detection.
- Optional superblock/trace formation.

Mọi optimization phải bảo toàn tuyệt đối guest architectural semantics.

## TCG fallback

NIR không được direct-execute một cách không an toàn:

- Privileged instructions.
- MMIO.
- Unmapped memory.
- Guest page faults.
- Unsupported CPU features.
- Instruction có semantic mismatch.
- Các trường hợp exception-sensitive mà NIR không thể reconstruct chính xác.

Các trường hợp trên phải fallback về TCG/helper. Fallback phải granular ở mức instruction hoặc translation block, không bắt buộc toàn bộ VM chuyển sang TCG chỉ vì một instruction không map được.

TCG vẫn là safety net đầy đủ của NIR.

## Memory fast path

Tối ưu memory access bằng inline TLB/direct mapping khi có thể, nhưng **không được bypass guest MMU, permission semantics hoặc memory ordering**.

Guest-base/direct-offset chỉ được dùng khi chứng minh an toàn.

Không phụ thuộc SIGSEGV làm cơ chế duy nhất để xử lý guest memory fault.

Hugepages chỉ là optional optimization. NIR phải chạy bình thường khi host/container/HPC không cho phép hugepages và không yêu cầu root.

## CPU state và registers

Implement register mapping/liveness để hạn chế register spilling.

Có thể pin một số host registers cho Guest Base hoặc CPUState nếu benchmark chứng minh có lợi, nhưng phải kiểm soát ABI, spilling và thread safety.

Lazy CPU-state synchronization: chỉ materialize guest state khi thực sự cần cho branch, helper, exception, interrupt, fallback hoặc context boundary.

Tận dụng native x86-64 flags khi guest và host semantics tương thích; không được giả định EFLAGS luôn tương đương nếu có semantic khác biệt.

## Block chaining và branching

Cho phép TB đã dịch nhảy trực tiếp tới TB đích thay vì quay lại dispatcher khi an toàn.

Hỗ trợ indirect branch target cache và RET fast path.

Mọi runtime patching phải thread-safe, không gây execution vào code đang được patch và phải xử lý invalidation chính xác.

## Multi-threaded NIR

NIR phải hỗ trợ **parallel translation**:

- Tự động phát hiện số CPU host phù hợp.
- Có worker pool để dịch các TB độc lập song song.
- Queue các TB chưa dịch.
- Worker có thể direct-map và generate native code song song.
- Shared code cache phải thread-safe.
- TB publication phải atomic.
- Có deduplication để tránh nhiều worker cùng dịch một TB.
- Ưu tiên lock-free hoặc fine-grained locking trên hot path.
- Background translation không được block guest execution nếu không cần thiết.
- Khi guest gặp TB chưa có bản dịch, có foreground translation fallback để tránh stall không cần thiết.
- Có cơ chế giới hạn worker để tránh oversubscription trong container/HPC.
- Tận dụng QEMU MTTCG/threading infrastructure khi phù hợp thay vì xây lại toàn bộ threading subsystem.

Nếu hỗ trợ nhiều vCPU guest chạy song song, phải đảm bảo memory ordering, atomic operations, CPU-state synchronization, TLB invalidation, interrupt delivery và SMC correctness.

Parallelism không được đánh đổi architectural correctness.

## NIR không dùng compiler backend nặng

Không đưa LLVM hoặc Cranelift vào NIR fast path.

NIR ưu tiên:

**translate cực nhanh + direct execution + code cache + chaining.**

Không biến NIR thành một compiler framework lớn.

Nếu cần optimizing JIT trong tương lai, phải thiết kế nó như một tầng riêng và chỉ thêm sau khi benchmark chứng minh cần thiết.

## Full Windows VM

Mục tiêu là boot và chạy Full Windows x86-64 VM thông qua NIR + TCG hybrid.

Phải xử lý đúng:

- Windows kernel.
- Drivers.
- Paging.
- System calls.
- Interrupts.
- CPUID.
- MSR.
- Exceptions.
- Page faults.
- MMIO.
- Self-modifying code.
- Atomic instructions.
- Memory ordering.
- CPU feature detection.

NIR chỉ direct-map những phần có thể đảm bảo semantic correctness; mọi phần còn lại fallback TCG.

## Phases triển khai

### Phase 1 — Integration

- Inspect toàn bộ QEMU source tree.
- Xác định accelerator, TCG, x86 CPU, TB, memory, SoftMMU/TLB và threading integration points.
- Lập kế hoạch file-by-file.
- Tạo `-accel nir`.
- Kiểm tra capability và fallback.
- Không phá backend hiện có.

### Phase 2 — Minimal Direct Mapper

Implement decoder/classifier và direct x86-64 → x86-64 mapping tối thiểu.

Mục tiêu đầu tiên là chạy được các instruction đơn giản và fallback chính xác về TCG khi không map được.

### Phase 3 — Lazy Translation + Code Cache

Implement lazy translation, TB lookup, native code cache và lifecycle management.

### Phase 4 — Multi-threaded Translation

Implement worker pool, translation queue, atomic TB publication, deduplication và parallel translation.

Benchmark scaling từ 1 → nhiều worker.

### Phase 5 — Register + Flags

Implement register mapping, liveness, lazy state synchronization và native flags fast path.

### Phase 6 — Block Chaining

Implement direct TB chaining, indirect branch cache và RET fast path.

### Phase 7 — Memory Fast Path

Implement inline TLB/direct RAM fast path và guest-base/direct-offset khi an toàn.

### Phase 8 — Correctness

Hoàn thiện exception/interrupt handling, precise Guest-PC mapping, SMC invalidation, MMIO và fallback correctness.

### Phase 9 — Context Specialization

Thêm partial evaluation/context specialization và redundant-state elimination nếu benchmark chứng minh có lợi.

### Phase 10 — Hot Path

Thêm hot-block detection và optional superblock/trace formation.

Không thêm optimization nặng nếu lợi ích không vượt translation cost.

### Phase 11 — Full Windows

Boot Windows x86-64 và xử lý toàn bộ compatibility issues bằng NIR/TCG hybrid.

## Testing

Sau mỗi phase phải:

1. Build QEMU.
2. Chạy unit tests liên quan.
3. Chạy instruction-equivalence tests NIR vs TCG.
4. Chạy random differential tests.
5. Chạy exception/fault tests.
6. Chạy memory/MMIO tests.
7. Chạy SMC tests.
8. Chạy multithread race/stress tests.
9. Boot test.
10. Tự sửa regression trước khi chuyển phase tiếp theo.

Không được đánh đổi correctness để lấy benchmark.

## Benchmark

So sánh:

- `TCG`
- `NIR`
- `NIR + TCG fallback`

Đo:

- Translation latency.
- TBs/sec.
- Parallel translation scaling.
- Execution throughput.
- Branch-heavy workload.
- Memory-heavy workload.
- Code-cache size.
- CPU usage.
- Windows boot time.
- Windows login time.
- Application startup.
- Long-running stability.
- Translation miss/fallback rate.

Nếu có KVM, chỉ dùng KVM làm native/reference benchmark. NIR tuyệt đối không phụ thuộc KVM.

Mọi claim về “native speed” phải dựa trên benchmark thực tế, không được suy đoán từ kiến trúc.

## Quy tắc phát triển

Trước khi sửa source:

1. Inspect source tree.
2. Xác định chính xác integration points.
3. Lập dependency graph.
4. Lập kế hoạch file-by-file.
5. Implement từng phase nhỏ.
6. Build/test sau mỗi thay đổi lớn.

Không xóa hoặc phá infrastructure QEMU hiện có.

Không giả định API hoặc internal structure của phiên bản QEMU khác; hãy kiểm tra source tree thực tế trước khi code.

## Mục tiêu cuối cùng

Tạo một accelerator:

**`-accel nir` = rootless-capable + same-ISA + No-IR + Direct-Mapping DBT + parallel translation + native execution tối đa + TCG fallback đầy đủ**

với mục tiêu giảm tối đa translation overhead, tránh IR trong fast path, tận dụng native x86-64 host execution và vẫn đủ tương thích để chạy Full Windows x86-64 VM trong môi trường Linux rootless/HPC/container.
