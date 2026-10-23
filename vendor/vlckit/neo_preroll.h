/* Conservative decoder-only preroll classifiers.
 * Copyright (C) 2026 NeoEPGStation contributors
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#ifndef NEO_PREROLL_H
#define NEO_PREROLL_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    bool reduced_still, decoder_model, frame_ids;
    unsigned operating_points_minus1, screen_tools, integer_mv, order_hint_bits;
} neo_av1_preroll_config;

typedef struct {
    const uint8_t *data;
    size_t size, bit;
    bool error;
} neo_preroll_bits;

static inline unsigned neo_preroll_read(neo_preroll_bits *b, unsigned count)
{
    if (count > 32 || b->bit > b->size * 8 || count > b->size * 8 - b->bit) {
        b->error = true;
        return 0;
    }
    unsigned value = 0;
    while (count--) {
        value = (value << 1) | ((b->data[b->bit / 8] >> (7 - b->bit % 8)) & 1);
        b->bit++;
    }
    return value;
}

/* Frame IDs, decoder models and scalability require additional persistent
 * state. Leave those streams untouched rather than approximating it. */
typedef struct { uint8_t types[8], known; } neo_av1_preroll_state;
typedef struct {
    unsigned type, refresh, index;
    bool valid, existing, show, error_resilient;
} neo_av1_preroll_frame;

static inline neo_av1_preroll_frame neo_av1_preroll_header(
    const uint8_t *data, size_t size, const neo_av1_preroll_config *c)
{
    neo_av1_preroll_frame f = {0};
    if (!c || c->reduced_still || c->decoder_model || c->frame_ids ||
        c->operating_points_minus1 || c->screen_tools > 2 || c->integer_mv > 2 ||
        c->order_hint_bits > 8 || size > SIZE_MAX / 8)
        return f;
    neo_preroll_bits b = { data, size, 0, false };
    f.existing = neo_preroll_read(&b, 1);
    if (f.existing) {
        f.index = neo_preroll_read(&b, 3);
        f.valid = !b.error;
        return f;
    }
    f.type = neo_preroll_read(&b, 2);
    f.show = neo_preroll_read(&b, 1);
    if (!f.show) (void)neo_preroll_read(&b, 1); /* showable_frame */
    f.error_resilient = f.type == 3 || (f.type == 0 && f.show) ? true : neo_preroll_read(&b, 1);
    (void)neo_preroll_read(&b, 1); /* disable_cdf_update */
    unsigned screen = c->screen_tools == 2 ? neo_preroll_read(&b, 1) : c->screen_tools;
    if (screen && c->integer_mv == 2) (void)neo_preroll_read(&b, 1);
    if (f.type != 3) (void)neo_preroll_read(&b, 1); /* frame_size_override_flag */
    (void)neo_preroll_read(&b, c->order_hint_bits);
    if (f.type == 1 && !f.error_resilient) (void)neo_preroll_read(&b, 3); /* primary_ref_frame */
    f.refresh = f.type == 3 || (f.type == 0 && f.show) ? 255 : neo_preroll_read(&b, 8);
    f.valid = !b.error;
    return f;
}

/* Keep the reference-slot TYPES, not decoded pictures. A show-existing of an
 * inter picture has no reference/CDF update; a show-existing KEY refreshes
 * every slot and must still go to VT. Update this map during normal playback
 * as well as preroll, and reset it on every decoder flush/sequence change. */
static inline bool neo_av1_preroll_update(neo_av1_preroll_state *state,
                                         neo_av1_preroll_frame f)
{
    if (!f.valid) { state->known = 0; return false; }
    if (f.existing) {
        if (!(state->known & (1u << f.index))) return false;
        if (state->types[f.index] != 0) return true;
        for (unsigned i = 0; i < 8; i++) state->types[i] = 0;
        state->known = 255;
        return false;
    }
    if (f.error_resilient && !(f.type == 0 && f.show)) state->known = 0;
    for (unsigned i = 0; i < 8; i++) {
        if (f.refresh & (1u << i)) {
            state->types[i] = (uint8_t)f.type;
            state->known |= (uint8_t)(1u << i);
        }
    }
    return f.type == 1 && f.show && !f.error_resilient && f.refresh == 0;
}

/* One complete temporal unit only. Preserve all metadata and mixed-frame
 * units. Even a unit we cannot skip must update reference-slot bookkeeping. */
static inline bool neo_av1_preroll_invalid(neo_av1_preroll_state *state,
                                         neo_av1_preroll_frame *first)
{
    state->known = 0;
    if (first) first->valid = false;
    return false;
}
static inline bool neo_av1_preroll_analyze(const uint8_t *data, size_t size,
                                            const neo_av1_preroll_config *c,
                                            neo_av1_preroll_state *state,
                                            neo_av1_preroll_frame *first)
{
    if (first) *first = (neo_av1_preroll_frame){0};
    unsigned frames = 0;
    bool droppable = false, safe_unit = true;
    while (size) {
        uint8_t header = *data++; size--;
        if (header & 0x81) return neo_av1_preroll_invalid(state, first);
        unsigned type = (header >> 3) & 15;
        bool base_layer = true;
        if (header & 4) {
            if (!size) return neo_av1_preroll_invalid(state, first);
            base_layer = *data++ == 0; size--;
        }
        uint64_t length = size;
        if (header & 2) {
            length = 0;
            unsigned shift = 0;
            uint8_t byte;
            do {
                if (!size || shift == 56) return neo_av1_preroll_invalid(state, first);
                byte = *data++; size--;
                length |= (uint64_t)(byte & 127) << shift;
                shift += 7;
            } while (byte & 128);
        }
        if (length > size || !base_layer) return neo_av1_preroll_invalid(state, first);
        if (type == 3 || type == 6) {
            frames++;
            neo_av1_preroll_frame frame = neo_av1_preroll_header(data, (size_t)length, c);
            if (first && frames == 1) *first = frame;
            bool can_skip = neo_av1_preroll_update(state, frame);
            droppable = frames == 1 && can_skip;
        } else if (type == 4) {
            if (!frames) { safe_unit = false; state->known = 0; }
        } else if (type == 1) {
            state->known = 0;
            safe_unit = false;
        } else if (type != 2 && type != 15) {
            safe_unit = false;
        }
        data += (size_t)length;
        size -= (size_t)length;
    }
    return safe_unit && frames == 1 && droppable;
}

static inline bool neo_av1_preroll_droppable(const uint8_t *data, size_t size,
                                            const neo_av1_preroll_config *c,
                                            neo_av1_preroll_state *state)
{
    return neo_av1_preroll_analyze(data, size, c, state, NULL);
}

/* HEVC 7.4.2.2: _N is non-reference within its temporal sublayer. Restrict
 * this to the highest SPS temporal layer so no higher-layer picture can
 * depend on it. A multilayer or malformed NAL must never be discarded. */
static inline bool neo_hevc_preroll_nal(const uint8_t *nal, size_t size,
                                       unsigned highest_temporal_id)
{
    if (size < 3 || (nal[0] & 0x80) || (nal[0] & 1) || (nal[1] & 0xf8) ||
        !(nal[1] & 7) || highest_temporal_id > 6 ||
        (unsigned)((nal[1] & 7) - 1) != highest_temporal_id)
        return false;
    unsigned type = (nal[0] >> 1) & 63;
    return type == 0 || type == 2 || type == 4 || type == 6 || type == 8;
}
#endif
