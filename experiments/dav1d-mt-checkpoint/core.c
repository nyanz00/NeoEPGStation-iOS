/* BSD-2-Clause. Quiescent multi-thread checkpoint experiment.
 * Derived from the tested single-thread checkpoint; no thread state is copied.
 * Reference objects remain in the process; immutable buffers are retained,
 * not copied. Synchronization primitives, frame workers and DSP tables are
 * deliberately never snapshotted. See README.md for the tested boundary.
 */
#include "config.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include "src/internal.h"
#include "src/picture.h"
#include "src/cdf.h"
#include "neo_checkpoint.h"

struct NeoCheckpoint {
    const Dav1dContext *owner;
    unsigned threads, frame_contexts;
    Dav1dRef *seq_ref;
    __typeof__(((Dav1dContext *)0)->refs) refs;
    CdfThreadContext cdf[8];
    unsigned operating_point_idc;
    int max_spatial_id, drain;
    enum PictureFlags frame_flags;
    enum Dav1dEventFlags event_flags;
};

/* Caller exclusively owns the decoder API. No input may be submitted from
 * another thread. Do not drain/drop user frames here: a non-empty pipeline is
 * rejected. After full drain, synchronize with the existing worker idle park. */
static int boundary(Dav1dContext *c) {
    if (!c || !c->n_tc || !c->n_fc ||
        c->allocator.alloc_picture_callback != dav1d_default_picture_alloc ||
        c->in.data || c->out.p.data[0] || c->cache.p.data[0] ||
        c->frame_hdr || c->n_tile_data || c->cached_error ||
        c->content_light_ref || c->mastering_display_ref || c->itut_t35_ref)
        return 0;
    if (c->n_tc == 1) return c->n_fc == 1;
    struct TaskThreadData *ttd = &c->task_thread;
    pthread_mutex_lock(&ttd->lock);
    int ok = !atomic_load(c->flush) && !ttd->delayed_fg.exec;
    for (unsigned i = 0; i < c->n_fc && ok; i++) {
        Dav1dFrameContext *f = &c->fc[i];
        if (f->n_tile_data || atomic_load(&f->task_thread.task_counter) ||
            f->task_thread.retval || atomic_load(&f->task_thread.error) ||
            (c->n_fc > 1 && c->frame_thread.out_delayed[i].p.frame_hdr)) ok = 0;
    }
    /* A completed frame can have just signaled completion while its worker
     * still finishes bookkeeping. Wait until all existing workers are parked;
     * this neither flushes references nor serializes their stacks/mutexes. */
    for (unsigned i = 0; i < c->n_tc && ok; i++)
        while (!c->tc[i].task_thread.flushed)
            pthread_cond_wait(&c->tc[i].task_thread.td.cond, &ttd->lock);
    for (unsigned i = 0; i < c->n_fc && ok; i++)
        if (c->fc[i].task_thread.task_head ||
            c->fc[i].task_thread.pending_tasks.head) ok = 0;
    for (int i = 0; i < 8 && ok; i++) {
        atomic_uint *progress = c->refs[i].p.progress;
        if (c->n_fc > 1 && c->refs[i].p.p.data[0] && !progress) ok = 0;
        if (progress && (atomic_load(&progress[0]) != UINT_MAX ||
                         atomic_load(&progress[1]) != UINT_MAX)) ok = 0;
        if (c->cdf[i].progress && atomic_load(c->cdf[i].progress) != 1) ok = 0;
    }
    pthread_mutex_unlock(&ttd->lock);
    return ok;
}

int neo_checkpoint_save(Dav1dContext *c, NeoCheckpoint **out) {
    if (!out || *out || !boundary(c) || !c->seq_hdr_ref)
        return DAV1D_ERR(EINVAL);
    NeoCheckpoint *p = calloc(1, sizeof(*p));
    if (!p) return DAV1D_ERR(ENOMEM);
    p->threads = c->n_tc; p->frame_contexts = c->n_fc;
    p->owner = c; p->seq_ref = c->seq_hdr_ref; dav1d_ref_inc(p->seq_ref);
    for (int i = 0; i < 8; ++i) {
        if (c->refs[i].p.p.data[0])
            dav1d_thread_picture_ref(&p->refs[i].p, &c->refs[i].p);
        p->refs[i].segmap = c->refs[i].segmap;
        p->refs[i].refmvs = c->refs[i].refmvs;
        if (p->refs[i].segmap) dav1d_ref_inc(p->refs[i].segmap);
        if (p->refs[i].refmvs) dav1d_ref_inc(p->refs[i].refmvs);
        memcpy(p->refs[i].refpoc, c->refs[i].refpoc, sizeof(p->refs[i].refpoc));
        dav1d_cdf_thread_ref(&p->cdf[i], &c->cdf[i]);
    }
    p->operating_point_idc = c->operating_point_idc;
    p->max_spatial_id = c->max_spatial_id;
    p->drain = c->drain;
    p->frame_flags = c->frame_flags; p->event_flags = c->event_flags;
    *out = p;
    return 0;
}

