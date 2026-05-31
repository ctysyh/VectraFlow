// This function list is codegened during runtime, as well `switch`es and `UnpackCSV` afterwards.
extern __device__ void user_func_warp(...);
extern __device__ void user_func_cta(...);
extern __device__ void user_func_ctapair(...);
extern __device__ void ck_worker(...);

__global__ __cluster_dims__(16,1,1) void VectraFlow_CGA_Wrapper(struct CSV *csv, ...) {
    // 0. Enable CTA Pair if needs
    if (threadIdx.x / 2048 >= 2) {
        asm volatile(
            "tcgen05.mma.cta_group::2.kind::f8f6f4 ...;"
            ::: "memory"
        );
    }

    // 1. Role Assignment
    bool is_ck = (threadIdx.x >= 0 && threadIdx.x < 32);
    bool is_tk_master = (
        (threadIdx.x / 32 >= 1 && threadIdx.x / 32 < 32 && threadIdx.x % 32 == 0) ||
        (threadIdx.x / 1024 >= 1 && threadIdx.x / 1024 < 4 && threadIdx.x % 1024 == 0) ||
        (threadIdx.x / 2048 >= 2 && threadIdx.x / 2048 < 8 && threadIdx.x % 2048 == 0)
    )
    int tk_base_idx;
    switch(threadIdx.x / 32) {
        // case 1~31:    tk_base_idx = threadIdx.x - threadIdx.x % 32;   break;
        // case 32~127:  tk_base_idx = threadIdx.x - threadIdx.x % 1024; break;
        // case 128~511: tk_base_idx = threadIdx.x - threadIdx.x % 2048; break;
    }
    
    // 2. Persistent Loop
    while (csv != NULL) {
        // --- Infra Pre Logic ---
        if (is_tk_master) {
            auto args_tuple = UnpackCSV<ExtType, FuncArgs...>(csv, tk_base_idx);
            Broadcast_Args(args_tuple, threadIdx.x);
        }

        switch(threadIdx.x / 32) {
            // case 1~31:    __syncwarp();      break;
            // case 32~127:  __syncthreads();   break;
            // case 128~511: __cta_pair_sync(); break;
        }

        // --- User Compute Logic ---
        if (!is_ck) {
            switch(threadIdx.x / 32) {
                // case 1~31:    std::apply(user_func_warp, args_tuple);    break;
                // case 32~127:  std::apply(user_func_cta, args_tuple);     break;
                // case 128~511: std::apply(user_func_ctapair, args_tuple); break;
            }
        }
        
        // --- Infra Post Logic ---
        switch(threadIdx.x / 32) {
            // case 1~31:    __syncwarp();      break;
            // case 32~127:  __syncthreads();   break;
            // case 128~511: __cta_pair_sync(); break;
        }
        if (is_tk_master) {
            csv = Mark_CSV_Done_And_Advance(csv);
        }

        // --- CK Logic ---
        // All of the conditional branchings ahead are orthogonal to this `if`.
        // Written *here* is just for avoiding a mess.
        if (is_ck) ck_worker(...);
    }
}