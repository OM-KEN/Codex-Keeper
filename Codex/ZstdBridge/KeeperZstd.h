#include <stddef.h>

// Incremental decoder. The caller owns fixed-size input/output buffers and frees the stream.
void *keeper_zstd_stream_create(void);
void keeper_zstd_stream_free(void *stream);
int keeper_zstd_stream_decode(void *stream, const void *input, size_t count, size_t *consumed,
                             void *output, size_t capacity, size_t *written, size_t *remaining);
