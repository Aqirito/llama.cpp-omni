#include "llama-moe-slot.h"

#include "ggml-backend.h"
#include "llama-impl.h"
#include "llama-model.h"
#include "llama-moe-sidecar.h"

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <unordered_map>
#include <vector>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

struct llama_moe_slot_runtime::impl {
    struct binding {
        ggml_tensor * tensor = nullptr;
        const llama_moe_sidecar_entry * entry = nullptr;
    };

    struct layer_state {
        bool enabled = false;
        std::vector<binding> bindings;
        std::vector<int32_t> slot_to_expert;
        std::vector<int32_t> expert_to_slot;
        std::vector<uint64_t> slot_age;
        std::vector<uint8_t> scratch;
        uint64_t age = 0;
        std::mutex mutex;
    };

    struct map_userdata {
        llama_moe_slot_runtime * runtime = nullptr;
        int layer = -1;
    };

    explicit impl(const llama_model & model) :
        model(model),
        n_expert((int32_t) model.hparams.n_expert),
        n_slots(model.moe_slot_bank_size()),
        layers(model.layers.size()),
        userdata(model.layers.size()) {
        for (size_t il = 0; il < model.layers.size(); ++il) {
            auto & state = layers[il];
            const auto & layer = model.layers[il];

            bind(state, layer.ffn_gate_up_exps);
            bind(state, layer.ffn_gate_exps);
            bind(state, layer.ffn_up_exps);
            bind(state, layer.ffn_down_exps);
            if (state.bindings.empty()) {
                continue;
            }
            if (!layer.ffn_down_exps ||
                (!layer.ffn_gate_up_exps && (!layer.ffn_gate_exps || !layer.ffn_up_exps))) {
                throw std::runtime_error(format("incomplete MoE slot bindings for layer %zu", il));
            }

            state.enabled = true;
            state.slot_to_expert.assign(n_slots, -1);
            state.expert_to_slot.assign(n_expert, -1);
            state.slot_age.assign(n_slots, 0);
            userdata[il] = { nullptr, (int) il };
        }
    }

    ~impl() {
        for (const auto & item : fds) {
#ifdef _WIN32
            _close(item.second);
#else
            close(item.second);
#endif
        }
    }

    void bind(layer_state & state, ggml_tensor * tensor) {
        if (!tensor) {
            return;
        }
        const auto * entry = model.moe_sidecar_entry(ggml_get_name(tensor));
        if (!entry) {
            throw std::runtime_error(format("missing sidecar entry for tensor '%s'", ggml_get_name(tensor)));
        }
        if (tensor->ne[2] != n_slots ||
            ggml_nbytes(tensor) != entry->bytes_per_expert * (size_t) n_slots) {
            throw std::runtime_error(format("invalid virtual slot tensor '%s'", ggml_get_name(tensor)));
        }
        state.bindings.push_back({ tensor, entry });
    }

    int fd_for(const std::string & path) {
        std::lock_guard<std::mutex> lock(fd_mutex);
        const auto found = fds.find(path);
        if (found != fds.end()) {
            return found->second;
        }
#ifdef _WIN32
        const int fd = _open(path.c_str(), _O_RDONLY | _O_BINARY);
#else
        const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
#endif
        if (fd < 0) {
            throw std::runtime_error(format("failed to open MoE sidecar file '%s': %s", path.c_str(), std::strerror(errno)));
        }
        fds.emplace(path, fd);
        return fd;
    }

    void read_exact(const llama_moe_sidecar_entry & entry, int32_t expert, void * output) {
        const size_t offset = entry.offset + (size_t) expert * entry.expert_stride;
        size_t done = 0;
        const int fd = fd_for(entry.path);
        while (done < entry.bytes_per_expert) {
#ifdef _WIN32
            std::lock_guard<std::mutex> lock(io_mutex);
            if (_lseeki64(fd, (int64_t) (offset + done), SEEK_SET) < 0) {
                throw std::runtime_error("failed to seek MoE sidecar");
            }
            const int result = _read(fd, (uint8_t *) output + done,
                                     (unsigned int) std::min<size_t>(entry.bytes_per_expert - done, INT_MAX));
#else
            const ssize_t result = pread(fd, (uint8_t *) output + done,
                                         entry.bytes_per_expert - done, (off_t) (offset + done));
#endif
            if (result < 0 && errno == EINTR) {
                continue;
            }
            if (result <= 0) {
                throw std::runtime_error(format(
                    "failed to read expert %d from MoE sidecar file '%s'",
                    expert, entry.path.c_str()));
            }
            done += (size_t) result;
        }
    }

