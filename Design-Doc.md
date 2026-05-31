# VectraFlow 设计文档

- [VectraFlow 设计文档](#vectraflow-设计文档)
  - [1. Executive Summary](#1-executive-summary)
  - [2. Core Philosophy \& Invariants](#2-core-philosophy--invariants)
  - [3. System Architecture](#3-system-architecture)
  - [4. Data Protocols](#4-data-protocols)
    - [4.1 Macro Task Graph (MTG) - 任务描述协议](#41-macro-task-graph-mtg---任务描述协议)
      - [4.1.1 `MacroTaskGraph_Context`](#411-macrotaskgraph_context)
      - [4.1.2 `MacroTaskGraph_Node`](#412-macrotaskgraph_node)
      - [4.1.3 Host End Node (HEN)](#413-host-end-node-hen)
    - [4.2 Control Signal Vector (CSV) - 执行描述协议](#42-control-signal-vector-csv---执行描述协议)
      - [4.2.1 `CSV`](#421-csv)
      - [4.2.2 原子操作与内存序约束](#422-原子操作与内存序约束)
  - [5. Execution Engine](#5-execution-engine)
    - [5.1 Task Kernel (TK) - 计算执行单元](#51-task-kernel-tk---计算执行单元)
    - [5.2 Control Kernel (CK) - 调度控制单元](#52-control-kernel-ck---调度控制单元)
  - [6. Host-end Logic](#6-host-end-logic)
    - [6.1 MTG 节点的就地复用](#61-mtg-节点的就地复用)
    - [6.2 `mtg_ready_list`](#62-mtg_ready_list)
    - [6.3 `hen_linked_list`](#63-hen_linked_list)
    - [6.4 `host_message_buffer`](#64-host_message_buffer)
  - [7. Memory Management](#7-memory-management)
    - [7.1 显存分配原则](#71-显存分配原则)
    - [7.2 不定大小输出的处理方案](#72-不定大小输出的处理方案)
    - [7.3 张量显存池](#73-张量显存池)
    - [7.4 CSV Slab 分配器](#74-csv-slab-分配器)
  - [8. Concurrency \& Elasticity](#8-concurrency--elasticity)
    - [8.1 并行度模型](#81-并行度模型)
    - [8.2 资源弹性控制](#82-资源弹性控制)
  - [9. User Interface](#9-user-interface)
    - [9.1 TK Wrapper](#91-tk-wrapper)

---

## 1. Executive Summary

本设计文档旨在阐述一种全新的、面向训练与推理并重的 LLM Infra 框架。该框架的核心目标是同时支持大量异构模型或不同序列长度的并行负载和异形模型的研究实验负载，在保证灵活性的基础上使能效达到硬件极限。
传统基于批次（Batch）和静态计算图的范式难以满足异构负载的细粒度调度需求。本框架提出了一种无状态算子内核（Task Kernel）与解耦控制内核（Control Kernel）在 Device 端自洽运行的模式。Host 端仅负责宏观任务图（Macro Task Graph）的提交与监控，将微观调度权下放至 Device 端。通过引入控制信号向量（CSV）作为虚拟硬件指令，实现了任务依赖的动态解析与资源的极致利用。
本框架致力于同时满足**极致性能**、**可维护性**与**可扩展性**三个条件。

---

## 2. Core Philosophy & Invariants

1.  Decoupled Control & Compute:
    *   **Task Kernel (TK)** 专注于纯计算，绝对无状态，类似后端执行单元。通常，TK 对应于张量算子。
    *   **Control Kernel (CK)** 专注于调度、依赖解析与资源管理，类似解码前端。
    *   两者在 Device 端独立运行，通过 **Control Signal Vector (CSV)** 通信。

2.  Virtual Instruction Set - CSV:
    *   CSV 被视为“虚拟硬件指令”，封装了任务执行所需的全部上下文（类型、状态、IO 指针）。
    *   TK 按链表顺序执行 CSV，实现了任务流的流水线化。

3.  De-batching:
    *   摒弃传统的“批次”概念，以**宏观任务（Macro Task）**为核心抽象。
    *   宏观任务表现为一个有向无环图（DAG）的 **Macro Task Graph (MTG)**，任务内的各个 **MTG 节点**存在偏序关系；不同宏观任务之间正交，无依赖关系。
    *   支持同构或异构宏观任务的并行堆叠，以每个 MTG 节点描述的**子任务（Sub Task）**为最小调度粒度。

4.  Memory Determinism:
    *   TK 每个执行循环前，CSV 必须完整列举此次执行的所有可用显存空间。TK 运行期间禁止动态显存申请。
    *   通过预计算算子或算子拆分策略，确保所有内存需求在执行前已知，保障实时性与稳定性。

5.  Topology Invariants:
    *   每个 CK 实例固定服务特定的若干个 TK 实例，每个 TK 实例只被一个 CK 实例管理，构成局部性绑定。
    *   基于上述绑定，CK 与 TK 之间的 CSV 链表天然是 SPSC 的。

---

## 3. System Architecture

系统分为 Host 端与 Device 端，交互边界清晰：
*   **Host 端:** 负责生命周期管理（创建/销毁 Kernel）、提交宏观任务图（Macro Task Graph）、接收 Trace 日志与异常报告、监控性能并动态调整 Device 端资源配比。此外，存在 Host 端子任务（Host End Node）。
*   **Device 端:** 包含若干 Task Kernel 实例与 Control Kernel 实例。CK 管理 TK，TK 执行计算。

---

## 4. Data Protocols

### 4.1 Macro Task Graph (MTG) - 任务描述协议

#### 4.1.1 `MacroTaskGraph_Context`
*   描述一个宏观任务的完整计算图。
*   实际实现中，在 Device 端按照 Sliding Window 方式，用 Ring Buffer 保存片段。本身的元信息包括任务 ID 和各类标志位、`mtg_ready_list`、以及 MTG Ring Buffer 的 Head 和 Tail 指针。每个节点在 Ring Buffer 中 Packed 存储。对于 MTG 结束时的最后一个节点，附加一个占位节点作为其后继节点，表示 MTG 已结束。
*   Host 轮询 Ring Buffer，回收 `releasable` 节点、自行保存其中的 Log 信息，同时补充新节点。补充新节点时，新节点必定是部分现有节点的后继节点，需要更新这些现有节点的 `successors` 字段，将初始化的 null 值更新为真实值。
*   MTG Ring Buffer 使用 MTG 实例锁来解决 Host 与 Device 的竞态。这个竞态不会激烈，因为 Host 对 MTG Ring Buffer 是轮询的。也因此避免节点锁带来的开销和复杂性。

#### 4.1.2 `MacroTaskGraph_Node`
*   具有固定结构规范但 Packed 的子任务描述。
*   内存结构：
    *   `node_type`: 节点类型，该节点所创建的 CSV 实例会继承这个类型。
    *   `node_state`: 节点状态，包括 `holding`、`executing`、`done`、`releasable`。当一个节点创建了 CSV 时进入 `executing` 状态，不论是否成功推送到某个 TK、也不论 TK 是否执行到它。当一个节点完成时进入 `done` 状态，本身的空间复用为 Log，记录下实际执行 CSV 的 TK 信息以及执行过程中的其他情况。当一个 `done` 节点不再被依赖时进入 `releasable` 状态，指向的 CSV 会被释放。
    *   `dynamic_in_degree`: 动态入度，初始为前置节点数，减至 0 即依赖就绪。初始值可以由前驱节点的 CSV 中特定反馈字段的值决定。
    *   `successors`: 后继节点数量和指针数组。
    *   `csv_ref`: 指向当前执行该节点的 CSV 实例。
    *   `InputRoutingTable`: 输入数据块来源（来自哪些前置节点的哪些 CSV 字段）。按照数量 + 描述符 `InputDescriptor` 的形式，描述符字面顺序即布局顺序。
    *   `OutputAllocationTable`: 输出数据块需求（是否需要分配新空间）。类似地采用数量 + `OutputDescriptor` 的形式，描述符字面顺序即布局顺序。
*   特别地，约定在描述符的排列中，必须按照 `InputSourceType` 或 `OutputAllocStrategy` 枚举值的顺序排列。
*   `InputDescriptor`: 对齐到 64 bits。
```
// 输入来源类型枚举
enum class InputSourceType : uint8_t {
    FROM_PREDECESSOR = 0, // 来自前驱节点的 CSV 槽位
    GLOBAL_WEIGHT    = 1, // 来自全局 HBM 权重/常量 (如 LLM 的 W_q, W_k)
    SCALAR_PARAM     = 2  // 直接内嵌在描述符中的标量参数 (如 alpha, beta)
};

// 单个输入描述符
struct InputDescriptor {
    InputSourceType src_type;

    union {
        // 分支 1: 来自前驱节点
        struct {
            uint32_t mtg_ring_buffer_offset; // 前驱 MTG 节点
            uint8_t  src_slot_idx;           // 取前驱 CSV 的第几个槽位
            uint8_t  size_slot_idx;          // 以前驱 CSV 的第几个槽位中的标量值作为数据块尺寸
        } pred_dep;

        // 分支 2: 全局权重/常量
        struct {
            uint8_t  size_bytes;    // 数据大小
            uint16_t global_addr_1; // 全局地址索引第 1 部分
            uint32_t global_addr_2; // 全局地址索引第 2 部分
        } global_ref;

        // 分支 3: 标量参数
        struct {
            char value[VALUE_SIZE]; // 直接存储标量值
        } scalar_val;
    } payload;
};
```
*   `OutputDescriptor`: 对齐到 64 bits。
```
// 输出分配策略枚举
enum class OutputAllocStrategy : uint8_t {
    STATIC_ALLOC  = 0, // 静态大小，直接从 HBM Pool 分配
    DYNAMIC_ALLOC = 1, // 动态大小，依赖 Pre-calc 节点的输出
    INPLACE_REUSE = 2, // In-place 操作，复用当前 CSV 的某个 input_ptr
    INPUT_REALLOC = 3  // 复用当前 CSV 的某个 input_ptr，但进行 realloc
};

// 单个输出描述符
struct OutputDescriptor {
    OutputAllocStrategy strategy;

    union {
        // 分支 1: 静态分配
        struct {
            uint32_t size_bytes;
        } static_alloc;

        // 分支 2: 动态分配 (Operator Splitting / Pre-calc 机制)
        struct {
            uint32_t mtg_ring_buffer_offset; // 提供 Size 的前驱节点
            uint8_t  size_slot_idx;          // 从该前驱 CSV 的哪个槽位读取 Size
            uint8_t  multiplier;             // Final Size = precalc_val * multiplier
        } dynamic_alloc;

        // 分支 3: In-place 复用
        struct {
            uint8_t reuse_input_slot_idx; // 复用当前 CSV 的哪个 input 槽位
        } inplace;

        // 分支 4: 对输入数据块进行 realloc
        struct {
            uint8_t reuse_input_slot_idx; // 复用当前 CSV 的哪个 input 槽位
            uint8_t new_size;             // realloc 后的尺寸
        } pred_dep;
    } payload;
};
```

#### 4.1.3 Host End Node (HEN)
*   描述由 Host 端 CPU 执行的子任务。
*   部分工具算子可以采用 HEN 的形式卸载回 Host，乃至将一些 CPU 逻辑算子化。
*   HEN 在 MTG 的节点描述符中，使用字面量形式的 CSV 替代常规 `csv_ref`、`InputRoutingTable` 和 `OutputAllocationTable` 的空间。CK 将其解析为普通 CSV，复用现有逻辑。
*   I/O 描述符信息由 Host 端另存。

### 4.2 Control Signal Vector (CSV) - 执行描述协议

#### 4.2.1 `CSV`
短生命周期、高频访问对象，构成单向链表。
*   固定通用字段：
    *   `task_kernel_type`: 决定算子类型及扩展字段结构。
    *   `input_ptr` / `input_size`: 只读输入数据块。
    *   `output_ptr` / `output_size`: 可读写输出数据块。
    *   `source_sub_task`: 指向对应的 `MacroTaskGraph_Node`。
    *   `next_csv`: 指向下一个 CSV 实例。
    *   `state`: 集成在 `next_csv` 低位，枚举值 `{waiting, running, done, error}`。整个 `next_csv` 的访问修改必须采用原子操作。
*   可变扩展字段: 由 `task_kernel_type` 决定，含额外 IO 指针、反馈字段等。

#### 4.2.2 原子操作与内存序约束
*   依赖更新: CK 更新 `dynamic_in_degree` 时需保证原子性。
*   链表插入: 向 TK 的 CSV 链表尾部追加新 CSV 时，必须使用 CAS (Compare-And-Swap) 操作更新尾指针，防止追加过程中 TK 读取到旧 null 值退出导致泄露。
*   状态标志: CSV 的 `state` 字段由 TK 更新，需符合内存序要求，确保 CK 看到 `done` 状态时数据写入已全局可见。

---

## 5. Execution Engine

### 5.1 Task Kernel (TK) - 计算执行单元
*   承载物：张量算子。一个 TK 对应于一个完整的张量算子，而非单个线程。由于张量算子处理的对象尺寸，一个 TK 天然占据一个 Warp 甚至 Thread Block。
*   并行模型: TK 实例数量受限于 GPU SM 数量，代表子任务的最大并行度。
*   无内部状态：所有执行上下文通过 CSV 传入。
*   基本执行逻辑:
    1.  初始化时接收首个 CSV 地址。
    2.  读取 CSV 中的 IO 指针、标志量。
    3.  执行计算。
    4.  更新 CSV 状态标志（如 `done`）。
    5.  读取 `next_csv` 指针，跳转至下一个 CSV。
    6.  若 `next_csv` 为 null，停止循环、Kernel 退出，释放硬件资源。
*   约束: 不可创建/销毁 CSV，不可修改 CSV 中除特定反馈字段外的内容，不可动态申请显存。

### 5.2 Control Kernel (CK) - 调度控制单元
*   并行模型: 单线程串行逻辑。一个 Warp 中包含 32 个 CK 实例，通过 SIMT 并行，彼此平行，各自负责特定的若干个 TK。
*   工作区内容:
    *   管理的 TK 实例控制上下文（属性、CSV 链表头尾指针、性能计数）。
    *   涉及的宏观任务图（MTG）实例。
    *   标志位组、新建 CSV 临时挂载缓冲区。
    *   `mtg_ready_list`、`hen_linked_list`、`host_message_buffer`。
*   基本执行逻辑:
    1.  遍历所管理的每个 TK。
    2.  从头顺序遍历该 TK 的 CSV 链表。
    3.  遇到 `done` CSV:
        *   将该 CSV 从链表中弹出。
        *   通过 `source_sub_task` 指针访问 MTG 节点。
        *   在 MTG 中原子递减后继节点的 `dynamic_in_degree`。若后继节点依赖归零、且这个后继节点它的所有后继节点已在 MTG Ring Buffer 中（它的后继节点数组中无 null 值），触发新 CSV 创建。
        *   若该 MTG 节点的所有后继节点均已创建 CSV，该节点即进入 `releasable` 状态。
    4.  遇到 `running` 节点: 结束当前 TK 链表的遍历（后续任务尚未完成，无需检查）。
    5.  新建 CSV 可能如 3 所示满足条件触发，或由 `mtg_ready_list` 非空触发。需要新建 CSV 时：
       *   根据 MTG 节点中的信息，获取节点属性，确认对前置节点的数据依赖和显存分配需求，执行显存分配。
       *   向 CSV Slab 分配器申请正确大小的 CSV，并填充内容。
       *   选取一个 TK 实例，将新建 CSV 尝试 CAS 插入其链表尾部。如果失败，挂载到当前 CK 的新建 CSV 临时挂载缓冲区，在下次循环再次尝试推送到 TK。
    6.  生成 Trace 日志，报告异常。

---

## 6. Host-end Logic

### 6.1 MTG 节点的就地复用
当一个 MTG 节点进入 `done` 状态时，其原本用于存放 `dynamic_in_degree`、`InputRoutingTable`、`OutputAllocationTable` 的空间，原地覆写为 Trace Log，记录执行 TK ID、CK 轮次序号（用于估算耗时）、异常码等。

### 6.2 `mtg_ready_list`
当 Host 发现 MTG 未结束，但 Ring Buffer 中无 `executing` 节点，说明 MTG 因为新节点补充不及时导致 CK 停止对它的调度。此时补充的新节点需要在 `mtg_ready_list` 中列出节点指针，使得 CK 可以知道从哪里开始恢复调度。

### 6.3 `hen_linked_list`
HEN 下，CK 将 Host 视为一个特殊 TK 实例。当 CK 发现一个 HEN 的依赖已经就绪，正常路径下 CK 生成 CSV 并推送给 TK，此时 CK 将这个 HEN 的 MTG Ring Buffer 偏移量插入 `hen_linked_list`。由于 HEN 的 CSV 直接作为字面量保存在节点中，因此这构成了充分必要的信息。

### 6.4 `host_message_buffer`
CK 和 Host 通过 `host_message_buffer` 中的消息包来进行控制面交互，遵循 `io_uring` 协议。

---

## 7. Memory Management

### 7.1 显存分配原则
*   **静态预分配:** TK 执行循环前，CSV 必须完整列举所有可用显存空间。
*   **禁止动态申请:** TK 内部严禁调用 `malloc` 或类似显存分配接口，以避免序列化开销与碎片化。

### 7.2 不定大小输出的处理方案
针对无法预先确定输出大小的算子，采用以下两种策略之一：
1.  Tool Operator Pre-calc:
    *   设计专用算子，仅计算输出尺寸，不执行实际计算。
    *   该算子同样通过 CSV 调度，先于实际计算算子执行。
    *   后续算子根据预计算结果分配显存。
    *   *注:* Control Kernel 可硬编码部分常用算子的尺寸推演逻辑。
2.  Operator Splitting:
    *   将算子拆分为 `Phase_A` (计算逻辑，输出尺寸信息) 和 `Phase_B` (需要动态空间的计算)。
    *   `Phase_B` 所需空间可由 `Phase_A` 输出唯一确定。
    *   流程回归到方案一，即通过 `Phase_A` 的 CSV 产出尺寸信息，指导 `Phase_B` 的 CSV 内存分配。

### 7.3 张量显存池
*   使用张量显存池来管理 TK 所使用的大型张量。
*   CK 是张量显存池逻辑的实际执行者，因为所有的显存分配和释放都是由 CK 完成的。

### 7.4 CSV Slab 分配器
*   负载特征：同一个 SMEM 域内 TK 数量有限，单 TK 链表长度极短（~3），活跃 CSV 总数很少；CSV 是紧凑的、以指针和少量标志位为主的结构体，单个 CSV 尺寸很小；因此，SMEM 域内的 CSV 总尺寸非常有限。不同节点类型的 CSV 具有不同的扩展字段结构，相同类型的 CSV 也可以具有可变长度的扩展字段（如数据块指针数组），每个 CSV 之间尺寸不一。
*   CSV Slab Pool 构成：SMEM 为主，分桶策略，划分为几个 Class 栈式无锁分配。极端情况下（异常的延迟或阻塞），当 SMEM 池耗尽，溢出到 HBM 全局后备池。
*   回收与复用优化：可释放的 CSV 交还 CSV Slab Pool 回收，下次分配时优先分配给上次的 CK。
*   奇偶对齐优化：CK 申请新 CSV 时传入 `last_csv_ptr`，在分配时尽量让新 CSV 的地址与前驱 CSV 奇偶对齐。这有助于 CK 在遍历链表时，预取下一个 CSV。

---

## 8. Concurrency & Elasticity

### 8.1 并行度模型
*   **TK 并行**: TK 实例总数受硬件 SM 数量限制 。每个 TK 实例独立执行。
*   **CK 并行**: 一个 Warp (32 Threads) 运行 32 个 CK 实例，每个 CK 独立管理一组 TK。利用 SIMT 特性，实现控制逻辑的高吞吐并行。
*   **宏观任务并行**: 宏观任务层面，多个同构或异构 Macro Task 同时存在，各自拥有独立的 MTG 实例，互不干扰。
*   **Host-Device 并行**：Host 回收已完成子任务，填充新的子任务，解析复杂控制流，执行 Host 端子任务，进行性能监控调优；Device 对已有任务自循环处理，与 Host 逻辑的执行重叠。

### 8.2 资源弹性控制
*   Host 可通过监控性能数据，向 CK 发送信号。
*   缩容: 通知 CK 停止向特定 TK 追加 CSV，待其自然耗尽退出。
*   扩容: 创建新的 TK 实例，并通知 CK 开始向其调度任务。
*   此机制实现了手动但精细的硬件资源控制，可以精准控制硬件负载率。

---

## 9. User Interface

### 9.1 TK Wrapper