int neo_checkpoint_restore(Dav1dContext *c, const NeoCheckpoint *p) {
    if (!p || p->owner != c || !boundary(c) ||
        p->threads != c->n_tc || p->frame_contexts != c->n_fc) return DAV1D_ERR(EINVAL);
    /* Flush the CURRENT stream state, retaining reusable decoder workspace.
     * No keyframe or sequence header is replayed after this point. */
    dav1d_flush(c);
    c->seq_hdr_ref = p->seq_ref; dav1d_ref_inc(c->seq_hdr_ref);
    c->seq_hdr = c->seq_hdr_ref->data;
    for (int i = 0; i < 8; ++i) {
        if (p->refs[i].p.p.data[0])
            dav1d_thread_picture_ref(&c->refs[i].p, &p->refs[i].p);
        c->refs[i].segmap = p->refs[i].segmap;
        c->refs[i].refmvs = p->refs[i].refmvs;
        if (c->refs[i].segmap) dav1d_ref_inc(c->refs[i].segmap);
        if (c->refs[i].refmvs) dav1d_ref_inc(c->refs[i].refmvs);
        memcpy(c->refs[i].refpoc, p->refs[i].refpoc, sizeof(c->refs[i].refpoc));
        /* Upstream's helper takes a mutable source although it only reads
         * its fields and retains the referenced allocation. */
        CdfThreadContext cdf = p->cdf[i];
        dav1d_cdf_thread_ref(&c->cdf[i], &cdf);
    }
    c->operating_point_idc = p->operating_point_idc;
    c->max_spatial_id = p->max_spatial_id; c->drain = p->drain;
    c->frame_flags = p->frame_flags; c->event_flags = p->event_flags;
    return 0;
}

void neo_checkpoint_free(NeoCheckpoint **saved) {
    if (!saved || !*saved) return;
    NeoCheckpoint *p = *saved; *saved = NULL;
    for (int i = 0; i < 8; ++i) {
        if (p->refs[i].p.p.data[0]) dav1d_thread_picture_unref(&p->refs[i].p);
        dav1d_ref_dec(&p->refs[i].segmap);
        dav1d_ref_dec(&p->refs[i].refmvs);
        dav1d_cdf_thread_unref(&p->cdf[i]);
    }
    dav1d_ref_dec(&p->seq_ref); free(p);
}

/* Exact requested pool-block sizes for the permitted default allocator.
 * Deduplicate shared reference slots. Includes pool headers, not CRT overhead
 * or unrelated decoder scratch/pool capacity. Held storage is NOT an immediate
 * extra allocation: it is shared with live decoding until slots are replaced. */
typedef struct Accounting { const void *seen[128]; unsigned count; size_t bytes; } Accounting;
static size_t account_pool(Accounting *a, const void *data) {
    if (!data) return 0;
    for (unsigned i = 0; i < a->count; ++i) if (a->seen[i] == data) return 0;
    if (a->count == 128) abort();
    a->seen[a->count++] = data;
    const Dav1dMemPoolBuffer *b = (const void *)((const unsigned char *)data - 64);
    const size_t n = b->size + 64;
    a->bytes += n; return n;
}
static void account_ref(Accounting *a, const Dav1dRef *r) {
    if (r) account_pool(a, r->data);
}
void neo_checkpoint_stats(const NeoCheckpoint *p, NeoCheckpointStats *out) {
    memset(out, 0, sizeof(*out)); if (!p) return;
    Accounting a = {0}; out->state_bytes = sizeof(*p);
    account_ref(&a, p->seq_ref);
    for (int i = 0; i < 8; ++i) {
        const Dav1dPicture *pic = &p->refs[i].p.p;
        if (pic->data[0]) {
            size_t n = account_pool(&a, pic->allocator_data);
            if (n) { out->picture_bytes += n; out->unique_pictures++; }
            /* Default allocator picture context is a separate pool block. */
            account_pool(&a, pic->ref->const_data);
            account_ref(&a, pic->seq_hdr_ref); account_ref(&a, pic->frame_hdr_ref);
        }
        account_ref(&a, p->refs[i].segmap); account_ref(&a, p->refs[i].refmvs);
        account_ref(&a, p->cdf[i].ref);
    }
    out->retained_bytes = a.bytes + sizeof(*p); out->unique_allocations = a.count;
}