    static const uint8_t * host_data(const ggml_tensor * tensor) {
        if (!tensor || !tensor->data || (tensor->buffer && !ggml_backend_buffer_is_host(tensor->buffer))) {
            return nullptr;
        }
        return (const uint8_t *) tensor->data;
    }

    static uint8_t * host_data(ggml_tensor * tensor) {
        return const_cast<uint8_t *>(host_data((const ggml_tensor *) tensor));
    }

    void read_i32_ids(const ggml_tensor * tensor, std::vector<int32_t> & ids) const {
        const int64_t n_ids = tensor->ne[0];
        const int64_t n_tokens = tensor->ne[1];
        const size_t row_bytes = (size_t) n_ids * sizeof(int32_t);
        ids.resize((size_t) (n_ids * n_tokens));
        if (const uint8_t * src = host_data(tensor)) {
            for (int64_t token = 0; token < n_tokens; ++token) {
                memcpy(ids.data() + token * n_ids, src + (size_t) token * tensor->nb[1], row_bytes);
            }
            return;
        }
        for (int64_t token = 0; token < n_tokens; ++token) {
            ggml_backend_tensor_get(
                tensor,
                ids.data() + token * n_ids,
                (size_t) token * tensor->nb[1],
                row_bytes);
        }
    }

    void write_i32_ids(ggml_tensor * tensor, const std::vector<int32_t> & ids) const {
        const int64_t n_ids = tensor->ne[0];
        const int64_t n_tokens = tensor->ne[1];
        const size_t row_bytes = (size_t) n_ids * sizeof(int32_t);
        if (ids.size() != (size_t) (n_ids * n_tokens)) {
            throw std::runtime_error("MoE slot id count does not match tensor shape");
        }
        if (uint8_t * dst = host_data(tensor)) {
            for (int64_t token = 0; token < n_tokens; ++token) {
                memcpy(dst + (size_t) token * tensor->nb[1], ids.data() + token * n_ids, row_bytes);
            }
            return;
        }
        for (int64_t token = 0; token < n_tokens; ++token) {
            ggml_backend_tensor_set(
                tensor,
                ids.data() + token * n_ids,
                (size_t) token * tensor->nb[1],
                row_bytes);
        }
    }

    void install(layer_state & state, int32_t expert, int32_t slot) {
        for (const auto & binding : state.bindings) {
            state.scratch.resize(binding.entry->bytes_per_expert);
            read_exact(*binding.entry, expert, state.scratch.data());
            ggml_backend_tensor_set(
                binding.tensor,
                state.scratch.data(),
                (size_t) slot * binding.entry->bytes_per_expert,
                binding.entry->bytes_per_expert);
        }
    }

    const llama_model & model;
    int32_t n_expert;
    int32_t n_slots;
    std::vector<layer_state> layers;
    std::vector<map_userdata> userdata;
    std::unordered_map<std::string, int> fds;
    std::mutex fd_mutex;
    std::mutex io_mutex;
};

void llama_moe_slot_runtime::map_custom(
        ggml_tensor * dst,
        const ggml_tensor * src,
        int ith,
        int nth,
        void * userdata) {
    GGML_UNUSED(nth);
    if (ith != 0) {
        return;
    }
    auto * data = static_cast<llama_moe_slot_runtime::impl::map_userdata *>(userdata);
    data->runtime->process(data->layer, src, dst);
}

llama_moe_slot_runtime::llama_moe_slot_runtime(const llama_model & model) :
    pimpl(std::make_unique<impl>(model)) {
    for (auto & item : pimpl->userdata) {
        item.runtime = this;
    }
}

