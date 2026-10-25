/* Minimal feasibility experiment, not a production decoder API.
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
    Dav1dRef *seq_ref;
    __typeof__(((Dav1dContext *)0)->refs) refs;
    CdfThreadContext cdf[8];
    unsigned operating_point_idc;
    int max_spatial_id, drain;
    enum PictureFlags frame_flags;
    enum Dav1dEventFlags event_flags;
};

static int boundary(const Dav1dContext *c) {
    if (!c || c->n_tc != 1 || c->n_fc != 1 ||
        c->allocator.alloc_picture_callback != dav1d_default_picture_alloc)
        return 0;
    return !c->in.data && !c->out.p.data[0] && !c->cache.p.data[0] &&
           !c->frame_hdr && !c->n_tile_data && !c->cached_error &&
           !c->content_light_ref && !c->mastering_display_ref && !c->itut_t35_ref;
}

int neo_checkpoint_save(Dav1dContext *c, NeoCheckpoint **out) {
    if (!out || *out || !boundary(c) || !c->seq_hdr_ref)
        return DAV1D_ERR(EINVAL);
    NeoCheckpoint *p = calloc(1, sizeof(*p));
    if (!p) return DAV1D_ERR(ENOMEM);
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
    if (!p || p->owner != c || !boundary(c)) return DAV1D_ERR(EINVAL);
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
