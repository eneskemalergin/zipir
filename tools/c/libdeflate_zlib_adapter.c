#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libdeflate.h>

/* zlib container by default; -DZIPIR_RAW selects raw DEFLATE. */
#if defined(ZIPIR_RAW)
#define NAME "libdeflate-deflate"
#define FORMAT_NAME "deflate"
#define DECOMPRESS_EX libdeflate_deflate_decompress_ex
#define COMPRESS libdeflate_deflate_compress
#define COMPRESS_BOUND libdeflate_deflate_compress_bound
#else
#define NAME "libdeflate-zlib"
#define FORMAT_NAME "zlib"
#define DECOMPRESS_EX libdeflate_zlib_decompress_ex
#define COMPRESS libdeflate_zlib_compress
#define COMPRESS_BOUND libdeflate_zlib_compress_bound
#endif

/*
 * This is deliberately a full-buffer peer. libdeflate's public zlib API is
 * one-shot: it accepts the complete compressed input and writes to one
 * caller-sized output buffer. The benchmark supplies the known plaintext size
 * so the timed call decodes into one buffer of exactly that size. The no-size
 * form is kept for CLI tests and grows by retrying, so it is not a benchmark
 * mode.
 */
enum {
    INPUT_GROWTH = 64 * 1024,
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
        fprintf(stderr, NAME ": cannot open input %s: %s\n", path, strerror(errno));
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
        fprintf(stderr, NAME ": cannot open output %s: %s\n", path, strerror(errno));
        return 1;
    }
    return 0;
}

static void close_file(FILE *file, const char *path) {
    if (!is_dash(path)) fclose(file);
}

static int parse_size(const char *text, size_t *value) {
    char *end = NULL;
    unsigned long long parsed;

    errno = 0;
    parsed = strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || parsed > SIZE_MAX) return 1;
    *value = (size_t)parsed;
    return 0;
}

static int read_regular_file(FILE *input, unsigned char **data, size_t *length) {
    long end;
    size_t size;
    unsigned char *buffer;

    if (fseek(input, 0, SEEK_END) != 0) {
        clearerr(input);
        return 1;
    }
    end = ftell(input);
    if (end < 0 || fseek(input, 0, SEEK_SET) != 0) {
        clearerr(input);
        return 1;
    }
    if ((unsigned long)end > SIZE_MAX) {
        fprintf(stderr, NAME ": input is too large\n");
        return -1;
    }
    size = (size_t)end;
    buffer = malloc(size == 0 ? 1 : size);
    if (buffer == NULL) {
        fprintf(stderr, NAME ": input allocation failed\n");
        return -1;
    }
    if (size != 0 && fread(buffer, 1, size, input) != size) {
        fprintf(stderr, NAME ": input read failed\n");
        free(buffer);
        return -1;
    }
    if (ferror(input)) {
        fprintf(stderr, NAME ": input read failed\n");
        free(buffer);
        return -1;
    }
    *data = buffer;
    *length = size;
    return 0;
}

static int read_growing(FILE *input, unsigned char **data, size_t *length) {
    unsigned char *buffer = NULL;
    size_t capacity = 0;
    size_t used = 0;

    for (;;) {
        size_t read_count;
        if (used == capacity) {
            size_t next_capacity = capacity == 0 ? INPUT_GROWTH : capacity;
            if (next_capacity > SIZE_MAX / 2) {
                fprintf(stderr, NAME ": input is too large\n");
                free(buffer);
                return 1;
            }
            if (capacity != 0) next_capacity *= 2;
            unsigned char *next = realloc(buffer, next_capacity);
            if (next == NULL) {
                fprintf(stderr, NAME ": input allocation failed\n");
                free(buffer);
                return 1;
            }
            buffer = next;
            capacity = next_capacity;
        }
        read_count = fread(buffer + used, 1, capacity - used, input);
        used += read_count;
        if (ferror(input)) {
            fprintf(stderr, NAME ": input read failed\n");
            free(buffer);
            return 1;
        }
        if (read_count == 0) break;
    }

    *data = buffer;
    *length = used;
    return 0;
}

static int read_all(FILE *input, unsigned char **data, size_t *length) {
    int regular = read_regular_file(input, data, length);
    if (regular <= 0) return regular == 0 ? 0 : 1;
    return read_growing(input, data, length);
}

static int initial_output_capacity(size_t input_length, size_t *capacity) {
    if (input_length > SIZE_MAX / 2) return 1;
    *capacity = input_length * 2;
    if (*capacity < INPUT_GROWTH) *capacity = INPUT_GROWTH;
    return 0;
}

