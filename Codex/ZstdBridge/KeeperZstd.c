#include "KeeperZstd.h"
#include "../../Vendor/zstd/zstddeclib.c"

int keeper_zstd_decode(const void *input, size_t count, void **output, size_t *output_count) {
    *output = NULL;
    *output_count = 0;
    ZSTD_DStream *stream = ZSTD_createDStream();
    if (!stream) return 1;
    ZSTD_inBuffer source = {input, count, 0};
    size_t remaining = 1, used = 0, capacity = 0;
    void *bytes = NULL;
    int failed = count == 0;
    while (!failed && source.pos < source.size) {
        if (capacity - used < 65536) {
            if (used > SIZE_MAX - 65536) { failed = 1; break; }
            capacity = used + 65536;
            void *grown = realloc(bytes, capacity);
            if (!grown) { failed = 1; break; }
            bytes = grown;
        }
        ZSTD_outBuffer target = {(char *)bytes + used, capacity - used, 0};
        size_t previous = source.pos;
        remaining = ZSTD_decompressStream(stream, &target, &source);
        used += target.pos;
        failed = ZSTD_isError(remaining) || (source.pos == previous && target.pos == 0);
        // A full output buffer may leave decoded bytes buffered after input ends.
        while (!failed && source.pos == source.size && target.pos == target.size && remaining != 0) {
            if (used > SIZE_MAX - 65536) { failed = 1; break; }
            capacity = used + 65536;
            void *grown = realloc(bytes, capacity);
            if (!grown) { failed = 1; break; }
            bytes = grown;
            target = (ZSTD_outBuffer){(char *)bytes + used, 65536, 0};
            remaining = ZSTD_decompressStream(stream, &target, &source);
            used += target.pos;
            failed = ZSTD_isError(remaining);
        }
    }
    ZSTD_freeDStream(stream);
    if (failed || remaining != 0) { free(bytes); return 1; }
    *output = bytes;
    *output_count = used;
    return 0;
}
