/* PC-only export of the actual unique dav1d reference allocations. BSD-2-Clause.
 * Reuses the already tested multithreaded feeder; never exports decoder pointers.
 */
#include "config.h"
#include "neo_parallel_harness.h"
#include "src/internal.h"
#include "src/mem.h"

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    choose_cores();
    Input in = input_open(argv[1]);
    size_t point = index_at(&in, strtod(argv[2], NULL));
    Context owner = open_context((Config){6, 0});
    prefix(&owner, &in, point);
    NeoCheckpoint *saved = NULL;
    check(neo_checkpoint_save(owner.c, &saved) == 0, "quiescent reference boundary");
    NeoCheckpointStats stats;
    neo_checkpoint_stats(saved, &stats);
    const void *seen[8] = {0};
    unsigned count = 0;
    size_t total = 0;
    printf("{\"checkpointSeconds\":%.6f,\"images\":[", seconds(&in, point));
    for (unsigned slot = 0; slot < 8; ++slot) {
        const Dav1dPicture *pic = &owner.c->refs[slot].p.p;
        if (!pic->data[0]) continue;
        unsigned j = 0;
        while (j < count && seen[j] != pic->allocator_data) ++j;
        if (j < count) continue;
        seen[count] = pic->allocator_data;
        const Dav1dMemPoolBuffer *block = (const void *)((const uint8_t *)pic->allocator_data - 64);
        check(pic->p.bpc == 10 && pic->p.layout == DAV1D_PIXEL_LAYOUT_I420, "10bit 420 input");
        check(block->size > 0 && block->size < 32 * 1024 * 1024, "allocation bound");
        char name[1024];
        check(snprintf(name, sizeof(name), "%s/%u.bin", argv[3], count) > 0, "output path");
        FILE *file = fopen(name, "wb"); check(file != NULL, "export open");
        check(fwrite(pic->allocator_data, 1, block->size, file) == block->size, "export write");
        check(fclose(file) == 0, "export close");
        printf("%s{\"file\":\"%u.bin\",\"bytes\":%zu,\"width\":%d,\"height\":%d,\"bpc\":%d,\"stride\":[%td,%td],\"offset\":[",
               count ? "," : "", count, block->size, pic->p.w, pic->p.h, pic->p.bpc, pic->stride[0], pic->stride[1]);
        for (int pl = 0; pl < 3; ++pl)
            printf("%s%zu", pl ? "," : "", (const uint8_t *)pic->data[pl] - (const uint8_t *)pic->allocator_data);
        printf("]}");
        total += block->size; ++count;
    }
    check(count == stats.unique_pictures && total + 64 * count == stats.picture_bytes, "deduplicated allocation accounting");
    printf("],\"rawImageBytes\":%zu,\"otherCheckpointBytes\":%zu}\n", total, stats.retained_bytes - total);
    neo_checkpoint_free(&saved); dav1d_close(&owner.c);
    for (size_t j = 0; j < in.count; ++j) free(in.p[j].data);
    free(in.p); return 0;
}
