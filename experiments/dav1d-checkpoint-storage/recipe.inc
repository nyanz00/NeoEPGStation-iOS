/* Conservative frame-header dependency trace. Header-only stubs are a private
 * replay format, NOT a valid ordinary AV1 stream or new independent keyframe. */
#define STORAGE_NODES 4096
#define STORAGE_OBUS 16384
typedef struct Node {int dependencies[8],n;int64_t packet;} Node;
typedef struct Entry {uint8_t *bytes;size_t size,header,payload;int node,type;int64_t packet;} Entry;
typedef struct RecipePacket {uint8_t *bytes;size_t size;int64_t index;} RecipePacket;
struct NeoTrace {
    Dav1dContext *owner;
    Node nodes[STORAGE_NODES];int count,slots[8],current;
    Entry *entries;size_t entry_count;
};
struct NeoRecipe {
    Dav1dContext *owner;
    uint8_t *keep;int count,cursor,slots[8],current;
    RecipePacket *packets;size_t packet_count,bytes,selected,original;
};
static NeoTrace *storage_trace;
static NeoRecipe *storage_replay;
static int add_entry(NeoTrace *t,const Dav1dData *in,int type,int node,
                     const uint8_t *start,const uint8_t *header,const uint8_t *end) {
    if(t->entry_count>=STORAGE_OBUS)return -1;
    Entry *entries=realloc(t->entries,(t->entry_count+1)*sizeof(*entries));if(!entries)return -1;t->entries=entries;
    Entry *e=&t->entries[t->entry_count++];memset(e,0,sizeof(*e));
    e->size=(size_t)(end-start);e->header=header?(size_t)(header-start):e->size;
    e->bytes=malloc(e->size);if(!e->bytes)return -1;memcpy(e->bytes,start,e->size);
    e->type=type;e->node=node;e->packet=in->m.offset;
    size_t at=1+!!(start[0]&4);
    if(start[0]&2) {while(at<e->size && (start[at++]&128)) {}}
    e->payload=at;
    return 0;
}
static void node_dep(Node *n,int id) {
    if(id<0)return;
    for(int j=0;j<n->n;j++)if(n->dependencies[j]==id)return;
    if(n->n<8)n->dependencies[n->n++]=id;
}
int neo_storage_header(Dav1dContext *c,const Dav1dData *in,int type,
                       const uint8_t *start,const uint8_t *header,const uint8_t *end) {
    NeoTrace *t=storage_trace && storage_trace->owner==c?storage_trace:NULL;
    NeoRecipe *r=storage_replay && storage_replay->owner==c?storage_replay:NULL;
    if(!t && !r)return 0;
    Dav1dFrameHeader *h=c->frame_hdr;int *slots=t?t->slots:r->slots;
    if(h->show_existing_frame) {
        int id=slots[h->existing_frame_idx];
        if(t && add_entry(t,in,type,-1,start,NULL,end))return -1;
        if(c->refs[h->existing_frame_idx].p.p.frame_hdr &&
           c->refs[h->existing_frame_idx].p.p.frame_hdr->frame_type==DAV1D_FRAME_TYPE_KEY)
            for(int j=0;j<8;j++)slots[j]=id;
        return r && (id<0 || !r->keep[id])?1:0;
    }
    int id=t?t->count:r->cursor;
    if(id>=STORAGE_NODES || (r && id>=r->count))return -1;
    if(t) {
        Node *n=&t->nodes[id];n->packet=in->m.offset;
        if(h->frame_type==DAV1D_FRAME_TYPE_INTER || h->frame_type==DAV1D_FRAME_TYPE_SWITCH)
            for(int j=0;j<7;j++)node_dep(n,slots[h->refidx[j]]);
        if(h->primary_ref_frame!=DAV1D_PRIMARY_REF_NONE)node_dep(n,slots[h->refidx[h->primary_ref_frame]]);
        /* Grain copying can refer outside the seven pixel prediction slots. */
        if(c->seq_hdr->film_grain_present)for(int j=0;j<8;j++)node_dep(n,slots[j]);
        if(add_entry(t,in,type,id,start,header,end))return -1;
        t->count++;t->current=id;
    } else {r->cursor++;r->current=id;}
    for(int j=0;j<8;j++)if(h->refresh_frame_flags&(1<<j))slots[j]=id;
    return r && !r->keep[id]?1:0;
}
int neo_storage_obu(Dav1dContext *c,const Dav1dData *in,int type,const uint8_t *start,const uint8_t *end) {
    if(type==DAV1D_OBU_FRAME || type==DAV1D_OBU_FRAME_HDR || type==DAV1D_OBU_REDUNDANT_FRAME_HDR)return 0;
    if(storage_trace && storage_trace->owner==c) {
        int id=type==DAV1D_OBU_TILE_GRP?storage_trace->current:-1;
        return add_entry(storage_trace,in,type,id,start,NULL,end)?-1:0;
    }
    if(storage_replay && storage_replay->owner==c && type==DAV1D_OBU_TILE_GRP)
        return storage_replay->current<0 || !storage_replay->keep[storage_replay->current]?1:0;
    return 0;
}
NeoTrace *neo_trace_start(Dav1dContext *c) {
    if(storage_trace || storage_replay)return NULL;
    NeoTrace *t=calloc(1,sizeof(*t));if(!t)return NULL;t->owner=c;t->current=-1;
    for(int j=0;j<8;j++)t->slots[j]=-1;
    storage_trace=t;return t;
}
void neo_trace_stop(NeoTrace *t) {if(storage_trace==t)storage_trace=NULL;}
void neo_trace_free(NeoTrace **ptr) {
    if(!ptr || !*ptr)return;NeoTrace *t=*ptr;*ptr=NULL;neo_trace_stop(t);
    for(size_t i=0;i<t->entry_count;i++)free(t->entries[i].bytes);
    free(t->entries);free(t);
}
static void mark_needed(const NeoTrace *t,uint8_t *keep,int id) {
    if(id<0 || keep[id])return;
    keep[id]=1;for(int j=0;j<t->nodes[id].n;j++)mark_needed(t,keep,t->nodes[id].dependencies[j]);
}
NeoRecipe *neo_recipe_build(NeoTrace *t,size_t packet_limit) {
    NeoRecipe *r=calloc(1,sizeof(*r));if(!r)return NULL;r->count=t->count;
    r->keep=calloc((size_t)t->count,1);if(!r->keep)goto error;
    for(int j=0;j<8;j++)mark_needed(t,r->keep,t->slots[j]);
    r->original=(size_t)t->count;
    for(int j=0;j<t->count;j++)r->selected+=r->keep[j];
    r->packets=calloc(packet_limit,sizeof(*r->packets));if(!r->packets)goto error;
    r->packet_count=packet_limit;
    for(size_t j=0;j<packet_limit;j++)r->packets[j].index=(int64_t)j;
    for(size_t j=0;j<t->entry_count;j++) {
        Entry *e=&t->entries[j];if(e->packet<0 || (size_t)e->packet>=packet_limit)goto error;
        int selected=e->node<0 || r->keep[e->node];
        if(!selected && e->type==DAV1D_OBU_TILE_GRP)continue;
        uint8_t header[16];const uint8_t *part=e->bytes;size_t n=e->size,h=0;
        if(!selected && e->type==DAV1D_OBU_FRAME) {
            size_t prefix=1+!!(e->bytes[0]&4);memcpy(header,e->bytes,prefix);header[0]|=2;h=prefix;
            size_t length=e->header-e->payload;
            do {header[h++]=(uint8_t)((length&127)|(length>127?128:0));length>>=7;}while(length);
            part=e->bytes+e->payload;n=e->header-e->payload;
        }
        RecipePacket *p=&r->packets[e->packet];uint8_t *bytes=realloc(p->bytes,p->size+h+n);if(!bytes)goto error;p->bytes=bytes;
        if(h)memcpy(bytes+p->size,header,h);memcpy(bytes+p->size+h,part,n);p->size+=h+n;r->bytes+=h+n;
    }
    return r;
error:
    neo_recipe_free(&r);return NULL;
}
void neo_recipe_free(NeoRecipe **ptr) {
    if(!ptr || !*ptr)return;NeoRecipe *r=*ptr;*ptr=NULL;neo_recipe_stop(r);
    for(size_t j=0;j<r->packet_count;j++)free(r->packets[j].bytes);
    free(r->packets);free(r->keep);free(r);
}
void neo_recipe_start(NeoRecipe *r,Dav1dContext *c) {
    r->owner=c;r->cursor=0;r->current=-1;for(int j=0;j<8;j++)r->slots[j]=-1;storage_replay=r;
}
void neo_recipe_stop(NeoRecipe *r) {if(storage_replay==r)storage_replay=NULL;if(r)r->owner=NULL;}
size_t neo_recipe_count(const NeoRecipe *r) {return r->packet_count;}
const uint8_t *neo_recipe_packet(const NeoRecipe *r,size_t n,size_t *size,int64_t *index) {
    *size=r->packets[n].size;*index=r->packets[n].index;return r->packets[n].bytes;
}
void neo_recipe_stats(const NeoRecipe *r,size_t *held,size_t *payload,size_t *selected,size_t *original) {
    *held=sizeof(*r)+(size_t)r->count+r->packet_count*sizeof(*r->packets)+r->bytes;
    *payload=r->bytes;*selected=r->selected;*original=r->original;
}
int neo_recipe_verify_refs(Dav1dContext *a,Dav1dContext *b) {
    for(int j=0;j<8;j++) {
        const Dav1dPicture *p=&a->refs[j].p.p,*q=&b->refs[j].p.p;
        if(!p->data[0] || !q->data[0]) {if(p->data[0]!=q->data[0])return -1;continue;}
        if(p->p.w!=q->p.w || p->p.h!=q->p.h || p->p.bpc!=q->p.bpc || p->p.layout!=q->p.layout)return -1;
        if(p->frame_hdr->frame_offset!=q->frame_hdr->frame_offset || p->m.offset!=q->m.offset)return -1;
        int count=p->p.layout==DAV1D_PIXEL_LAYOUT_I400?1:3;
        for(int pl=0;pl<count;pl++) {
            int hs=pl && p->p.layout!=DAV1D_PIXEL_LAYOUT_I444,vs=pl && p->p.layout==DAV1D_PIXEL_LAYOUT_I420;
            int w=(p->p.w+((1<<hs)-1))>>hs,h=(p->p.h+((1<<vs)-1))>>vs;
            for(int y=0;y<h;y++)if(memcmp((uint8_t*)p->data[pl]+y*p->stride[pl?1:0],
                (uint8_t*)q->data[pl]+y*q->stride[pl?1:0],(size_t)w*(p->p.bpc>8?2:1)))return -1;
        }
    }
    return 0;
}
