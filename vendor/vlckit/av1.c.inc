/* AV1 support for VLC's VideoToolbox decoder.
 * Copyright (C) 2026 NeoEPGStation contributors
 * SPDX-License-Identifier: LGPL-2.1-or-later
 * Included by modules/codec/videotoolbox/decoder.c in the pinned VLC source.
 */
#include "../../packetizer/av1_obu.h"
#include <pthread.h>

struct vt_av1_context
{
    av1_OBU_sequence_header_t *sequence;
    uint8_t *config;
    size_t config_size;
    neo_av1_preroll_state preroll_state;
    bool preroll_droppable;
    neo_av1_preroll_frame frame;
};

static pthread_once_t av1_support_once = PTHREAD_ONCE_INIT;
static bool av1_hardware_supported;

static void QueryAV1HardwareSupport(void)
{
    if (__builtin_available(macOS 14.0, iOS 17.0, tvOS 17.0, *))
        av1_hardware_supported = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);
}

static bool DeviceSupportsAV1(decoder_t *dec)
{
    /* The app supplies its cached OS capability. Standalone VLC callers use
     * the same cheap OS query once, never a trial decode or a session per seek. */
    const int policy = var_InheritInteger(dec, "videotoolbox-av1-hardware");
    if (policy == 0)
        return false;
    pthread_once(&av1_support_once, QueryAV1HardwareSupport);
    return av1_hardware_supported;
}

static bool AV1Main420(const av1_OBU_sequence_header_t *sequence)
{
    int profile, level, tier;
    AV1_get_profile_level(sequence, &profile, &level, &tier);
    const vlc_fourcc_t chroma = AV1_get_chroma(sequence);
    return profile == 0 && (chroma == VLC_CODEC_I420 || chroma == VLC_CODEC_I420_10L);
}

static void CleanAV1(void *opaque)
{
    struct vt_av1_context *ctx = opaque;
    if (!ctx)
        return;
    if (ctx->sequence)
        AV1_release_sequence_header(ctx->sequence);
    free(ctx->config);
    free(ctx);
}

static bool InitAV1(decoder_t *dec)
{
    decoder_sys_t *sys = dec->p_sys;
    const uint8_t *extra = dec->fmt_in->p_extra;
    const size_t size = dec->fmt_in->i_extra;
    /* av1C v1, Main profile, no twelve-bit or monochrome. Missing/unsupported
     * configuration falls straight through to dav1d before playback starts. */
    if (!extra || size <= 4 || extra[0] != 0x81 || (extra[1] >> 5) != 0 ||
        (extra[2] & 0x30) || (extra[2] & 0x0c) != 0x0c)
        goto unsupported;

    struct vt_av1_context *ctx = calloc(1, sizeof(*ctx));
    if (!ctx)
        return false;
    AV1_OBU_iterator_ctx_t iterator;
    AV1_OBU_iterator_init(&iterator, extra + 4, size - 4);
    const uint8_t *obu; size_t length;
    while (AV1_OBU_iterate_next(&iterator, &obu, &length))
    {
        if (AV1_OBUGetType(obu) == AV1_OBU_SEQUENCE_HEADER)
        {
            ctx->sequence = AV1_OBU_parse_sequence_header(obu, length);
            break;
        }
    }
    if (!ctx->sequence || !AV1Main420(ctx->sequence))
    {
        CleanAV1(ctx);
        goto unsupported;
    }
    ctx->config = malloc(size);
    if (!ctx->config)
    {
        CleanAV1(ctx);
        return false;
    }
    memcpy(ctx->config, extra, size);
    ctx->config_size = size;
    sys->p_codec_context = ctx;
    return true;
unsupported:
    msg_Dbg(dec, "neo-av1-selection fallback=1");
    return false;
}

static CFDictionaryRef CopyDecoderExtradataAV1(decoder_t *dec)
{
    struct vt_av1_context *ctx = ((decoder_sys_t *)dec->p_sys)->p_codec_context;
    return ExtradataInfoCreate(CFSTR("av1C"), ctx->config, ctx->config_size);
}

