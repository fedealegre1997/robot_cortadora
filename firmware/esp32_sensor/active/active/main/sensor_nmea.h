#pragma once
#include <stdbool.h>
#include <string.h>
static inline int sensor_hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}
static inline bool sensor_nmea_checksum_ok(const char *s) {
    if (!s || *s != '$') return false;
    const char *end = strchr(s, '*');
    if (!end || strlen(end) != 3) return false;
    int hi = sensor_hex(end[1]), lo = sensor_hex(end[2]);
    if (hi < 0 || lo < 0) return false;
    unsigned char sum = 0;
    for (const char *p = s + 1; p < end; p++) sum ^= (unsigned char)*p;
    return sum == (unsigned char)((hi << 4) | lo);
}
