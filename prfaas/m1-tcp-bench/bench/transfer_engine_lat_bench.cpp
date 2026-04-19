// Copyright 2026 PrfaaS-on-Mooncake contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Latency-aware Transfer Engine bench, focused on what M1 needs:
//   - TCP transport only (PrfaaS cross-DC hop is commodity Ethernet).
//   - DRAM only (cross-DC hop is DRAM<->DRAM by design).
//   - Per-batch wall-clock latency tracked per worker thread.
//   - Aggregated P50/P95/P99 reported on a single line for easy parsing:
//       LAT_STATS samples=NNN p50_us=NN.N p95_us=NN.N p99_us=NN.N \
//                 mean_us=NN.N max_us=NN.N
//
// We deliberately keep this binary minimal — it shares the *engine* with the
// upstream `transfer_engine_bench` (the same TCP transport, the same env
// vars: MC_SLICE_SIZE, MC_TCP_ENABLE_CONNECTION_POOL, MC_PATH_ROUNDROBIN,
// etc.) but strips out GPU/HIP/Ascend/TENT paths so the source stays small
// enough to read in one sitting.

#include <gflags/gflags.h>
#include <glog/logging.h>
#include <numa.h>
#include <signal.h>
#include <sys/time.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <memory>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>

#include "common.h"
#include "memory_location.h"
#include "transfer_engine.h"
#include "transfer_metadata.h"
#include "transport/transport.h"

using mooncake::TransferEngine;
using mooncake::TransferRequest;
using mooncake::TransferStatus;
using mooncake::TransferStatusEnum;
using mooncake::SegmentID;
using mooncake::Status;

DEFINE_string(local_server_name, mooncake::getHostname(),
              "Local server name. Defaults to hostname.");
DEFINE_string(metadata_server, "P2PHANDSHAKE",
              "Metadata server (defaults to in-band P2P handshake).");
DEFINE_string(mode, "initiator", "Mode: initiator | target");
DEFINE_string(operation, "write", "Operation: read | write");
DEFINE_string(segment_id, "",
              "Target segment id (host:port), required for initiator.");
DEFINE_uint64(buffer_size, 1ull << 30, "Buffer size per NUMA node (bytes).");
DEFINE_int32(batch_size, 128, "Requests per batch.");
DEFINE_uint64(block_size, 65536, "Block size per request (bytes).");
DEFINE_int32(threads, 12, "Initiator worker threads.");
DEFINE_int32(duration, 20, "Test duration (seconds).");
DEFINE_int32(rpc_port, 12345, "Local RPC port (target).");

