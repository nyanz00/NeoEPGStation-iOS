/* Included after the exact MT packed implementation, so geometry/allocator and
 * state lifetime match the tested checkpoint. All padding bytes are preserved. */
#include "neo_compression_namespace.h"
#include "lz4.h"
#include <zstd.h>
#include "lossless.h"
#include "rcomp.h"
#include "lscomp.h"
struct NeoLosslessCheckpoint {
    NeoPackedCheckpoint *shell;
    size_t stage[8];
    int method;
};
typedef struct NeoLosslessCheckpoint Stored;
const char *neo_lossless_name(int m) {
    static const char *names[9]={"packed10","raw-lz4","packed10-lz4",
        "horizontal-delta-lz4","shuffled-delta-lz4","raw-zstd1","packed10-zstd1",
        "shuffled-delta-zstd1","block32-min-bitpack"};
    return m==11?"lscomp-cpu-raw":m==12?"lscomp-metal-raw":m==13?"lscomp-cpu-delta":m==14?"lscomp-metal-delta":m==9?"cpu-lz4-64k":m==10?"rcomp-metal-lz4-64k":m>=0 && m<9?names[m]:"invalid";
}
static void geometry(PackedImage *im,const Dav1dPicture *p) {
    memset(im,0,sizeof(*im));im->w=p->p.w;im->h=p->p.h;im->bpc=p->p.bpc;im->layout=p->p.layout;
    memcpy(im->stride,p->stride,sizeof(im->stride));
    const Dav1dMemPoolBuffer *block=(const void *)((const uint8_t*)p->allocator_data-64);
    im->raw_size=block->size;
    for(int pl=0;pl<planes(im);pl++)im->offset[pl]=(const uint8_t*)p->data[pl]-(const uint8_t*)p->allocator_data;
}
static void delta_rows(const PackedImage *im,uint8_t *buf,int undo,int shuffle) {
    for(int pl=0;pl<planes(im);pl++)for(int y=0;y<height(im,pl);y++) {
        int w=width(im,pl);uint8_t *row=buf+im->offset[pl]+(size_t)y*im->stride[pl?1:0];
        if(im->bpc==8) {
            int previous=0;
            for(int x=0;x<w;x++) {
                if(undo) {int z=row[x];previous=(previous+((z>>1)^-(z&1)))&255;row[x]=(uint8_t)previous;}
                else {int current=row[x],d=(int8_t)(current-previous);previous=current;row[x]=(uint8_t)(d>=0?2*d:-2*d-1);}
            }
            continue;
        }
        uint16_t *v=(uint16_t*)row;
        uint8_t tmp[8192]; /* experiment limited to 1920 pixels */
        if(undo && shuffle) {
            memcpy(tmp,row,2*(size_t)w);
            for(int x=0;x<w;x++)v[x]=(uint16_t)(tmp[x]|(unsigned)tmp[w+x]<<8);
        }
        int previous=0;
        for(int x=0;x<w;x++) {
            if(undo) {int z=v[x];previous+=(z>>1)^-(z&1);v[x]=(uint16_t)previous;}
            else {int current=v[x],d=current-previous;previous=current;v[x]=(uint16_t)(d>=0?2*d:-2*d-1);}
        }
        if(!undo && shuffle) {
            for(int x=0;x<w;x++) {tmp[x]=(uint8_t)v[x];tmp[w+x]=(uint8_t)(v[x]>>8);}
            memcpy(row,tmp,2*(size_t)w);
        }
    }
}
static size_t block_encode(const PackedImage *im,const uint8_t *raw,uint8_t *out) {
    size_t cursor=0,n=0;
    for(int pl=0;pl<planes(im);pl++)for(int y=0;y<height(im,pl);y++) {
        int w=width(im,pl);size_t start=im->offset[pl]+(size_t)y*im->stride[pl?1:0];
        memcpy(out+n,raw+cursor,start-cursor);n+=start-cursor;
        const uint16_t *v=(const uint16_t*)(raw+start);
        for(int x=0;x<w;x+=32) {
            int count=w-x<32?w-x:32;unsigned low=65535,high=0;
            for(int k=0;k<count;k++) {if(v[x+k]<low)low=v[x+k];if(v[x+k]>high)high=v[x+k];}
            unsigned bits=0;while((high-low)>>bits)bits++;
            out[n++]=(uint8_t)low;out[n++]=(uint8_t)(low>>8);out[n++]=(uint8_t)bits;
            unsigned pending=0,value=0;
            for(int k=0;k<count;k++) {
                value|=(unsigned)(v[x+k]-low)<<pending;pending+=bits;
                while(pending>=8) {out[n++]=(uint8_t)value;value>>=8;pending-=8;}
            }
            if(pending)out[n++]=(uint8_t)value;
        }
        cursor=start+2*(size_t)w;
    }
    memcpy(out+n,raw+cursor,im->raw_size-cursor);return n+im->raw_size-cursor;
}
static void block_decode(const PackedImage *im,const uint8_t *in,uint8_t *raw) {
    size_t cursor=0,n=0;
    for(int pl=0;pl<planes(im);pl++)for(int y=0;y<height(im,pl);y++) {
        int w=width(im,pl);size_t start=im->offset[pl]+(size_t)y*im->stride[pl?1:0];
        memcpy(raw+cursor,in+n,start-cursor);n+=start-cursor;
        uint16_t *v=(uint16_t*)(raw+start);
        for(int x=0;x<w;x+=32) {
            int count=w-x<32?w-x:32;unsigned low=in[n]|(unsigned)in[n+1]<<8,bits=in[n+2];n+=3;
            unsigned pending=0,value=0;
            for(int k=0;k<count;k++) {
                while(pending<bits) {value|=(unsigned)in[n++]<<pending;pending+=8;}
                v[x+k]=(uint16_t)(low+(value&((1U<<bits)-1)));value>>=bits;pending-=bits;
            }
        }
        cursor=start+2*(size_t)w;
    }
    memcpy(raw+cursor,in+n,im->raw_size-cursor);
}
static int image_store(PackedImage *im,size_t *stage,const Dav1dPicture *p,int method) {
    if((p->p.bpc!=10 && p->p.bpc!=8) || p->p.w>1920)return DAV1D_ERR(EINVAL);
    if(method==0)return encode(im,p);
    const uint8_t *raw=p->allocator_data;uint8_t *input=NULL;
    if(method==2 || method==6) {int e=encode(im,p);if(e)return e;input=im->bytes;im->bytes=NULL;*stage=im->size;}
    else {
        geometry(im,p);*stage=im->raw_size;
        if(method==8) {
            im->bytes=malloc(im->raw_size*2);if(!im->bytes)return DAV1D_ERR(ENOMEM);
            im->size=block_encode(im,raw,im->bytes);
            uint8_t *small=realloc(im->bytes,im->size);if(small)im->bytes=small;
            return 0;
        }
        input=malloc(*stage);if(!input)return DAV1D_ERR(ENOMEM);memcpy(input,raw,*stage);
        if(method==3 || method==4 || method==7)delta_rows(im,input,0,method!=3);
    }
    size_t bound=method>=5?ZSTD_compressBound(*stage):(size_t)LZ4_compressBound((int)*stage);
    im->bytes=malloc(bound);if(!im->bytes) {free(input);return DAV1D_ERR(ENOMEM);}
    if(method>=5) {im->size=ZSTD_compress(im->bytes,bound,input,*stage,1);if(ZSTD_isError(im->size))im->size=0;}
    else im->size=(size_t)LZ4_compress_default((const char*)input,(char*)im->bytes,(int)*stage,(int)bound);
    free(input);if(!im->size)return DAV1D_ERR(EINVAL);
    uint8_t *small=realloc(im->bytes,im->size);if(small)im->bytes=small;
    return 0;
}
static int image_restore(const PackedImage *im,size_t stage,int method,uint8_t *raw) {
    if(method==0) {decode(im,raw);return 0;}
    if(method>=11 && method<=14) {int e=neo_lscomp_unpack(im->bytes,im->size,raw,im->raw_size);if(!e && method>=13)delta_rows(im,raw,1,0);return e;}
    if(method==9 || method==10) {int e=neo_rcomp_unpack(im->bytes,im->size,raw,im->raw_size);if(!e)delta_rows(im,raw,1,1);return e;}
    if(method==8) {block_decode(im,im->bytes,raw);return 0;}
    int packed=method==2 || method==6;uint8_t *dest=packed?malloc(stage):raw;
    if(!dest)return DAV1D_ERR(ENOMEM);
    size_t n;
    if(method>=5) n=ZSTD_decompress(dest,stage,im->bytes,im->size);
    else {int v=LZ4_decompress_safe((const char*)im->bytes,(char*)dest,(int)im->size,(int)stage);n=v<0?SIZE_MAX:(size_t)v;}
    int e=n==stage?0:DAV1D_ERR(EINVAL);
    if(!e && packed) {PackedImage view=*im;view.bytes=dest;decode(&view,raw);}
    if(!e && (method==3 || method==4 || method==7))delta_rows(im,raw,1,method!=3);
    if(packed)free(dest);return e;
}
int neo_lossless_capture(Dav1dContext *c,int method,NeoLosslessCheckpoint **out) {
    if(!out || *out || (method!=0 && method!=4 && method!=7 && method!=9 && method!=10 && method!=11 && method!=12 && method!=13 && method!=14))return DAV1D_ERR(EINVAL);
    Stored *s=calloc(1,sizeof(*s));if(!s)return DAV1D_ERR(ENOMEM);s->method=method;
    s->shell=calloc(1,sizeof(*s->shell));if(!s->shell) {free(s);return DAV1D_ERR(ENOMEM);}
    for(int i=0;i<8;i++)s->shell->slots[i]=-1;
    int e=neo_checkpoint_save(c,&s->shell->meta);
    if(e) {neo_lossless_free(&s);return e;}
    *out=s;return 0;
}
static int rcomp_store(Stored *s) {
    NeoPackedCheckpoint *p=s->shell;const void *original[8]={0};
    NeoRcompInput input[8]={{0}};NeoRcompOutput output[8]={{0}};int e=0;
    for(int i=0;i<8;i++) {
        const Dav1dPicture *pic=&p->meta->refs[i].p.p;if(!pic->data[0])continue;
        if(pic->p.w>1920 || pic->p.h>1080 || (pic->p.bpc!=8 && pic->p.bpc!=10) ||
           pic->m.user_data.ref || pic->content_light_ref || pic->mastering_display_ref || pic->itut_t35_ref) {e=DAV1D_ERR(EINVAL);goto done;}
        unsigned j=0;for(;j<p->count;j++)if(original[j]==pic->allocator_data)break;
        if(j==p->count) {
            original[j]=pic->allocator_data;p->count++;geometry(&p->images[j],pic);
            size_t n=p->images[j].raw_size;uint8_t *bytes=malloc(n);if(!bytes) {e=DAV1D_ERR(ENOMEM);goto done;}
            memcpy(bytes,pic->allocator_data,n);
            if(s->method<11 || s->method>=13)delta_rows(&p->images[j],bytes,0,s->method<11);
            unsigned word=pic->p.bpc==8?1:2;
            if(pic->stride[0]<=0 || pic->stride[0]/word>16384) {free(bytes);e=DAV1D_ERR(EINVAL);goto done;}
            input[j]=(NeoRcompInput){bytes,n,(uint32_t)(pic->stride[0]/word),word};
        }
        p->slots[i]=(int)j;
    }
    if(s->method>=11)e=neo_checkpoint_gpu_method(s->method)?neo_lscomp_gpu_pack(input,output,p->count):neo_lscomp_cpu_pack(input,output,p->count);
    else e=s->method==10?neo_rcomp_gpu_pack(input,output,p->count):neo_rcomp_cpu_pack(input,output,p->count);
    if(!e)for(unsigned j=0;j<p->count;j++) {
        p->images[j].bytes=output[j].data;p->images[j].size=output[j].size;output[j].data=NULL;
    }
done:
    for(unsigned j=0;j<8;j++) {free((void*)input[j].data);free(output[j].data);}
    return e;
}
int neo_lossless_encode(NeoLosslessCheckpoint *s) {
    if(!s || !s->shell || !s->shell->meta || s->shell->count)return DAV1D_ERR(EINVAL);
    NeoPackedCheckpoint *p=s->shell;int e=0,method=s->method;
    if(method>=9 && method<=14) {e=rcomp_store(s);if(e)return e;}
    else {
    const void *original[8]={0};
    for(int i=0;i<8;i++) {
        Dav1dPicture *pic=&p->meta->refs[i].p.p;if(!pic->data[0])continue;
        if(pic->m.user_data.ref || pic->content_light_ref || pic->mastering_display_ref || pic->itut_t35_ref)return DAV1D_ERR(EINVAL);
        unsigned j=0;for(;j<p->count;j++)if(original[j]==pic->allocator_data)break;
        if(j==p->count) {original[j]=pic->allocator_data;p->count++;e=image_store(&p->images[j],&s->stage[j],pic,method);if(e)return e;}
        p->slots[i]=(int)j;
    }
    }
    for(int i=0;i<8;i++) {
        Dav1dPicture *pic=&p->meta->refs[i].p.p;dav1d_ref_dec(&pic->ref);
        memset(pic->data,0,sizeof(pic->data));pic->allocator_data=NULL;p->meta->refs[i].p.progress=NULL;
    }
    return 0;
}
int neo_lossless_restore(Dav1dContext *c,const NeoLosslessCheckpoint *s) {
    if(!s)return DAV1D_ERR(EINVAL);
    NeoPackedCheckpoint *p=s->shell;
    if(!p || !p->meta || p->meta->owner!=c || !boundary(c))return DAV1D_ERR(EINVAL);
    Dav1dThreadPicture images[8]={0};int e=neo_checkpoint_restore(c,p->meta);if(e)return e;
    for(unsigned j=0;j<p->count;j++) {
        int slot=0;while(slot<8 && p->slots[slot]!=(int)j)slot++;
        e=neo_packed_picture_allocate(c,&images[j],&p->meta->refs[slot].p);if(e)goto done;
        const Dav1dMemPoolBuffer *block=(const void*)((const uint8_t*)images[j].p.allocator_data-64);
        if(block->size!=p->images[j].raw_size) {e=DAV1D_ERR(EINVAL);goto done;}
        e=image_restore(&p->images[j],s->stage[j],s->method,images[j].p.allocator_data);if(e)goto done;
    }
    for(int i=0;i<8;i++)if(p->slots[i]>=0) {
        Dav1dThreadPicture *dst=&c->refs[i].p;const Dav1dThreadPicture *src=&images[p->slots[i]];
        dav1d_thread_picture_ref(dst,&p->meta->refs[i].p);dst->p.ref=src->p.ref;dav1d_ref_inc(dst->p.ref);
        memcpy(dst->p.data,src->p.data,sizeof(src->p.data));memcpy(dst->p.stride,src->p.stride,sizeof(src->p.stride));
        dst->p.allocator_data=src->p.allocator_data;dst->progress=src->progress;
    }
done:
    for(unsigned j=0;j<p->count;j++)dav1d_thread_picture_unref(&images[j]);
    if(e)dav1d_flush(c);return e;
}

void neo_lossless_free(NeoLosslessCheckpoint **ptr) {
    if(!ptr || !*ptr)return;
    Stored *s=*ptr;*ptr=NULL;neo_packed_free(&s->shell);free(s);
}
void neo_lossless_stats(const NeoLosslessCheckpoint *s,NeoLosslessStats *out) {
    memset(out,0,sizeof(*out));if(!s)return;
    NeoPackedStats stats;neo_packed_stats(s->shell,&stats);
    out->held_bytes=stats.total_bytes+sizeof(*s);out->pixel_bytes=stats.pixel_bytes;out->detached=stats.pixel_references_detached;
}
