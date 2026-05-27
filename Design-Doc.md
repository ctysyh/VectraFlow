# VectraFlow 设计文档

## 1. Executive Summary

本设计文档旨在阐述一种全新的、面向训练与推理并重的 LLM Infra 框架。该框架的核心目标是同时支持大量异构模型或不同序列长度的并行负载和异形模型的研究实验负载。
传统基于批次（Batch）和静态计算图的范式难以满足异构负载的细粒度调度需求。本框架提出了一种无状态算子内核（Task Kernel）与解耦控制内核（Control Kernel）在 Device 端自洽运行的模式。Host 端仅负责宏观任务图的提交与监控，将微观调度权下放至 Device 端。通过引入控制信号向量（CSV）作为虚拟硬件指令，实现了任务依赖的动态解析与资源的极致利用。
本框架致力于同时满足**极致性能**、**可维护性**与**可扩展性**三个条件。

---

## 2. Core Philosophy

1.  Decoupled Control & Compute:
    *   **Task Kernel (TK)** 专注于纯计算，绝对无状态，类似后端执行单元。通常，TK 对应于张量算子。
    *   **Control Kernel (CK)** 专注于调度、依赖解析与资源管理，类似解码前端。
    *   两者在 Device 端独立运行，通过共享内存结构（CSV）通信，减少 Host-Device 同步开销。

2.  Virtual Instruction Set - CSV:
    *   CSV 被视为“虚拟硬件指令”，封装了任务执行所需的全部上下文（类型、状态、IO 指针）。
    *   TK 按链表顺序执行 CSV，实现了任务流的流水线化。

3.  De-batching:
    *   摒弃传统的“批次”概念，以**宏观任务（Macro Task）**为基本调度单元。
    *   宏观任务表现为一个有向无环图（DAG），任务间存在偏序关系；不同宏观任务之间正交，无依赖关系。
    *   支持同构或异构宏观任务的并行堆叠，以每个 **Macro Task Graph (MTG) 节点**即子任务（Sub Task）为最小调度粒度。

4.  Memory Determinism:
    *   TK 运行期间禁止动态显存申请。
    *   通过预计算算子或算子拆分策略，确保所有内存需求在执行前已知，保障实时性与稳定性。

---

## 3. System Architecture

### 3.1 总体拓扑
系统分为 Host 端与 Device 端，交互边界清晰：
*   **Host 端:** 负责生命周期管理（创建/销毁 Kernel）、提交宏观任务图（Macro Task Graph）、接收 Trace 日志与异常报告、监控性能并动态调整 Device 端资源配比。
*   **Device 端:** 包含若干 Task Kernel 实例与 Control Kernel 实例。CK 管理 TK，TK 执行计算。

### 3.2 核心组件定义

#### 3.2.1 数据结构定义
1. Macro Task Graph - MTG
*   **`MacroTaskGraph_Context`**: 任务 ID，节点数组指针。
*   **`MacroTaskGraph_Node`**: 
    *   `csv_ref`: 指向当前执行该节点的 CSV 实例。
    *   `dynamic_in_degree`: 动态入度，初始为前置节点数，减至 0 可执行。
    *   `successors`: 后继节点数组。
    *   `IO_Descriptors`: 输入数据块来源（来自哪些前置节点的哪些 CSV 字段）、输出数据块需求（是否需要分配新空间）。

2. Control Signal Vector - CSV
*   **`CSV`**: 短生命周期、高频访问对象，构成单向链表。
    *   `task_kernel_type`: 决定算子类型及扩展字段结构。
    *   `input_ptr` / `input_size`: 只读输入数据块。
    *   `output_ptr` / `output_size`: 可读写输出数据块。
    *   `source_sub_task`: 指向对应的 `MacroTaskGraph_Node`。
    *   `next_csv`: 指向下一个 CSV 实例。
    *   `state`: 集成在 `next_csv` 低位，枚举值 `{waiting, running, done, error}`。
*   可变扩展字段: 由 `task_kernel_type` 决定，含额外 IO 指针、反馈字段等。

#### 3.2.2 Task Kernel (TK) - 计算执行单元
*   资源映射: 由于张量算子处理的对象尺寸，一个 TK 天然占据一个 Warp 甚至 Thread Block。TK 实例数量受限于 GPU SM 数量，代表子任务的最大并行度。
*   无内部状态：所有执行上下文通过 CSV 传入。
*   基本执行逻辑:
    1.  初始化时接收首个 CSV 地址。
    2.  读取 CSV 中的 IO 指针、标志量。
    3.  执行计算。
    4.  更新 CSV 状态标志（如 `done`）。
    5.  读取 `next_csv` 指针，跳转至下一个 CSV。
    6.  若 `next_csv` 为 null，停止循环、Kernel 退出，释放硬件资源。
*   约束: 不可创建/销毁 CSV，不可修改 CSV 中除特定反馈字段外的内容，不可动态申请显存。