llama_moe_slot_runtime::~llama_moe_slot_runtime() = default;

bool llama_moe_slot_runtime::uses_layer(int layer) const {
    return layer >= 0 && layer < (int) pimpl->layers.size() && pimpl->layers[layer].enabled;
}

ggml_tensor * llama_moe_slot_runtime::build_slot_ids_tensor(
        ggml_context * ctx,
        ggml_tensor * expert_ids,
        int layer) {
    if (!uses_layer(layer)) {
        return expert_ids;
    }
    return ggml_map_custom1(ctx, expert_ids, map_custom, 1, &pimpl->userdata[layer]);
}

void llama_moe_slot_runtime::process(
        int layer,
        const ggml_tensor * expert_ids,
        ggml_tensor * slot_ids) {
    if (!uses_layer(layer) ||
        expert_ids->type != GGML_TYPE_I32 ||
        slot_ids->type != GGML_TYPE_I32 ||
        expert_ids->ne[0] != slot_ids->ne[0] ||
        expert_ids->ne[1] != slot_ids->ne[1]) {
        throw std::runtime_error(format(
            "invalid MoE slot map tensors at layer %d type=%s/%s shape=%lldx%lld vs %lldx%lld",
            layer,
            ggml_type_name(expert_ids ? expert_ids->type : GGML_TYPE_COUNT),
            ggml_type_name(slot_ids ? slot_ids->type : GGML_TYPE_COUNT),
            expert_ids ? (long long) expert_ids->ne[0] : -1,
            expert_ids ? (long long) expert_ids->ne[1] : -1,
            slot_ids ? (long long) slot_ids->ne[0] : -1,
            slot_ids ? (long long) slot_ids->ne[1] : -1));
    }

    auto & state = pimpl->layers[layer];
    std::lock_guard<std::mutex> lock(state.mutex);
    std::vector<int32_t> experts;
    pimpl->read_i32_ids(expert_ids, experts);
    const size_t count = experts.size();
    std::vector<int32_t> slots(count);
    std::vector<uint8_t> requested(pimpl->n_expert, 0);

    for (size_t i = 0; i < count; ++i) {
        if (experts[i] < 0 || experts[i] >= pimpl->n_expert) {
            throw std::runtime_error("MoE expert id is out of range");
        }
        requested[experts[i]] = 1;
    }

    for (int32_t expert = 0; expert < pimpl->n_expert; ++expert) {
        if (!requested[expert] || state.expert_to_slot[expert] >= 0) {
            continue;
        }

        int32_t slot = -1;
        for (int32_t candidate = 0; candidate < pimpl->n_slots; ++candidate) {
            if (state.slot_to_expert[candidate] < 0) {
                slot = candidate;
                break;
            }
        }
        if (slot < 0) {
            uint64_t oldest = UINT64_MAX;
            for (int32_t candidate = 0; candidate < pimpl->n_slots; ++candidate) {
                const int32_t resident = state.slot_to_expert[candidate];
                if (!requested[resident] && state.slot_age[candidate] < oldest) {
                    oldest = state.slot_age[candidate];
                    slot = candidate;
                }
            }
        }
        if (slot < 0) {
            throw std::runtime_error(format(
                "layer %d requires more than %d unique experts in one graph; reduce ubatch or increase --moe-slot-bank",
                layer, pimpl->n_slots));
        }

        const int32_t evicted = state.slot_to_expert[slot];
        if (evicted >= 0) {
            state.expert_to_slot[evicted] = -1;
        }
        pimpl->install(state, expert, slot);
        state.slot_to_expert[slot] = expert;
        state.expert_to_slot[expert] = slot;
        state.slot_age[slot] = ++state.age;
    }

    for (size_t i = 0; i < count; ++i) {
        const int32_t slot = state.expert_to_slot[experts[i]];
        if (slot < 0) {
            throw std::runtime_error("MoE expert was not installed");
        }
        slots[i] = slot;
        state.slot_age[slot] = ++state.age;
    }
    pimpl->write_i32_ids(slot_ids, slots);
}
