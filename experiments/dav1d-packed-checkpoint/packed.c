/* BSD-2-Clause. The original snapshot implementation is included unchanged in
 * this experiment's translation unit. No production source is changed. */
#include "neo_checkpoint.c"
#include "packed.h"

typedef struct PackedImage {
    uint8_t *bytes;
    size_t size, raw_size, offset[3];
    ptrdiff_t stride[2];
    int w, h, bpc, layout;
} PackedImage;
struct NeoPackedCheckpoint {
    NeoCheckpoint *meta;
    PackedImage images[8];
    int slots[8];
    unsigned count;
};
int neo_packed_picture_allocate(Dav1dContext *, Dav1dThreadPicture *, const Dav1dThreadPicture *);

/* Four uint16 samples become five bytes. Padding is never interpreted as a
 * pixel, so uninitialized/high padding bits cannot be discarded by accident. */
static int pack_row(uint8_t *d, const uint16_t *s, int n) {
    int i=0;
    for (; i+4<=n; i+=4,d+=5) {
        const unsigned a=s[i],b=s[i+1],c=s[i+2],e=s[i+3];
        if ((a|b|c|e)>1023) return DAV1D_ERR(EINVAL);
        d[0]=(uint8_t)a; d[1]=(uint8_t)((a>>8)|(b<<2));
        d[2]=(uint8_t)((b>>6)|(c<<4)); d[3]=(uint8_t)((c>>4)|(e<<6)); d[4]=(uint8_t)(e>>2);
    }
    unsigned bits=0,value=0;
    for (;i<n;i++) {
        if(s[i]>1023) return DAV1D_ERR(EINVAL);
        value|=(unsigned)s[i]<<bits; bits+=10;
        while(bits>=8) {*d++=(uint8_t)value; value>>=8; bits-=8;}
    }
    if(bits) *d=(uint8_t)value;
    return 0;
}
static void unpack_row(uint16_t *d,const uint8_t *s,int n) {
    int i=0;
    for (;i+4<=n;i+=4,s+=5) {
        d[i]=(uint16_t)(s[0]|(s[1]&3)<<8);
        d[i+1]=(uint16_t)(s[1]>>2|(s[2]&15)<<6);
        d[i+2]=(uint16_t)(s[2]>>4|(s[3]&63)<<4);
        d[i+3]=(uint16_t)(s[3]>>6|s[4]<<2);
    }
    unsigned bits=0,value=0;
    for(;i<n;i++) {
        while(bits<10) {value|=(unsigned)*s++<<bits;bits+=8;}
        d[i]=(uint16_t)(value&1023);value>>=10;bits-=10;
    }
}
static int width(const PackedImage *im,int plane) {
    return plane && im->layout!=DAV1D_PIXEL_LAYOUT_I444 ? (im->w+1)>>1 : im->w;
}
static int height(const PackedImage *im,int plane) {
    return plane && im->layout==DAV1D_PIXEL_LAYOUT_I420 ? (im->h+1)>>1 : im->h;
}
static int planes(const PackedImage *im) {return im->layout==DAV1D_PIXEL_LAYOUT_I400?1:3;}
static int encode(PackedImage *im,const Dav1dPicture *p) {
    if(p->p.bpc!=8 && p->p.bpc!=10) return DAV1D_ERR(EINVAL);
    im->w=p->p.w;im->h=p->p.h;im->bpc=p->p.bpc;im->layout=p->p.layout;
    memcpy(im->stride,p->stride,sizeof(im->stride));
    const uint8_t *raw=p->allocator_data;
    const Dav1dMemPoolBuffer *block=(const void *)(raw-64);
    im->raw_size=block->size;im->size=im->raw_size;
    for(int plane=0;plane<planes(im);plane++) {
        im->offset[plane]=(const uint8_t *)p->data[plane]-raw;
        if(im->bpc==10) {
            int w=width(im,plane),h=height(im,plane);
            im->size-=(size_t)h*(2*(size_t)w-((size_t)w*10+7)/8);
        }
    }
    im->bytes=malloc(im->size);if(!im->bytes) return DAV1D_ERR(ENOMEM);
    if(im->bpc==8) {memcpy(im->bytes,raw,im->raw_size);return 0;}
    size_t cursor=0,out=0;
    for(int plane=0;plane<planes(im);plane++) {
        int w=width(im,plane),h=height(im,plane);
        for(int y=0;y<h;y++) {
            size_t start=im->offset[plane]+(size_t)y*im->stride[plane?1:0];
            if(start<cursor || start+2*(size_t)w>im->raw_size) return DAV1D_ERR(EINVAL);
            size_t gap=start-cursor;memcpy(im->bytes+out,raw+cursor,gap);out+=gap;
            int r=pack_row(im->bytes+out,(const uint16_t *)(raw+start),w);if(r)return r;
            out+=((size_t)w*10+7)/8;cursor=start+2*(size_t)w;
        }
    }
    memcpy(im->bytes+out,raw+cursor,im->raw_size-cursor);out+=im->raw_size-cursor;
    return out==im->size?0:DAV1D_ERR(EINVAL);
}
static void decode(const PackedImage *im,uint8_t *raw) {
    if(im->bpc==8) {memcpy(raw,im->bytes,im->raw_size);return;}
    size_t cursor=0,in=0;
    for(int plane=0;plane<planes(im);plane++) {
        int w=width(im,plane),h=height(im,plane);
        for(int y=0;y<h;y++) {
            size_t start=im->offset[plane]+(size_t)y*im->stride[plane?1:0];
            size_t gap=start-cursor;memcpy(raw+cursor,im->bytes+in,gap);in+=gap;
            unpack_row((uint16_t *)(raw+start),im->bytes+in,w);
            in+=((size_t)w*10+7)/8;cursor=start+2*(size_t)w;
        }
    }
    memcpy(raw+cursor,im->bytes+in,im->raw_size-cursor);
}
int neo_packed_save(Dav1dContext *c,NeoPackedCheckpoint **out) {
    if(!out || *out) return DAV1D_ERR(EINVAL);
    NeoPackedCheckpoint *p=calloc(1,sizeof(*p));if(!p)return DAV1D_ERR(ENOMEM);
    for(int i=0;i<8;i++) p->slots[i]=-1;
    int r=neo_checkpoint_save(c,&p->meta);if(r) {free(p);return r;}
    const void *original[8]={0};
    for(int i=0;i<8;i++) {
        Dav1dPicture *pic=&p->meta->refs[i].p.p;
        if(!pic->data[0])continue;
        if(p->meta->refs[i].p.progress || pic->m.user_data.ref ||
           pic->content_light_ref || pic->mastering_display_ref || pic->itut_t35_ref) {
            r=DAV1D_ERR(EINVAL);goto fail;
        }
        unsigned j=0;for(;j<p->count;j++) if(original[j]==pic->allocator_data)break;
        if(j==p->count) {
            original[j]=pic->allocator_data;p->count++;
            r=encode(&p->images[j],pic);if(r)goto fail;
        }
        p->slots[i]=(int)j;
    }
    for(int i=0;i<8;i++) {
        Dav1dPicture *pic=&p->meta->refs[i].p.p;
        /* Keep header/property refs but release ownership of all pixel
         * buffers/contexts. No decoded image is hidden in the packed state. */
        dav1d_ref_dec(&pic->ref);
        memset(pic->data,0,sizeof(pic->data));pic->allocator_data=NULL;
        p->meta->refs[i].p.progress=NULL;
    }
    *out=p;return 0;
fail:
    neo_packed_free(&p);return r;
}
void neo_packed_free(NeoPackedCheckpoint **saved) {
    if(!saved || !*saved)return;
    NeoPackedCheckpoint *p=*saved;*saved=NULL;
    if(p->meta) {
        /* Also releases metadata for pictures whose pixel reference was
         * intentionally detached; the original destructor skips those. */
        for(int i=0;i<8;i++) dav1d_thread_picture_unref(&p->meta->refs[i].p);
        neo_checkpoint_free(&p->meta);
    }
    for(unsigned i=0;i<p->count;i++)free(p->images[i].bytes);
    free(p);
}
int neo_packed_restore(Dav1dContext *c,const NeoPackedCheckpoint *p) {
    if(!p || !p->meta || p->meta->owner!=c || !boundary(c))return DAV1D_ERR(EINVAL);
    Dav1dThreadPicture images[8]={0};
    int r=neo_checkpoint_restore(c,p->meta);if(r)return r;
    for(unsigned j=0;j<p->count;j++) {
        int slot=0;while(slot<8 && p->slots[slot]!=(int)j)slot++;
        if(slot==8) {r=DAV1D_ERR(EINVAL);goto done;}
        r=neo_packed_picture_allocate(c,&images[j],&p->meta->refs[slot].p);if(r)goto done;
        const PackedImage *im=&p->images[j];
        Dav1dPicture *pic=&images[j].p;
        const Dav1dMemPoolBuffer *b=(const void *)((const uint8_t *)pic->allocator_data-64);
        if(b->size!=im->raw_size || memcmp(pic->stride,im->stride,sizeof(im->stride))) {r=DAV1D_ERR(EINVAL);goto done;}
        for(int plane=0;plane<planes(im);plane++) if((const uint8_t *)pic->data[plane]-(const uint8_t *)pic->allocator_data!=(ptrdiff_t)im->offset[plane]) {r=DAV1D_ERR(EINVAL);goto done;}
        decode(im,pic->allocator_data);
    }
    for(int i=0;i<8;i++) if(p->slots[i]>=0) {
        const Dav1dPicture *im=&images[p->slots[i]].p;
        Dav1dThreadPicture *dst=&c->refs[i].p;
        dav1d_thread_picture_ref(dst,&p->meta->refs[i].p);
        dst->p.ref=im->ref;dav1d_ref_inc(dst->p.ref);
        memcpy(dst->p.data,im->data,sizeof(im->data));
        memcpy(dst->p.stride,im->stride,sizeof(im->stride));dst->p.allocator_data=im->allocator_data;
    }
done:
    for(unsigned j=0;j<p->count;j++) dav1d_thread_picture_unref(&images[j]);
    if(r) dav1d_flush(c);
    return r;
}
void neo_packed_stats(const NeoPackedCheckpoint *p,NeoPackedStats *out) {
    memset(out,0,sizeof(*out));if(!p)return;
    Accounting a={0};out->state_bytes=sizeof(*p)+sizeof(*p->meta);out->unique_pictures=p->count;
    out->pixel_references_detached=1;
    account_ref(&a,p->meta->seq_ref);
    for(int i=0;i<8;i++) {
        const Dav1dPicture *pic=&p->meta->refs[i].p.p;
        if(pic->ref || pic->data[0] || pic->allocator_data)out->pixel_references_detached=0;
        account_ref(&a,pic->frame_hdr_ref);account_ref(&a,pic->seq_hdr_ref);
        account_ref(&a,p->meta->refs[i].segmap);account_ref(&a,p->meta->refs[i].refmvs);
        account_ref(&a,p->meta->cdf[i].ref);
    }
    for(unsigned i=0;i<p->count;i++)out->pixel_bytes+=p->images[i].size;
    out->metadata_bytes=a.bytes;
    out->total_bytes=out->state_bytes+out->metadata_bytes+out->pixel_bytes;
}
int neo_packed_verify_buffers(Dav1dContext *c,const NeoPackedCheckpoint *p) {
    for(unsigned j=0;j<p->count;j++) {
        int slot=0;while(slot<8 && p->slots[slot]!=(int)j)slot++;
        if(slot==8 || !c->refs[slot].p.p.data[0])return DAV1D_ERR(EINVAL);
        uint8_t *tmp=malloc(p->images[j].raw_size);if(!tmp)return DAV1D_ERR(ENOMEM);
        decode(&p->images[j],tmp);
        int mismatch=memcmp(tmp,c->refs[slot].p.p.allocator_data,p->images[j].raw_size);
        free(tmp);if(mismatch)return DAV1D_ERR(EINVAL);
    }
    return 0;
}
int neo_packed_codec_selftest(void) {
    for(int n=1;n<=257;n++) {
        uint16_t src[257],dst[257];uint8_t packed[322];
        for(int k=0;k<n;k++)src[k]=(uint16_t)((k*357+n*13)&1023);
        memset(dst,0,sizeof(dst));memset(packed,0xA5,sizeof(packed));
        if(pack_row(packed,src,n))return -1;
        unpack_row(dst,packed,n);if(memcmp(src,dst,n*sizeof(*src)))return -1;
    }
    uint16_t bad=1024;uint8_t bytes[2];
    return pack_row(bytes,&bad,1)<0?0:-1;
}