#### 3.2.3 Control Kernel (CK) - 调度控制单元
*   并发模型: 单线程串行逻辑。一个 Warp 中包含 32 个 CK 实例，通过 SIMT 并行，彼此平行，各自负责特定的若干个 TK。
*   工作区内容:
    *   管理的 TK 实例控制上下文（属性、CSV 链表头尾指针、性能计数）。
    *   涉及的宏观任务图（MTG）实例。
    *   标志位组、Trace Log 缓冲区、新建 CSV 临时挂载缓冲区。
*   基本执行逻辑:
    1.  遍历所管理的每个 TK。
    2.  从头顺序遍历该 TK 的 CSV 链表。
    3.  遇到 `done` CSV:
        *   将该 CSV 从链表中弹出。
        *   通过 `source_sub_task` 指针访问 MTG 节点。
        *   在 MTG 中原子递减后继节点的 `dynamic_in_degree`。若后继节点依赖归零，触发新 CSV 创建。
        *   若该 MTG 节点的所有后继节点均已创建 CSV，释放该节点的相关资源。
    4.  遇到 `running` 节点: 结束当前 TK 链表的遍历（后续任务尚未完成，无需检查）。
    5.  需要新建 CSV 时：
       *   根据 MTG 节点中的信息，获取节点属性，确认对前置节点的数据依赖和显存分配需求，执行显存分配。
       *   向 CSV Slab 分配器申请正确大小的 CSV，并填充内容。
       *   选取一个 TK 实例，将新建 CSV 尝试 CAS 插入其链表尾部。如果失败，挂载到当前 CK 的新建 CSV 临时挂载缓冲区，在下次循环再次尝试推送到 TK。
    6.  生成 Trace 日志，报告异常。

#### 3.2.4 CSV Slab 分配器
*   负载特征：同一个 SMEM 域内 TK 数量有限，单 TK 链表长度极短（~3），活跃 CSV 总数很少；CSV 是紧凑的、以指针和少量标志位为主的结构体，单个 CSV 尺寸很小；不同节点类型的 CSV 具有不同的扩展字段结构，相同类型的 CSV 也可以具有可变长度的扩展字段（如数据块指针数组），每个 CSV 之间尺寸不一。
*   CSV Slab Pool 构成：SMEM 为主，分桶策略，划分为几个 Class 栈式无锁分配。极端情况下，当 SMEM 池耗尽，溢出到 HBM 全局后备池。
*   回收与复用优化：可释放的 CSV 交还 CSV Slab Pool 回收，下次分配时优先分配给上次的 CK。
*   对齐优化：CK 申请新 CSV 时传入 `last_csv_ptr`，在分配时尽量让新 CSV 的地址与前驱 CSV 奇偶对齐。这有助于 CK 在遍历链表时，预取下一个 CSV。

---

## 4. Memory Management

### 4.1 显存分配原则
*   **静态预分配:** TK 执行循环前，CSV 必须完整列举所有可用显存空间。
*   **禁止动态申请:** TK 内部严禁调用 `malloc` 或类似显存分配接口，以避免序列化开销与碎片化。

### 4.2 可变大小输出处理方案
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

---

## 5. Concurrency & Scheduling

### 5.1 并行度模型
*   **TK 并行**: TK 实例总数受硬件 SM 数量限制 。每个 TK 实例独立执行。
*   **CK 并行**: 一个 Warp (32 Threads) 运行 32 个 CK 实例，每个 CK 独立管理一组 TK。利用 SIMT 特性，实现控制逻辑的高吞吐并行。
*   **宏观任务并行**: 宏观任务层面，多个同构或异构 Macro Task 同时存在，各自拥有独立的 MTG 实例，互不干扰。

### 5.2 依赖解析与原子性
*   依赖更新: CK 更新 `dynamic_in_degree` 时需保证原子性。
*   链表插入: 向 TK 的 CSV 链表尾部追加新 CSV 时，必须使用 CAS (Compare-And-Swap) 操作更新尾指针，防止追加过程中 TK 读取到旧 null 值退出导致泄露。
*   状态标志: CSV 的 `state` 字段由 TK 更新，需符合内存序要求，确保 CK 看到 `done` 状态时数据写入已全局可见。

### 5.3 资源弹性控制
*   Host 可通过监控性能数据，向 CK 发送信号。
*   缩容: 通知 CK 停止向特定 TK 追加 CSV，待其自然耗尽退出。
*   扩容: 创建新的 TK 实例，并通知 CK 开始向其调度任务。
*   此机制实现了手动但精细的硬件资源控制，可以精准控制硬件负载率。

---

## 6. Observability & Debuggability

### 6.1 Trace 与日志
*   本地缓冲: CK 在工作区维护 Trace Log 缓冲区，记录任务调度记录。
*   DMA 读取: Host 主动定时 DMA 读取并释放 Trace Log，收集调度记录的同时统计性能数据，监测异常耗时。
*   异常报告: 遇到不可恢复错误（如显存越界、非法指令），CK 立即标记 CSV 状态为 `error` 并上报 Host，Host 决定是终止任务还是尝试恢复。

### 6.2 Debuggability
*   MTG 快照: Host 可随时 DMA 读取 MTG 当前状态快照，用于死锁检测。
*   CSV 链查看: 从 Trace Log 中还原特定 TK 的历史 CSV 链表长度及状态分布，用于性能瓶颈分析。
