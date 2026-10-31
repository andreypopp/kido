#ifndef KO_PIXELS_H
#define KO_PIXELS_H
#include <stdint.h>
static inline uint16_t ko_pixels(uint16_t cells, uint16_t each) {
  uint64_t pixels = (uint64_t)cells * each;
  return pixels > UINT16_MAX ? UINT16_MAX : (uint16_t)pixels;
}
#endif
