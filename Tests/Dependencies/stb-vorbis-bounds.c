#include <assert.h>
#include <limits.h>
#include "stb_vorbis.c"

int main(void) {
    unsigned char buffer[8] = {0};
    stb_vorbis decoder = {0};
    decoder.stream_start = buffer;
    decoder.stream_end = buffer + sizeof(buffer);
    decoder.stream = buffer;
    assert(set_file_offset(&decoder, 0) == 1);
    assert(set_file_offset(&decoder, 7) == 1);
    assert(decoder.stream == buffer + 7);
    assert(set_file_offset(&decoder, 8) == 0);
    assert(decoder.eof == 1);
    assert(set_file_offset(&decoder, UINT_MAX) == 0);
    assert(decoder.stream == decoder.stream_end);
    return 0;
}