static int decompress_buffer(
    FILE *output,
    const unsigned char *input,
    size_t input_length,
    bool expected_output,
    size_t expected_output_length
) {
    struct libdeflate_decompressor *decompressor = NULL;
    unsigned char *decoded = NULL;
    size_t output_capacity;
    int status = 1;

    if (expected_output) {
        output_capacity = expected_output_length;
    } else if (initial_output_capacity(input_length, &output_capacity) != 0) {
        fprintf(stderr, NAME ": output is too large\n");
        return 1;
    }

    decoded = malloc(output_capacity == 0 ? 1 : output_capacity);
    if (decoded == NULL) {
        fprintf(stderr, NAME ": output allocation failed\n");
        return 1;
    }
    decompressor = libdeflate_alloc_decompressor();
    if (decompressor == NULL) {
        fprintf(stderr, NAME ": decompressor allocation failed\n");
        goto done;
    }

    for (;;) {
        size_t actual_input = 0;
        size_t actual_output = 0;
        enum libdeflate_result result = DECOMPRESS_EX(
            decompressor,
            input,
            input_length,
            decoded,
            output_capacity,
            &actual_input,
            &actual_output
        );

        if (result == LIBDEFLATE_SUCCESS) {
            if (actual_input != input_length) {
                fprintf(stderr, NAME ": trailing " FORMAT_NAME " data\n");
                goto done;
            }
            if (expected_output && actual_output != expected_output_length) {
                fprintf(stderr, NAME ": output size mismatch\n");
                goto done;
            }
            if (actual_output != 0 && fwrite(decoded, 1, actual_output, output) != actual_output) {
                fprintf(stderr, NAME ": output write failed\n");
                goto done;
            }
            status = 0;
            goto done;
        }
        if (result != LIBDEFLATE_INSUFFICIENT_SPACE || expected_output) {
            fprintf(stderr, NAME ": decompression failed: %d\n", result);
            goto done;
        }
        if (output_capacity > SIZE_MAX / 2) {
            fprintf(stderr, NAME ": output is too large\n");
            goto done;
        }
        output_capacity *= 2;
        unsigned char *next = realloc(decoded, output_capacity == 0 ? 1 : output_capacity);
        if (next == NULL) {
            fprintf(stderr, NAME ": output allocation failed\n");
            goto done;
        }
        decoded = next;
    }

done:
    libdeflate_free_decompressor(decompressor);
    free(decoded);
    return status;
}

/* Full-buffer compression: the whole input in, one call, the whole output out. */
static int compress_buffer(FILE *output, const unsigned char *input, size_t input_length, int level) {
    struct libdeflate_compressor *compressor = libdeflate_alloc_compressor(level);
    unsigned char *encoded = NULL;
    size_t bound;
    size_t written;
    int status = 1;

    if (compressor == NULL) {
        fprintf(stderr, NAME ": compressor allocation failed for level %d\n", level);
        return 1;
    }
    bound = COMPRESS_BOUND(compressor, input_length);
    encoded = malloc(bound == 0 ? 1 : bound);
    if (encoded == NULL) {
        fprintf(stderr, NAME ": output allocation failed\n");
        goto done;
    }
    written = COMPRESS(compressor, input, input_length, encoded, bound);
    if (written == 0) {
        fprintf(stderr, NAME ": compression failed\n");
        goto done;
    }
    if (fwrite(encoded, 1, written, output) != written) {
        fprintf(stderr, NAME ": output write failed\n");
        goto done;
    }
    status = 0;

done:
    libdeflate_free_compressor(compressor);
    free(encoded);
    return status;
}

static int print_version(void) {
    printf(NAME " %s\n", LIBDEFLATE_VERSION_STRING);
    return 0;
}

int main(int argc, char **argv) {
    FILE *input = NULL;
    FILE *output = NULL;
    unsigned char *input_data = NULL;
    size_t input_length = 0;
    size_t expected_output_length = 0;
    bool expected_output = false;
    int status;

    if (argc == 2 && strcmp(argv[1], "--version") == 0) return print_version();
    if (argc == 6 && strcmp(argv[1], "compress") == 0 && strcmp(argv[2], "--level") == 0) {
        char *end = NULL;
        long level = strtol(argv[3], &end, 10);
        if (end == argv[3] || *end != '\0' || level < 0 || level > 12) {
            fprintf(stderr, NAME ": invalid level: %s\n", argv[3]);
            return 2;
        }
        if (open_input(argv[4], &input) != 0 || open_output(argv[5], &output) != 0) {
            if (input != NULL && !is_dash(argv[4])) fclose(input);
            return 2;
        }
        status = read_all(input, &input_data, &input_length);
        if (status == 0) status = compress_buffer(output, input_data, input_length, (int)level);
        free(input_data);
        close_file(input, argv[4]);
        close_file(output, argv[5]);
        return status;
    }
    if (argc == 4 && strcmp(argv[1], "decompress") == 0) {
        argv += 1;
    } else if (argc == 6 && strcmp(argv[1], "decompress") == 0 &&
               strcmp(argv[2], "--expected-output-bytes") == 0) {
        if (parse_size(argv[3], &expected_output_length) != 0) {
            fprintf(stderr, NAME ": invalid expected output size: %s\n", argv[3]);
            return 2;
        }
        expected_output = true;
        argv += 3;
    } else {
        fprintf(stderr,
            "usage: " NAME " --version\n"
            "       " NAME " compress --level N IN OUT\n"
            "       " NAME " decompress [--expected-output-bytes N] IN OUT\n");
        return 2;
    }

    if (open_input(argv[1], &input) != 0 || open_output(argv[2], &output) != 0) {
        if (input != NULL && !is_dash(argv[1])) fclose(input);
        return 2;
    }
    status = read_all(input, &input_data, &input_length);
    if (status == 0) {
        status = decompress_buffer(output, input_data, input_length, expected_output, expected_output_length);
    }
    free(input_data);
    close_file(input, argv[1]);
    close_file(output, argv[2]);
    return status;
}
