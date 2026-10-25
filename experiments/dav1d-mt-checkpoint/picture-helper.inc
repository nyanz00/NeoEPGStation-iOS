/* Appended only to the private PC clone's picture.c. BSD-2-Clause. */
int neo_packed_picture_allocate(Dav1dContext *c, Dav1dThreadPicture *dst,
                               const Dav1dThreadPicture *meta);
int neo_packed_picture_allocate(Dav1dContext *c, Dav1dThreadPicture *dst,
                               const Dav1dThreadPicture *meta) {
    const Dav1dPicture *p = &meta->p;
    int r = picture_alloc(c, &dst->p, p->p.w, p->p.h, p->seq_hdr, p->seq_hdr_ref,
                         p->frame_hdr, p->frame_hdr_ref, p->p.bpc, &p->m,
                         &c->allocator, (void **)&dst->progress);
    if (r) return r;
    dav1d_picture_copy_props(&dst->p, p->content_light, p->content_light_ref,
                            p->mastering_display, p->mastering_display_ref,
                            p->itut_t35, p->itut_t35_ref, p->n_itut_t35, &p->m);
    dst->visible = meta->visible; dst->showable = meta->showable;
    dst->flags = meta->flags;
    if (c->n_fc > 1) {
        atomic_init(&dst->progress[0], UINT_MAX);
        atomic_init(&dst->progress[1], UINT_MAX);
    } else dst->progress = NULL;
    return 0;
}
