#include "../vendor/vlckit/neo_preroll.h"
#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif
EXPORT bool test_av1(const uint8_t *data, size_t size, const neo_av1_preroll_config *c,
                     neo_av1_preroll_state *state)
{
    return neo_av1_preroll_droppable(data, size, c, state);
}
EXPORT bool test_hevc(const uint8_t *data, size_t size, unsigned highest)
{
    return neo_hevc_preroll_nal(data, size, highest);
}
EXPORT unsigned test_av1_analyze(const uint8_t *data, size_t size,
                                const neo_av1_preroll_config *c, neo_av1_preroll_state *state)
{
    neo_av1_preroll_frame first;
    bool drop = neo_av1_preroll_analyze(data, size, c, state, &first);
    return (unsigned)drop | ((unsigned)first.valid << 1) |
           ((unsigned)first.existing << 2) | (first.type << 3);
}