namespace {

const static int NR_SOCKETS =
    numa_available() == 0 ? numa_num_configured_nodes() : 1;

std::atomic<bool> running{true};
std::atomic<size_t> total_batch_count{0};
std::atomic<size_t> total_bytes{0};

// Thread-local latency samples are merged into this vector under
// `latency_mutex` after the worker stops.
std::mutex latency_mutex;
std::vector<uint64_t> latencies_us;

void bindToSocket(int socket_id) {
    if (numa_available() != 0) return;
    struct bitmask *cpu_mask = numa_allocate_cpumask();
    if (numa_node_to_cpus(socket_id % NR_SOCKETS, cpu_mask) == 0) {
        numa_sched_setaffinity(0, cpu_mask);
    }
    numa_free_cpumask(cpu_mask);
}

std::vector<void *> allocateBuffers() {
    std::vector<void *> addrs(NR_SOCKETS, nullptr);
    for (int i = 0; i < NR_SOCKETS; ++i) {
        if (numa_available() == 0) {
            addrs[i] = numa_alloc_onnode(FLAGS_buffer_size, i);
        } else {
            addrs[i] = aligned_alloc(4096, FLAGS_buffer_size);
        }
        if (!addrs[i]) {
            LOG(FATAL) << "Failed to allocate " << FLAGS_buffer_size
                       << " bytes on node " << i;
        }
        std::memset(addrs[i], 0, FLAGS_buffer_size);
    }
    return addrs;
}

void freeBuffers(std::vector<void *> &addrs) {
    for (int i = 0; i < NR_SOCKETS; ++i) {
        if (!addrs[i]) continue;
        if (numa_available() == 0) {
            numa_free(addrs[i], FLAGS_buffer_size);
        } else {
            free(addrs[i]);
        }
    }
}

void initiatorWorker(TransferEngine *engine, SegmentID segment_id,
                     int thread_id, void *addr) {
    bindToSocket(thread_id % NR_SOCKETS);

    TransferRequest::OpCode opcode;
    if (FLAGS_operation == "read")
        opcode = TransferRequest::READ;
    else if (FLAGS_operation == "write")
        opcode = TransferRequest::WRITE;
    else
        LOG(FATAL) << "operation must be 'read' or 'write'";

    auto seg_desc = engine->getMetadata()->getSegmentDescByID(segment_id);
    if (!seg_desc) LOG(FATAL) << "openSegment did not yield a desc";

    int buffer_index = thread_id % NR_SOCKETS;
    if (buffer_index >= (int)seg_desc->buffers.size()) {
        LOG(FATAL) << "remote segment has fewer buffers ("
                   << seg_desc->buffers.size() << ") than expected ("
                   << NR_SOCKETS << ")";
    }
    uint64_t remote_base = (uint64_t)seg_desc->buffers[buffer_index].addr;

    std::vector<uint64_t> local_latencies;
    local_latencies.reserve(4096);

    size_t batch_count = 0;
    size_t local_bytes = 0;
    while (running.load(std::memory_order_relaxed)) {
        auto batch_id = engine->allocateBatchID(FLAGS_batch_size);
        std::vector<TransferRequest> requests;
        requests.reserve(FLAGS_batch_size);
        for (int i = 0; i < FLAGS_batch_size; ++i) {
            TransferRequest e;
            e.opcode = opcode;
            e.length = FLAGS_block_size;
            e.source = (uint8_t *)addr +
                       FLAGS_block_size * (i * FLAGS_threads + thread_id);
            e.target_id = segment_id;
            e.target_offset =
                remote_base +
                FLAGS_block_size * (i * FLAGS_threads + thread_id);
            requests.push_back(e);
        }

        auto t0 = std::chrono::steady_clock::now();
        auto s = engine->submitTransfer(batch_id, requests);
        if (!s.ok()) LOG(FATAL) << "submitTransfer: " << s.ToString();

        for (int task = 0; task < FLAGS_batch_size; ++task) {
            TransferStatus st;
            while (true) {
                auto gs = engine->getTransferStatus(batch_id, task, st);
                if (!gs.ok()) LOG(FATAL) << "getTransferStatus: " << gs.ToString();
                if (st.s == TransferStatusEnum::COMPLETED) break;
                if (st.s == TransferStatusEnum::FAILED) {
                    LOG(FATAL) << "transfer failed task=" << task;
                }
            }
        }
        auto t1 = std::chrono::steady_clock::now();
        uint64_t us =
            std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0)
                .count();
        local_latencies.push_back(us);

        engine->freeBatchID(batch_id);
        batch_count++;
        local_bytes += (size_t)FLAGS_batch_size * (size_t)FLAGS_block_size;
    }

    total_batch_count.fetch_add(batch_count);
    total_bytes.fetch_add(local_bytes);
    {
        std::lock_guard<std::mutex> lk(latency_mutex);
        latencies_us.insert(latencies_us.end(), local_latencies.begin(),
                            local_latencies.end());
    }
}

double percentile(std::vector<uint64_t> &v, double p) {
    if (v.empty()) return 0.0;
    size_t n = v.size();
    double idx = p * (n - 1);
    size_t lo = (size_t)std::floor(idx);
    size_t hi = (size_t)std::ceil(idx);
    if (lo == hi) return (double)v[lo];
    return v[lo] + (v[hi] - v[lo]) * (idx - lo);
}

