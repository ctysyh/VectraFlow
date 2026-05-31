// src/host/mtg_manager/mtg_feeder.cpp
void MTGFeeder::FeedNewNodes(MacroTaskGraph_Context* ctx, const std::vector<NodePacked>& new_nodes) {
    // 1. 获取 MTG 实例锁 (轻量级，Host 轮询时占用极短)
    ctx->Lock();
    
    // 2. 将新节点 Packed 写入 Ring Buffer Tail
    for (auto& node : new_nodes) {
        WriteToRingBuffer(ctx->tail, node);
        
        // 3. 关键：更新前驱节点的 successors 指针数组 (将 null 更新为真实 offset)
        // 此操作必须是原子的，确保 CK 在遍历 successors 时不会读到半更新状态
        for (auto pred_offset : node.predecessors) {
            auto* pred_node = GetNodeAtOffset(pred_offset);
            // 找到前驱节点 successors 数组中对应的 null 位置，原子写入当前 offset
            AtomicUpdateSuccessor(pred_node, ctx->tail); 
        }
        
        // 4. 如果导致 CK 停摆，需推入 mtg_ready_list
        if (ctx->no_executing_nodes) {
            ctx->mtg_ready_list.push(ctx->tail);
        }
        ctx->tail++;
    }
    ctx->Unlock();
}
