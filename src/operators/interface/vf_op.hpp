// src/operators/interface/vf_op.hpp
// 算子注册表项：包含编译期和运行期所需信息
struct OpRegistration {
    std::string name;
    TKType tk_type; // 分配的唯一 ID

    // [编译期使用] 形状推导函数，用于 AOT 生成 OutputDescriptor 的动态分配逻辑
    std::function<Shape(const std::vector<Shape>&)> infer_shape; 
    
    // [运行期使用] 算子本体的函数指针，TK Executor 会根据 tk_type 调用
    void (*compute_func)(CSV* csv); 
};
