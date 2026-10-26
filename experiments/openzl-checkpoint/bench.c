/* CPU-only standalone reference-image compression comparison. BSD-2-Clause.
 * No I/O or byte comparison inside the compression/decompression timers.
 */
#include <windows.h>
#include <psapi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include "zstd.h"
#include "openzl/zl_compressor.h"
#include "openzl/zl_decompress.h"

/* GNU ld allocation wrapping: requested live bytes, not resident memory or
 * allocator overhead. Both libraries are static and use the same wrappers. */
void *__real_malloc(size_t);
void *__real_calloc(size_t, size_t);
void *__real_realloc(void *, size_t);
void __real_free(void *);
typedef union Header { size_t bytes; max_align_t align; } Header;
static size_t live_bytes, peak_bytes;
void *__wrap_malloc(size_t n) {
    if (n > SIZE_MAX - sizeof(Header)) return NULL;
    Header *h = __real_malloc(sizeof(Header) + n);
    if (!h) return NULL;
    h->bytes = n; live_bytes += n;
    if (live_bytes > peak_bytes) peak_bytes = live_bytes;
    return h + 1;
}
void __wrap_free(void *p) {
    if (!p) return;
    Header *h = (Header *)p - 1;
    live_bytes -= h->bytes; __real_free(h);
}
void *__wrap_calloc(size_t n, size_t s) {
    if (n && s > SIZE_MAX / n) return NULL;
    void *p = __wrap_malloc(n * s);
    if (p) memset(p, 0, n * s);
    return p;
}
void *__wrap_realloc(void *p, size_t n) {
    if (!p) return __wrap_malloc(n);
    if (!n) { __wrap_free(p); return NULL; }
    if (n > SIZE_MAX - sizeof(Header)) return NULL;
    Header *old = (Header *)p - 1;
    size_t before = old->bytes;
    Header *h = __real_realloc(old, sizeof(Header) + n);
    if (!h) return NULL;
    h->bytes = n; live_bytes = live_bytes - before + n;
    if (live_bytes > peak_bytes) peak_bytes = live_bytes;
    return h + 1;
}
static void need(int ok, const char *message) {
    if (!ok) { fprintf(stderr, "%s\n", message); exit(1); }
}
static double clock_ms(void) {
    LARGE_INTEGER t, f; QueryPerformanceCounter(&t); QueryPerformanceFrequency(&f);
    return 1000.0 * (double)t.QuadPart / (double)f.QuadPart;
}
static double thread_ms(void) {
    FILETIME a, b, k, u;
    need(GetThreadTimes(GetCurrentThread(), &a, &b, &k, &u), "thread CPU timer");
    ULARGE_INTEGER x, y;
    x.LowPart = k.dwLowDateTime; x.HighPart = k.dwHighDateTime;
    y.LowPart = u.dwLowDateTime; y.HighPart = u.dwHighDateTime;
    return (double)(x.QuadPart + y.QuadPart) / 10000.0;
}
typedef struct Image {
    uint8_t *raw;
    size_t size, offset[3];
    int w, h, stride[2];
} Image;
typedef struct Frame { uint8_t *data; size_t size; } Frame;
static void delta(const Image *im, uint8_t *buf, int undo) {
    uint8_t tmp[8192]; need(im->w <= 4096, "delta width");
    for (int pl = 0; pl < 3; ++pl) {
        int w = pl ? (im->w + 1) / 2 : im->w;
        int h = pl ? (im->h + 1) / 2 : im->h;
        for (int y = 0; y < h; ++y) {
            uint16_t *v = (void *)(buf + im->offset[pl] + (size_t)y * im->stride[pl != 0]);
            if (undo) {
                memcpy(tmp, v, (size_t)w * 2);
                for (int x = 0; x < w; ++x) v[x] = (uint16_t)(tmp[x] | (unsigned)tmp[w+x] << 8);
            }
            int previous = 0;
            for (int x = 0; x < w; ++x) {
                if (undo) { int z = v[x]; previous += (z >> 1) ^ -(z & 1); v[x] = (uint16_t)previous; }
                else { int current = v[x], d = current - previous; previous = current; v[x] = (uint16_t)(d >= 0 ? 2*d : -2*d-1); }
            }
            if (!undo) {
                for (int x = 0; x < w; ++x) { tmp[x] = (uint8_t)v[x]; tmp[w+x] = (uint8_t)(v[x] >> 8); }
                memcpy(v, tmp, (size_t)w * 2);
            }
        }
    }
}
static int method, level;
static ZL_GraphID graph(ZL_Compressor *c) {
    need(!ZL_isError(ZL_Compressor_setParameter(c, ZL_CParam_formatVersion, ZL_MAX_FORMAT_VERSION)), "format parameter");
    need(!ZL_isError(ZL_Compressor_setParameter(c, ZL_CParam_compressionLevel, level)), "level parameter");
    if (method == 6 || method == 7) return ZL_GRAPH_LZ;
    if (method == 3)
        return ZL_Compressor_registerStaticGraph_fromPipelineNodes1o(c,
            ZL_NODELIST(ZL_NODE_INTERPRET_AS_LE16), ZL_GRAPH_NUMERIC);
    if (method == 4)
        return ZL_Compressor_registerStaticGraph_fromPipelineNodes1o(c,
            ZL_NODELIST(ZL_NODE_INTERPRET_AS_LE16, ZL_NODE_DELTA_INT, ZL_NODE_ZIGZAG), ZL_GRAPH_NUMERIC);
    return ZL_GRAPH_COMPRESS_GENERIC;
}
static Frame compress_image(const Image *im) {
    int prep = method == 1 || method == 5 || method == 7;
    uint8_t *input = im->raw;
    if (prep) { input = malloc(im->size); need(input != NULL, "preprocess allocation"); memcpy(input, im->raw, im->size); delta(im, input, 0); }
    size_t capacity = method < 2 ? ZSTD_compressBound(im->size) : 2 * im->size + 65536;
    Frame f = { malloc(capacity), 0 }; need(f.data != NULL, "output allocation");
    if (method < 2) {
        f.size = ZSTD_compress(f.data, capacity, input, im->size, level);
        need(!ZSTD_isError(f.size), "Zstandard compression");
    } else {
        ZL_Report r = ZL_compress_usingGraphFn(f.data, capacity, input, im->size, graph);
        if (ZL_isError(r)) { fprintf(stderr, "OpenZL error method=%d level=%d code=%d\n", method, level, (int)ZL_errorCode(r)); exit(1); }
        f.size = ZL_validResult(r);
    }
    if (prep) free(input);
    uint8_t *small = realloc(f.data, f.size); need(small != NULL, "output shrink"); f.data = small;
    return f;
}
static uint8_t *decompress_image(const Image *im, const Frame *f) {
    uint8_t *out = malloc(im->size); need(out != NULL, "restore allocation");
    if (method < 2) {
        size_t n = ZSTD_decompress(out, im->size, f->data, f->size);
        need(!ZSTD_isError(n) && n == im->size, "Zstandard restore");
    } else {
        ZL_Report r = ZL_decompress(out, im->size, f->data, f->size);
        need(!ZL_isError(r) && ZL_validResult(r) == im->size, "OpenZL restore");
    }
    if (method == 1 || method == 5 || method == 7) delta(im, out, 1);
    return out;
}
int main(int argc, char **argv) {
    if (argc != 5) return 2;
    /* All cases use a single compression thread on the same logical CPU. */
    need(SetProcessAffinityMask(GetCurrentProcess(), 1), "affinity");
    method = atoi(argv[2]); level = atoi(argv[3]); int repeats = atoi(argv[4]);
    need(method >= 0 && method <= 7 && repeats >= 1 && repeats <= 9, "arguments");
    char path[1024]; snprintf(path, sizeof(path), "%s/geometry.txt", argv[1]);
    FILE *manifest = fopen(path, "r"); need(manifest != NULL, "geometry input");
    unsigned count = 0; need(fscanf(manifest, "%u", &count) == 1 && count > 0 && count <= 8, "image count");
    Image images[8] = {0}; size_t raw_bytes = 0;
    for (unsigned i = 0; i < count; ++i) {
        Image *im = &images[i];
        need(fscanf(manifest, "%zu%d%d%d%d%zu%zu%zu", &im->size, &im->w, &im->h,
                    &im->stride[0], &im->stride[1], &im->offset[0], &im->offset[1], &im->offset[2]) == 8, "geometry row");
        need(im->size < 32*1024*1024 && !(im->size & 1), "input budget");
        snprintf(path, sizeof(path), "%s/%u.bin", argv[1], i);
        FILE *f = fopen(path, "rb"); need(f != NULL, "image input");
        im->raw = malloc(im->size); need(im->raw != NULL, "source allocation");
        need(fread(im->raw, 1, im->size, f) == im->size && fgetc(f) == EOF, "image length"); fclose(f);
        raw_bytes += im->size;
    }
    fclose(manifest);
    size_t baseline = live_bytes;
    printf("{\"method\":%d,\"level\":%d,\"rawImageBytes\":%zu,\"images\":%u,\"rounds\":[", method, level, raw_bytes, count);
    /* First round is a separately reported warm-up. */
    for (int rep = -1; rep < repeats; ++rep) {
        need(live_bytes == baseline, "allocation leak before round"); peak_bytes = live_bytes;
        Frame frames[8] = {0}; uint8_t *out[8] = {0}; size_t compressed = 0;
        double cpu = thread_ms(), start = clock_ms();
        for (unsigned i = 0; i < count; ++i) { frames[i] = compress_image(&images[i]); compressed += frames[i].size; }
        double save = clock_ms() - start, save_cpu = thread_ms() - cpu;
        size_t compression_peak = peak_bytes - baseline;
        need(live_bytes == baseline + compressed, "compression temporary allocation leak");
        peak_bytes = live_bytes;
        cpu = thread_ms(); start = clock_ms();
        for (unsigned i = 0; i < count; ++i) out[i] = decompress_image(&images[i], &frames[i]);
        double restore = clock_ms() - start, restore_cpu = thread_ms() - cpu;
        size_t restoration_peak = peak_bytes - baseline - compressed;
        for (unsigned i = 0; i < count; ++i) {
            need(!memcmp(out[i], images[i].raw, images[i].size), "allocation byte mismatch");
            free(out[i]); free(frames[i].data);
        }
        need(live_bytes == baseline, "allocation leak after round");
        printf("%s{\"warmup\":%s,\"compressedBytes\":%zu,\"saveMs\":%.6f,\"saveThreadCpuMs\":%.6f,\"restoreMs\":%.6f,\"restoreThreadCpuMs\":%.6f,\"compressionAdditionalPeakBytes\":%zu,\"restorationAdditionalPeakBytes\":%zu,\"exactBytes\":true}",
               rep == -1 ? "" : ",", rep == -1 ? "true" : "false", compressed, save, save_cpu, restore, restore_cpu, compression_peak, restoration_peak);
        fflush(stdout);
    }
    PROCESS_MEMORY_COUNTERS_EX pm = {0}; pm.cb = sizeof(pm);
    need(GetProcessMemoryInfo(GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS *)&pm, sizeof(pm)), "memory counter");
    for (unsigned i = 0; i < count; ++i) free(images[i].raw);
    /* MinGW's input/stdio initialization can retain a process-lifetime buffer.
     * Each codec round must return exactly to its pre-compression baseline. */
    need(live_bytes == baseline - raw_bytes, "final allocation leak");
    printf("],\"trackedLiveBytesAfterFree\":%zu,\"trackedPreCompressionNonImageBytes\":%zu,\"processPeakWorkingSetBytes\":%zu,\"processPeakCommitBytes\":%zu}\n", live_bytes, baseline - raw_bytes, (size_t)pm.PeakWorkingSetSize, (size_t)pm.PeakPagefileUsage);
    return 0;
}
