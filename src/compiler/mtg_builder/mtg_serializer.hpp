// src/compiler/mtg_builder/mtg_serializer.hpp
class MTGSerializer {
public:
    // 将优化后的 IR 序列化为紧凑的二进制流
    // 包含：节点数量、各节点 Packed 后的内容（对齐 64 bits）
    std::vector<uint8_t> Serialize(const VFGraphIR& ir);
};

// 产出的二进制流结构示意：
// [MTG_Meta] -> [Node_0_Packed (type, in_deg, succ_cnt, succ_offsets, IO_Desc)] -> [Node_1_Packed] ...
