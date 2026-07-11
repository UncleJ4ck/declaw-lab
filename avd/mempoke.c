// mempoke: peek/poke a running process's loaded lib by file-offset, via /proc/pid/mem.
// peek:  mempoke <pid> <lib-substr> <hex-foff> <nbytes>
// poke:  mempoke <pid> <lib-substr> <hex-foff> = <hexbytes>   (e.g. = 000020d4  -> BRK #0)
// Same foff->addr mapping as declaw mempatch. pread/pwrite (FOLL_FORCE), works on r-x .text.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <inttypes.h>
#include <ctype.h>

static uint64_t foff2addr(int pid, const char *sub, uint64_t foff, uint64_t *base_out) {
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/maps", pid);
    FILE *m = fopen(path, "r");
    if (!m) { perror("open maps"); exit(3); }
    char line[1024];
    uint64_t start = 0, mapoff = 0; int found = 0;
    while (fgets(line, sizeof line, m)) {
        if (!strstr(line, sub)) continue;
        uint64_t s, e, o; char perms[8] = {0};
        if (sscanf(line, "%" SCNx64 "-%" SCNx64 " %7s %" SCNx64, &s, &e, perms, &o) != 4) continue;
        if (perms[2] != 'x') continue;
        if (foff >= o && foff < o + (e - s)) { start = s; mapoff = o; found = 1; break; }
    }
    fclose(m);
    if (!found) { fprintf(stderr, "no exec mapping of '%s' covering 0x%" PRIx64 "\n", sub, foff); exit(3); }
    if (base_out) *base_out = start;
    return start + (foff - mapoff);
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "peek: %s <pid> <lib> <hexfoff> <nbytes>\n"
                        "poke: %s <pid> <lib> <hexfoff> = <hexbytes>\n", argv[0], argv[0]);
        return 2;
    }
    int pid = atoi(argv[1]);
    uint64_t foff = strtoull(argv[3], NULL, 16);
    uint64_t base = 0;
    uint64_t addr = foff2addr(pid, argv[2], foff, &base);

    char path[64];
    snprintf(path, sizeof path, "/proc/%d/mem", pid);

    if (strcmp(argv[4], "=") == 0) {                 // POKE
        if (argc < 6) { fprintf(stderr, "poke needs hexbytes\n"); return 2; }
        const char *h = argv[5];
        unsigned char buf[64]; int n = 0;
        for (const char *p = h; p[0] && p[1] && n < 64; p += 2)
            buf[n++] = (unsigned char)strtoul((char[]){p[0], p[1], 0}, NULL, 16);
        int fd = open(path, O_RDWR);
        if (fd < 0) { perror("open mem"); return 4; }
        unsigned char before[64] = {0}, after[64] = {0};
        pread(fd, before, n, (off_t)addr);
        ssize_t w = pwrite(fd, buf, n, (off_t)addr);
        if (w != n) { perror("pwrite"); close(fd); return 5; }
        pread(fd, after, n, (off_t)addr);
        close(fd);
        printf("POKE addr=0x%" PRIx64 " (base=0x%" PRIx64 ") before=", addr, base);
        for (int i = 0; i < n; i++) printf("%02x", before[i]);
        printf(" after=");
        for (int i = 0; i < n; i++) printf("%02x", after[i]);
        printf(" %s\n", memcmp(after, buf, n) == 0 ? "OK" : "FAIL");
        return 0;
    }

    int nbytes = atoi(argv[4]);                      // PEEK
    if (nbytes <= 0 || nbytes > 512) nbytes = 16;
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror("open mem"); return 4; }
    unsigned char buf[512] = {0};
    ssize_t r = pread(fd, buf, nbytes, (off_t)addr);
    close(fd);
    if (r <= 0) { perror("pread"); return 5; }
    printf("PEEK addr=0x%" PRIx64 " (base=0x%" PRIx64 ", foff=0x%" PRIx64 ") %zd bytes:\n", addr, base, foff, r);
    for (int i = 0; i < r; i++) { printf("%02x", buf[i]); if ((i & 15) == 15) printf("\n"); else printf(" "); }
    if (r & 15) printf("\n");
    return 0;
}
