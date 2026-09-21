#include <errno.h>
#include <stdio.h>
#include <string.h>

#if defined(ZIPIR_ZLIB_NG_NATIVE)
#include <zlib-ng.h>
#define ZIPIR_STREAM zng_stream
#define ZIPIR_INFLATE_INIT zng_inflateInit
#define ZIPIR_INFLATE_END zng_inflateEnd
#define ZIPIR_INFLATE zng_inflate
#define ZIPIR_OK Z_OK
#define ZIPIR_STREAM_END Z_STREAM_END
#define ZIPIR_NO_FLUSH Z_NO_FLUSH
#define ZIPIR_VERSION_TEXT ZLIBNG_VERSION
#else
#include <zlib.h>
#define ZIPIR_STREAM z_stream
#define ZIPIR_INFLATE_INIT inflateInit
#define ZIPIR_INFLATE_END inflateEnd
#define ZIPIR_INFLATE inflate
#define ZIPIR_OK Z_OK
#define ZIPIR_STREAM_END Z_STREAM_END
#define ZIPIR_NO_FLUSH Z_NO_FLUSH
#define ZIPIR_VERSION_TEXT zlibVersion()
#endif

enum {
    IO_BUFFER_SIZE = 64 * 1024,
};

static int is_dash(const char *path) {
    return strcmp(path, "-") == 0;
}

static int open_input(const char *path, FILE **file) {
    if (is_dash(path)) {
        *file = stdin;
        return 0;
    }
    *file = fopen(path, "rb");
    if (*file == NULL) {
        fprintf(stderr, "zlib-adapter: cannot open input %s: %s\n", path, strerror(errno));
        return 1;
    }
    return 0;
}

static int open_output(const char *path, FILE **file) {
    if (is_dash(path)) {
        *file = stdout;
        return 0;
    }
    *file = fopen(path, "wb");
    if (*file == NULL) {
        fprintf(stderr, "zlib-adapter: cannot open output %s: %s\n", path, strerror(errno));
        return 1;
    }
    return 0;
}

static void close_file(FILE *file, const char *path) {
    if (!is_dash(path)) fclose(file);
}

static int trailing_data(FILE *input, ZIPIR_STREAM *stream) {
    int next;
    if (stream->avail_in != 0) {
        fprintf(stderr, "zlib-adapter: trailing zlib data\n");
        return 1;
    }
    next = fgetc(input);
    if (next != EOF) {
        fprintf(stderr, "zlib-adapter: trailing zlib data\n");
        return 1;
    }
    if (ferror(input)) {
        fprintf(stderr, "zlib-adapter: input read failed\n");
        return 1;
    }
    return 0;
}

static int stream_decompress(FILE *input, FILE *output) {
    unsigned char input_buffer[IO_BUFFER_SIZE];
    unsigned char output_buffer[IO_BUFFER_SIZE];
    ZIPIR_STREAM stream;
    int result;

    memset(&stream, 0, sizeof(stream));
    result = ZIPIR_INFLATE_INIT(&stream);
    if (result != ZIPIR_OK) {
        fprintf(stderr, "zlib-adapter: inflateInit failed: %d\n", result);
        return 1;
    }

    for (;;) {
        size_t read_count = fread(input_buffer, 1, sizeof(input_buffer), input);
        if (ferror(input)) {
            fprintf(stderr, "zlib-adapter: input read failed\n");
            ZIPIR_INFLATE_END(&stream);
            return 1;
        }
        if (read_count == 0) {
            fprintf(stderr, "zlib-adapter: truncated zlib stream\n");
            ZIPIR_INFLATE_END(&stream);
            return 1;
        }

        stream.next_in = input_buffer;
        stream.avail_in = (uInt)read_count;
        do {
            size_t written;
            stream.next_out = output_buffer;
            stream.avail_out = (uInt)sizeof(output_buffer);
            result = ZIPIR_INFLATE(&stream, ZIPIR_NO_FLUSH);
            written = sizeof(output_buffer) - stream.avail_out;
            if (written != 0 && fwrite(output_buffer, 1, written, output) != written) {
                fprintf(stderr, "zlib-adapter: output write failed\n");
                ZIPIR_INFLATE_END(&stream);
                return 1;
            }
            if (result == ZIPIR_STREAM_END) {
                int trailing = trailing_data(input, &stream);
                ZIPIR_INFLATE_END(&stream);
                return trailing == 0 ? 0 : 1;
            }
            if (result != ZIPIR_OK) {
                fprintf(stderr, "zlib-adapter: inflate failed: %d\n", result);
                ZIPIR_INFLATE_END(&stream);
                return 1;
            }
        } while (stream.avail_in != 0);
    }
}

static int print_version(void) {
#if defined(ZIPIR_ZLIB_NG_NATIVE)
    printf("zlib-ng-zlib %s\n", ZIPIR_VERSION_TEXT);
#else
    printf("system-zlib %s\n", ZIPIR_VERSION_TEXT);
#endif
    return 0;
}

int main(int argc, char **argv) {
    FILE *input = NULL;
    FILE *output = NULL;
    int status;

    if (argc == 2 && strcmp(argv[1], "--version") == 0) return print_version();
    if (argc == 4 && strcmp(argv[1], "decompress") == 0) {
        if (open_input(argv[2], &input) != 0 || open_output(argv[3], &output) != 0) {
            if (input != NULL && !is_dash(argv[2])) fclose(input);
            return 2;
        }
        status = stream_decompress(input, output);
        close_file(input, argv[2]);
        close_file(output, argv[3]);
        return status;
    }

    fprintf(stderr,
        "usage: zlib-adapter --version\n"
        "       zlib-adapter decompress IN OUT\n");
    return 2;
}
