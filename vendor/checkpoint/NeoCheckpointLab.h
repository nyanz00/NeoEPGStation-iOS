/* BSD-2-Clause. Independent diagnostic API; no FFmpeg/dav1d types cross it. */
#ifndef NEO_CHECKPOINT_LAB_H
#define NEO_CHECKPOINT_LAB_H
#include <stddef.h>
#include <stdint.h>
#define NEO_CHECKPOINT_REPEATS 5
typedef struct NeoCheckpointPacket {
    const uint8_t *data;
    size_t size;
    double seconds;
} NeoCheckpointPacket;
typedef struct NeoCheckpointResult {
    int status; /* 0=success; 1001=input, 1002=boundary, 1003=mismatch,
                 1004=no target/keyframe, 1005=memory, 1006=cancel, 1007=timeout, 1008=native */
    int decoder_error, failure_stage;
    int threads, frame_contexts, packed;
    uint64_t compared_frames, compared_pixel_bytes;
    uint64_t retained_bytes, state_bytes, picture_bytes;
    uint32_t unique_pictures, width, height, bit_depth;
    double checkpoint_seconds, target_seconds, first_following_key_seconds;
    double save_ms, drain_before_save_ms;
    double repeated_save_ms[NEO_CHECKPOINT_REPEATS];
    double restored_ms[NEO_CHECKPOINT_REPEATS];
    double restore_only_ms[NEO_CHECKPOINT_REPEATS];
    uint64_t sampled_footprint_bytes[NEO_CHECKPOINT_REPEATS];
    uint64_t before_bytes, sampled_peak_bytes, after_bytes;
    int empty_rejected, busy_rejected, wrong_owner_rejected, suffix_without_state_rejected;
    int restore_count, temporary_save_free_count, target_verified_count;
    int full_suffix_passes, allocation_verification_passes, original_pixels_detached;
} NeoCheckpointResult;
/* Synchronous worker-only call. Input remains borrowed until return. One
 * checkpoint at a time; configured worker/frame parallelism; never normal playback. */
int neo_checkpoint_lab_run(const NeoCheckpointPacket *packets, size_t count,
    double gop_seconds, double distance_seconds, int threads, int packed, NeoCheckpointResult *out,
    int (*cancelled)(void *), void *cookie);
uint64_t neo_checkpoint_lab_footprint(void);

/* Storage diagnostic: method 0=packed10, 4=delta/shuffle LZ4,
 * 7=delta/shuffle Zstd level 1; 9=CPU independent LZ4 64KiB; 10=rcomp-metal;
 * 11/12=CPU/Metal lsCOMP raw; 13/14=CPU/Metal lsCOMP delta (lossless only).
 * 15=Metal Zstd full encoder; 16=its CPU reference/control.
 * Preprocessing and restore remain on CPU. Never normal playback. */
typedef struct NeoStorageResult {
    NeoCheckpointResult checkpoint;
    int method;
    double save_cpu_ms[NEO_CHECKPOINT_REPEATS];
    double gpu_setup_ms,gpu_ms[NEO_CHECKPOINT_REPEATS],gpu_wait_ms[NEO_CHECKPOINT_REPEATS];
    uint64_t gpu_staging_bytes;
    int gpu_dispatches;
    double gpu_stage_total_ms[7];
    int gpu_stage_timed_batches;
} NeoStorageResult;
int neo_checkpoint_storage_run(const NeoCheckpointPacket *,size_t,double,double,int,
    NeoStorageResult *,int(*)(void*),void*);

#define NEO_REALTIME_MAX_SAVES 32
#define NEO_REALTIME_TARGETS 3
typedef struct NeoRealtimeResult {
    int status,decoder_error,method,frames,late_frames,completed_saves,skipped_busy,evicted;
    int retained_count,target_verified_count;
    uint64_t retained_bytes,maximum_retained_bytes,memory_budget_bytes;
    uint64_t before_bytes,sampled_peak_bytes,after_bytes;
    double media_seconds,wall_seconds,late_mean_ms,late_p95_ms,late_max_ms;
    double save_ms[NEO_REALTIME_MAX_SAVES],save_cpu_ms[NEO_REALTIME_MAX_SAVES];
    double capture_ms[NEO_REALTIME_MAX_SAVES];
    double target_ms[NEO_REALTIME_TARGETS],target_seconds[NEO_REALTIME_TARGETS],chosen_seconds[NEO_REALTIME_TARGETS];
    int used_checkpoint[NEO_REALTIME_TARGETS];
    double gpu_setup_ms,gpu_ms[NEO_REALTIME_MAX_SAVES],gpu_wait_ms[NEO_REALTIME_MAX_SAVES];
    uint64_t gpu_staging_bytes;
    int gpu_dispatches;
    double gpu_stage_total_ms[7];
    int gpu_stage_timed_batches;
} NeoRealtimeResult;
int neo_checkpoint_realtime_run(const NeoCheckpointPacket *,size_t,double,int,
    NeoRealtimeResult *,int(*)(void*),void*);
#endif