int run_initiator() {
    auto engine = std::make_unique<TransferEngine>(/*auto_discover=*/false);
    auto hp = mooncake::parseHostNameWithPort(FLAGS_local_server_name);
    int rc = engine->init(FLAGS_metadata_server, FLAGS_local_server_name,
                          hp.first, hp.second);
    if (rc) LOG(FATAL) << "TransferEngine::init failed: rc=" << rc;

    auto *xport = engine->installTransport("tcp", nullptr);
    if (!xport) LOG(FATAL) << "installTransport(tcp) failed";

    auto addrs = allocateBuffers();
    for (int i = 0; i < NR_SOCKETS; ++i) {
        if (engine->registerLocalMemory(addrs[i], FLAGS_buffer_size,
                                        mooncake::kWildcardLocation)) {
            LOG(FATAL) << "registerLocalMemory failed for node " << i;
        }
    }

    auto seg = engine->openSegment(FLAGS_segment_id.c_str());
    if (seg == 0) LOG(FATAL) << "openSegment(" << FLAGS_segment_id << ") failed";

    std::vector<std::thread> workers;
    workers.reserve(FLAGS_threads);

    auto start = std::chrono::steady_clock::now();
    for (int i = 0; i < FLAGS_threads; ++i) {
        workers.emplace_back(initiatorWorker, engine.get(), seg, i,
                             addrs[i % NR_SOCKETS]);
    }
    std::this_thread::sleep_for(std::chrono::seconds(FLAGS_duration));
    running = false;
    for (auto &w : workers) w.join();
    auto stop = std::chrono::steady_clock::now();

    double secs =
        std::chrono::duration_cast<std::chrono::milliseconds>(stop - start)
            .count() /
        1000.0;
    size_t bytes = total_bytes.load();
    size_t batches = total_batch_count.load();
    double gbps = (bytes * 8.0) / 1e9 / secs;

    {
        std::lock_guard<std::mutex> lk(latency_mutex);
        std::sort(latencies_us.begin(), latencies_us.end());
        double p50 = percentile(latencies_us, 0.50);
        double p95 = percentile(latencies_us, 0.95);
        double p99 = percentile(latencies_us, 0.99);
        double sum = 0;
        for (auto v : latencies_us) sum += v;
        double mean = latencies_us.empty() ? 0 : sum / latencies_us.size();
        uint64_t max_us = latencies_us.empty() ? 0 : latencies_us.back();

        std::cout << std::fixed << std::setprecision(2);
        std::cout << "TPUT_STATS duration_s=" << secs
                  << " batches=" << batches
                  << " bytes=" << bytes
                  << " goodput_gbps=" << gbps << "\n";
        std::cout << "LAT_STATS samples=" << latencies_us.size()
                  << " p50_us=" << p50
                  << " p95_us=" << p95
                  << " p99_us=" << p99
                  << " mean_us=" << mean
                  << " max_us=" << max_us << "\n";
    }

    for (int i = 0; i < NR_SOCKETS; ++i) engine->unregisterLocalMemory(addrs[i]);
    freeBuffers(addrs);
    return 0;
}

int run_target() {
    auto engine = std::make_unique<TransferEngine>(/*auto_discover=*/false);
    auto hp = mooncake::parseHostNameWithPort(FLAGS_local_server_name);
    int rc = engine->init(FLAGS_metadata_server, FLAGS_local_server_name,
                          hp.first, hp.second);
    if (rc) LOG(FATAL) << "TransferEngine::init failed: rc=" << rc;

    auto *xport = engine->installTransport("tcp", nullptr);
    if (!xport) LOG(FATAL) << "installTransport(tcp) failed";

    auto addrs = allocateBuffers();
    for (int i = 0; i < NR_SOCKETS; ++i) {
        if (engine->registerLocalMemory(addrs[i], FLAGS_buffer_size,
                                        mooncake::kWildcardLocation)) {
            LOG(FATAL) << "registerLocalMemory failed for node " << i;
        }
    }

    LOG(INFO) << "Transfer Engine RPC using TCP, listening on "
              << engine->getLocalIpAndPort();

    while (true) std::this_thread::sleep_for(std::chrono::seconds(60));
    // unreachable
    return 0;
}

}  // namespace

int main(int argc, char **argv) {
    gflags::ParseCommandLineFlags(&argc, &argv, true);
    google::InitGoogleLogging(argv[0]);
    FLAGS_logtostderr = true;
    FLAGS_colorlogtostderr = true;

    if (FLAGS_mode == "target") return run_target();
    if (FLAGS_mode == "initiator") {
        if (FLAGS_segment_id.empty()) {
            LOG(FATAL) << "--segment_id required for initiator";
        }
        return run_initiator();
    }
    LOG(FATAL) << "--mode must be 'target' or 'initiator', got: " << FLAGS_mode;
    return 1;
}
