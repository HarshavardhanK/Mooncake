# PrfaaS M1 — latency-aware bench, gated by -DWITH_PRFAAS=ON in the top-level
# CMakeLists. Links against the same `transfer_engine` target as the upstream
# benches so we share the exact transport/topology/config code.

add_executable(transfer_engine_lat_bench transfer_engine_lat_bench.cpp)

target_link_libraries(transfer_engine_lat_bench
  PUBLIC
    transfer_engine
    glog::glog
    gflags::gflags
    numa
    pthread
)

target_include_directories(transfer_engine_lat_bench
  PRIVATE
    ${CMAKE_SOURCE_DIR}/mooncake-transfer-engine/include
)
