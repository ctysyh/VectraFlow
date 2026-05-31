// src/device/compute/tk_executor.cuh
__device__ void TK_Execute(CSV* csv) {
    // 1. 读取通用字段
    TKType op_type = csv->task_kernel_type;
    void* input = csv->input_ptr;
    void* output = csv->output_ptr;
    
    // 2. 读取扩展字段 (位于 CSV 固定头部之后)
    void* ext_fields = reinterpret_cast<char*>(csv) + sizeof(CSV_Header);

    // 3. 查表调用算子本体 (来自 operators/backends)
    // 例如调用 TileLang 生成的 FlashAttention Kernel
    extern void (*op_dispatch_table[])(void*, void*, void*);
    op_dispatch_table[op_type](input, output, ext_fields);

    // 4. 更新 CSV 状态 (集成在 next_csv 指针的低位)
    // 使用 Release 内存序，确保上方计算的数据写入对 CK 全局可见
    uint64_t old_next = atomic_load(&(csv->next_csv), memory_order_relaxed);
    uint64_t new_next = (old_next & ~0x3ULL) | CSV_STATE_DONE; // 低位设为 DONE
    atomic_store(&(csv->next_csv), new_next, memory_order_release);
}
