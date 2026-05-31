struct CKWorkspace {
    // 绑定的 TK 上下文
    TKContext managed_tks[MAX_TK_PER_CK];
    
    // 绑定的 MTG 实例 (Ring Buffer 指针)
    MacroTaskGraph_Context* mtg_instances[MAX_MTG_PER_CK];
    
    // 临时挂载缓冲区：CAS 失败时的避风港
    CSV* pending_csv_buffer[MAX_PENDING_CSVS];
    int pending_csv_count;
    
    // 特殊调度列表
    MacroTaskGraph_Node* mtg_ready_list[MAX_READY_NODES]; // Host 补充节点后的恢复点
    uint32_t hen_linked_list[MAX_HEN_NODES];              // HEN 节点的 MTG Ring Buffer 偏移量
    
    // 主机交互
    HostMessageRingBuffer host_message_buffer;             // io_uring 协议
};


__device__ void ControlKernel_Main(CKWorkspace* ws) {
    while (true) {
        // Step 1: 处理 Host 控制面消息 (扩缩容)
        ProcessHostMessages(ws);
        
        // Step 2: 遍历管理的 TK，回收完成的 CSV 并推进 MTG 状态
        for (int i = 0; i < MAX_TK_PER_CK; ++i) {
            if (!ws->managed_tks[i].is_active) continue;
            ProcessTKChain(ws, &ws->managed_tks[i]);
        }
        
        // Step 3: 处理 mtg_ready_list (Host 刚补充的新节点)
        ProcessMTGReadyList(ws);
        
        // Step 4: 尝试将之前 CAS 失败挂起的 CSV 重新推入 TK
        RetryPendingCSVs(ws);
        
        // Step 5: 将 HEN 就绪信息提交给 host_message_buffer
        FlushHENToHost(ws);
        
        // 避免 CK 空转消耗过多功耗 (实际可能采用 yield 或特定等待指令)
        if (NoWorkDone(ws)) break; // 或继续自旋
    }
}