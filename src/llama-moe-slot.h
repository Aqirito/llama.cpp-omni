#pragma once

#include "ggml.h"

#include <memory>

struct llama_model;

class llama_moe_slot_runtime {
public:
    explicit llama_moe_slot_runtime(const llama_model & model);
    ~llama_moe_slot_runtime();

    bool uses_layer(int layer) const;
    ggml_tensor * build_slot_ids_tensor(
        ggml_context * ctx,
        ggml_tensor * expert_ids,
        int layer);
    void process(int layer, const ggml_tensor * expert_ids, ggml_tensor * slot_ids);

private:
    static void map_custom(
        ggml_tensor * dst,
        const ggml_tensor * src,
        int ith,
        int nth,
        void * userdata);

    struct impl;
    std::unique_ptr<impl> pimpl;
};
