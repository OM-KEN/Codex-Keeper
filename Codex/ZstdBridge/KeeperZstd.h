#include <stddef.h>
#include <stdlib.h>
// Returns zero only after every frame has completed. Caller frees *output.
int keeper_zstd_decode(const void *input, size_t count, void **output, size_t *output_count);