static bool ConfigureVoutAV1(decoder_t *dec)
{
    decoder_sys_t *sys = dec->p_sys;
    struct vt_av1_context *ctx = sys->p_codec_context;
    if (!AV1Main420(ctx->sequence))
        return false;
    AV1_get_frame_max_dimensions(ctx->sequence, &dec->fmt_out.video.i_width,
                                 &dec->fmt_out.video.i_height);
    dec->fmt_out.video.i_visible_width = dec->fmt_out.video.i_width;
    dec->fmt_out.video.i_visible_height = dec->fmt_out.video.i_height;
    AV1_get_colorimetry(ctx->sequence, &dec->fmt_out.video.primaries,
                        &dec->fmt_out.video.transfer, &dec->fmt_out.video.space,
                        &dec->fmt_out.video.color_range);
    if (!sys->b_cvpx_format_forced)
        sys->i_cvpx_format = GetBestChroma(1,
            AV1_get_chroma(ctx->sequence) == VLC_CODEC_I420 ? 8 : 10,
            AV1_get_chroma(ctx->sequence) == VLC_CODEC_I420 ? 8 : 10);
    return dec->fmt_out.video.i_width > 0 && dec->fmt_out.video.i_height > 0;
}

static block_t *ProcessBlockAV1(decoder_t *dec, block_t *block, bool *changed)
{
    decoder_sys_t *sys = dec->p_sys;
    struct vt_av1_context *ctx = sys->p_codec_context;
    AV1_OBU_iterator_ctx_t iterator;
    AV1_OBU_iterator_init(&iterator, block->p_buffer, block->i_buffer);
    const uint8_t *obu; size_t length;
    while (AV1_OBU_iterate_next(&iterator, &obu, &length))
    {
        if (AV1_OBUGetType(obu) != AV1_OBU_SEQUENCE_HEADER)
            continue;
        av1_OBU_sequence_header_t *sequence = AV1_OBU_parse_sequence_header(obu, length);
        if (!sequence)
            continue;
        if (!AV1_sequence_header_equal(ctx->sequence, sequence))
        {
            uint8_t *config = NULL;
            size_t size = AV1_create_DecoderConfigurationRecord(&config, sequence, 1, &obu, &length);
            if (!size || !config)
            {
                free(config);
                AV1_release_sequence_header(sequence);
                block_Release(block);
                return NULL;
            }
            AV1_release_sequence_header(ctx->sequence);
            free(ctx->config);
            ctx->sequence = sequence;
            ctx->config = config;
            ctx->config_size = size;
            *changed = true;
        }
        else
            AV1_release_sequence_header(sequence);
        break;
    }
    neo_av1_preroll_config config;
    ctx->frame = (neo_av1_preroll_frame){0};
    ctx->preroll_droppable = AV1_get_preroll_config(ctx->sequence, &config) &&
        neo_av1_preroll_analyze(block->p_buffer, block->i_buffer, &config, &ctx->preroll_state, &ctx->frame);
    return block;
}

static void FlushAV1(decoder_t *dec)
{
    struct vt_av1_context *ctx = ((decoder_sys_t *)dec->p_sys)->p_codec_context;
    ctx->preroll_state.known = 0;
    ctx->preroll_droppable = false;
    ctx->frame = (neo_av1_preroll_frame){0};
}

static bool VideoToolboxNeedsToRestartAV1(decoder_t *dec, VTDecompressionSessionRef session)
{
    VLC_UNUSED(dec); VLC_UNUSED(session);
    return true; /* A changed sequence header needs a new av1C format. */
}

static bool FillReorderInfoAV1(decoder_t *dec, const block_t *block, frame_info_t *info)
{
    struct vt_av1_context *ctx = ((decoder_sys_t *)dec->p_sys)->p_codec_context;
    info->b_keyframe = (block->i_flags & BLOCK_FLAG_TYPE_I) != 0;
    /* ProcessBlock already parsed the first frame header while maintaining
     * the reference map. Share that result instead of walking/parsing again.
     * show_existing_frame has no frame_type bits; it must not become KEY. */
    if (ctx->frame.valid)
        info->b_keyframe = !ctx->frame.existing && ctx->frame.type == AV1_FRAME_TYPE_KEY;
    info->b_flush = info->b_keyframe;
    info->b_progressive = true;
    info->i_num_ts = 2;
    /* AV1 temporal units already have presentation order. VT owns the eight
     * reference slots, so don't add an H.264/HEVC POC queue in front of VLC. */
    info->i_max_pics_buffering = 1;
    return true;
}
