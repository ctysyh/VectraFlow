struct TKContext {
    int tk_id;
    bool is_active;             // 是否被激活（受弹性控制）
    CSV* head_csv;              // CSV 链表头（用于弹出 done）
    CSV* tail_csv;              // CSV 链表尾（用于 CAS 追加 new）
    PerformanceCounter perf;    
};