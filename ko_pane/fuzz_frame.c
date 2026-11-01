#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include "protocol.h"
#include <assert.h>
int LLVMFuzzerTestOneInput(const uint8_t *data,size_t size) {
  while(size){size_t len=0;int result=ko_frame_size(data,size,&len);
    if(result<=0)break;
    assert(len>=5&&len<=size&&len<=KO_MAX_FRAME+4);
    data+=len;size-=len;
  }
  return 0;
}
#ifndef KO_LIBFUZZER
#include <stdlib.h>
int main(void) {
  static uint8_t input[1 << 16];
  srand(182);
  for (int round = 0; round < 20000; round++) {
    size_t size = (size_t)rand() % sizeof(input);
    for (size_t i = 0; i < size; i++) input[i] = (uint8_t)rand();
    if (round % 2) for (size_t i = 0; i + 5 < size; i += 64) { input[i] = (uint8_t)(rand() % 70); input[i + 1] = input[i + 2] = input[i + 3] = 0; }
    LLVMFuzzerTestOneInput(input, size);
  }
  return 0;
}
#endif
