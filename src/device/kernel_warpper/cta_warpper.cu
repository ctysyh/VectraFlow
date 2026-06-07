// This function list is codegened during runtime, as well `switch`es, `SMEM_Layout` and
// `UnpackCSV` afterwards.
extern __device__ void user_func_warp(...);
extern __device__ void user_func_cta(...);
extern __device__ void user_func_ctapair(...);
extern __device__ void ck_worker(...);

// This layout is merely schematic. For real application, *Swizzle* is necessary.
struct alignas(128) SMEM_Layout {
    // Area 1: CK workspace (Only being accessed by Warp 0)
    // Including MTG pointers, all the queues and so on.
    alignas(128) CK_Context ck_ctx[CK_WORKSPACE_SIZE]; 
    
    // Area 2: CSV Slab Pool
    alignas(128) char csv_slab_pool[SLAB_POOL_SIZE]; 
    
    // Area 3: TK user func workspace
    // *USER_SMEM_SIZE* of each kind of TK instance can be different and is computed and
    // confirmed on JIT. Here 2D-array writing is just for good-looking. Of course,
    // *CK_WORKSPACE_SIZE* and *SLAB_POOL_SIZE* ahead does as well.
    alignas(128) char tk_user_workspace[NUM_TK_INSTANCES][USER_SMEM_SIZE];
};

extern "C" __global__ void __cluster_dims__(16,1,1) CGA_Wrapper(bool *global_terminate_flag, ...) {
    // 0. Configuration
    if (blockIdx.x >= 4 && blockIdx.x % 2 == 0 && threadIdx.x == 0) {
        asm volatile("tcgen05.mma.cta_group::2.kind::f8f6f4 ...;" ::: "memory");
    }

    extern __shared__ char smem[];
    uint64_t dsmem_base;
    asm volatile("cvta.to.shared::cluster.u64 %0, %1;" : "=l"(dsmem_base) : "l"(smem));
    SMEM_Layout* layout = (SMEM_Layout*)dsmem_base;

    // 1. Identity Verification
    bool is_ck = (threadIdx.x >= 0 && threadIdx.x < 32);
    bool is_tk_master = false;
    int my_tk_id = -1;
    char* my_workspace = nullptr;
    uint64_t my_mbarrier_addr = 0ULL;

    if (blockIdx.x == 0) { // CTA 0: CK + Warp-TKs
        if (threadIdx.x < 32) { // CK
            my_tk_id = threadIdx.x;
            my_workspace = layout->ck_ctx[my_tk_id];
        } else { // Warp-TKs (31)
            int warp_id_in_cta = threadIdx.x / 32;
            if (threadIdx.x % 32 == 0) is_tk_master = true;
            my_tk_id = warp_id_in_cta - 1; // TK 0~30
            my_workspace = layout->tk_user_workspace[my_tk_id];
            my_mbarrier_addr = (uint64_t)&layout->tk_mbarriers[my_tk_id]; // DSMEM mbarrier
        }
    } else if (blockIdx.x <= 3) { // CTA 1~3: CTA-TKs
        if (threadIdx.x == 0) is_tk_master = true;
        my_tk_id = 31 + (blockIdx.x - 1); // TK 31~33
        my_workspace = layout->tk_user_workspace[my_tk_id];
        my_mbarrier_addr = (uint64_t)&layout->tk_mbarriers[my_tk_id];
    } else { // CTA 4~15: CTA-Pair-TKs (6)
        int pair_idx = (blockIdx.x - 4) / 2;
        int role_in_pair = (blockIdx.x - 4) % 2; // 0=Master CTA, 1=Slave CTA
        if (role_in_pair == 0 && threadIdx.x == 0) is_tk_master = true;
        my_tk_id = 34 + pair_idx; // TK 34~39
        my_workspace = layout->tk_user_workspace[my_tk_id];
        my_mbarrier_addr = (uint64_t)&layout->tk_mbarriers[my_tk_id];
    }
    
    // 2. Persistent Loop
    while (atomic_load_system(global_terminate_flag) == false) {
        // --- TK Logic ---
        if (!is_ck) {
            // --- TK Wait: If there is not a CSV, sleep and wait ---
            if (is_tk_master) {
                CSV* current_csv = atomic_load_relaxed(&my_workspace->current_csv);
                if (current_csv == NULL) {
                    asm volatile("mbarrier.try_wait.parity.shared::cluster.b64 _, %0, 1;" 
                                :: "r"(my_mbarrier_addr) : "memory");
                    current_csv = atomic_load_acquire(&my_workspace->current_csv);
                }
            }
            
            // --- Infra Pre Logic ---
            Sync_My_TK_Instances(); 
            
            typename OpType::ArgsTuple args_tuple;
            if (is_tk_master) {
                args_tuple = UnpackCSV<ExtType, FuncArgs...>(my_workspace->current_csv);
                // For Warp level TKs, `__shfl_sync` can do the best. But for those bigger TKs,
                // a temporary SMEM buffer is needed and the master thread should write args into
                // buffer, then sub-masters of each warp read the buffer and execute `__shfl_sync`
                // inside its warp. By this way, the temporary SMEM buffer is only read by 32
                // sub-masters, not all of the 1024 threads.
                Broadcast_Args(args_tuple);
            }
            Sync_My_Sub_Warps();

            // --- User Compute Logic ---
            Execute_My_User_Func(my_tk_id, args_tuple);

            // --- Infra Post Logic ---
            Sync_My_TK_Instances();
            
            if (is_tk_master) {
                Mark_CSV_Done_And_Advance(my_workspace->current_csv);
                if (my_workspace->current_csv == NULL) {
                    Reset_Mbarrier(my_mbarrier_addr);
                }
            }
        }

        // --- CK Logic ---
        if (is_ck) ck_worker(layout, my_tk_id);
    }
}