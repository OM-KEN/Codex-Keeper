#include "KeeperZstd.h"
#include "../../Vendor/zstd/zstddeclib.c"

void *keeper_zstd_stream_create(void) {
    ZSTD_DStream *stream = ZSTD_createDStream();
    if (!stream) return NULL;
    if (ZSTD_isError(ZSTD_initDStream(stream))) { ZSTD_freeDStream(stream); return NULL; }
    return stream;
}

void keeper_zstd_stream_free(void *stream) { ZSTD_freeDStream((ZSTD_DStream *)stream); }

int keeper_zstd_stream_decode(void *stream, const void *input, size_t count, size_t *consumed,
                             void *output, size_t capacity, size_t *written, size_t *remaining) {
    ZSTD_inBuffer source = {input, count, 0};
    ZSTD_outBuffer target = {output, capacity, 0};
    size_t result = ZSTD_decompressStream((ZSTD_DStream *)stream, &target, &source);
    *consumed = source.pos; *written = target.pos; *remaining = result;
    return ZSTD_isError(result) ? 1 : 0;
}
