# Macro Task Graph Structure

## 1. Overview

编译器后端生成 Blueprint，Host 端在运行时充当 Dynamic Linker，将 Blueprint 实例化为 Ring Buffer 中的物理节点。
MTG 节点在 Ring Buffer 中具有 Packed（紧凑定长）特性。
Blueprint 应该紧凑且支持 SIMD 向量化解析。

---

## 2. Blueprint

### 2.1 Blueprint Header
包含元数据，用于 Host 端快速校验和加载。
*   `magic_number`: 标识文件格式。
*   `version`: 协议版本。
*   `superblock_count`: 宏观任务中“同构超块”（如单层 Transformer）的数量。
*   `symbol_table_offset` & `relocation_table_offset`: 指向后续段的偏移量。

### 2.2 Node Templates
这是 MTG 节点的“模具”。其内存布局与 Device 端的 `MacroTaskGraph_Node` 严格对齐，但关键区别在于引用字段被符号化：
*   `node_type`, `max_in_degree`, `max_successors`: **定长预分配**。
*   `successors` 数组: **目标节点的 Symbol ID**。当此字段为运行时该节点的 CSV 反馈字段决定的时候，
*   `InputRoutingTable` & `OutputAllocationTable`: 其中的 `mtg_ring_buffer_offset` 字段同样存储 **Symbol ID**。
*   `dynamic_in_degree` 初始值: 编译器根据静态图的最大入度计算得出（例如 Expert 节点 = 1个静态控制依赖 + 1个最大 Routing 依赖 = 2）。

### 2.3 Relocation Table
指导 Dynamic Linker 如何将 Symbol ID 替换为 Ring Buffer 中的真实物理 Index。
*   结构：`[Template_Index, Field_Offset, Target_Symbol_ID]`
*   作用：当 Host 实例化一个 Template 时，遍历此表，找到对应的字段，查表获取 `Target_Symbol_ID` 对应的真实 Ring Buffer Index，并填入。

---

## 3. Dynamic Linker

### 3.1 Data Structure

*   Symbol Map：Host 端维护的哈希表：`Symbol_Map[Symbol_ID] -> Ring_Buffer_Physical_Index`。

### 3.2 Injection Pipeline
假设 Host 准备将第 $K$ 层 Transformer 推入 Ring Buffer：

1.  **空间预留与 Index 分配**：
    *   Host 检查 Ring Buffer 的 Tail 指针，确保有足够的连续空间容纳该层的所有 Node Templates。
    *   为每个 Template 分配一个真实的 `Physical_Index` (例如 Tail, Tail+1, ...)。
2.  **Symbol Registration**：
    *   Host 遍历当前层的 Templates，提取其自身的 Symbol ID（如 `SYM_ATTN_LAYER_K`），并将其与刚分配的 `Physical_Index` 绑定，写入 `Symbol_Map`。
3.  **Copy & Relocate**：
    *   Host 将 Template 的原始字节拷贝到 Ring Buffer 的 `Physical_Index` 位置。
    *   Host 遍历 **Relocation Table** 中属于当前 Template 的条目。
    *   对于每个条目，Host 从 `Symbol_Map` 中查出 `Target_Symbol_ID` 对应的真实 `Physical_Index`。
    *   Host 将该 `Physical_Index` 写入 Ring Buffer 中节点的对应字段（如 `successors` 数组或 `InputDescriptor.pred_dep.mtg_ring_buffer_offset`）。
    *   *特例处理*：如果 `Target_Symbol_ID` 指向的是**上一层**的节点（跨 Superblock 依赖），Host 直接从 `Symbol_Map` 中读取上一层节点遗留的物理 Index 进行回填。
4.  **Atomic Commit**：
    *   重定位完成后，Host 使用 Memory Barrier 确保数据对 Device 可见。
    *   Host 原子更新 Ring Buffer 的 Tail 指针，正式将该 Layer 的 MTG 节点暴露给 Device 端的 CK。

