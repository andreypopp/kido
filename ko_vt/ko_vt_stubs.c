#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/callback.h>
#include <ghostty/vt.h>
#include "snapshot_cut.h"
#include "buffer.h"
#include <stdlib.h>
#include <string.h>

#define T(v) (*(GhosttyTerminal *)Data_custom_val(v))
static void finalize(value v) { if (T(v)) ghostty_terminal_free(T(v)); }
static struct custom_operations ops = { .identifier="ko.vt", .finalize=finalize,
  .compare=custom_compare_default, .hash=custom_hash_default,
  .serialize=custom_serialize_default, .deserialize=custom_deserialize_default,
  .compare_ext=custom_compare_ext_default, .fixed_length=custom_fixed_length_default };
static void check(GhosttyResult r) { if(r != GHOSTTY_SUCCESS) caml_failwith("libghostty-vt operation failed"); }
static value wrap(GhosttyTerminal vt) {
  value v=caml_alloc_custom(&ops,sizeof(GhosttyTerminal),0,1); T(v)=vt; return v;
}
static void check_size(value cols,value rows) {
  if(Long_val(cols)<1 || Long_val(cols)>65535 || Long_val(rows)<1 || Long_val(rows)>65535)
    caml_invalid_argument("terminal dimensions");
}
CAMLprim value ko_vt_create(value cols,value rows,value scrollback,value apc,value kitty,value continuation) {
  CAMLparam5(cols,rows,scrollback,apc,kitty); CAMLxparam1(continuation); CAMLlocal1(v);
  check_size(cols,rows);
  GhosttyTerminal vt=NULL;
  check(ghostty_terminal_new(NULL,&vt,Long_val(cols),Long_val(rows)));
  v=wrap(vt);
  size_t scrollback_bytes=Long_val(scrollback),apc_bytes=Long_val(apc),continuation_bytes=Long_val(continuation);
  uint64_t kitty_bytes=Long_val(kitty);
  check(ghostty_terminal_set(vt,GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,&scrollback_bytes));
  check(ghostty_terminal_set(vt,GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES,&apc_bytes));
  check(ghostty_terminal_set(vt,GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,&kitty_bytes));
  check(ghostty_terminal_set(vt,GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES,&continuation_bytes));
  CAMLreturn(v);
}
CAMLprim value ko_vt_create_bytecode(value *argv,int argc) {
  (void)argc; return ko_vt_create(argv[0],argv[1],argv[2],argv[3],argv[4],argv[5]);
}
CAMLprim value ko_vt_write(value v,value bytes) {
  CAMLparam2(v,bytes);
  ghostty_terminal_vt_write(T(v),(const uint8_t *)String_val(bytes),caml_string_length(bytes));
  CAMLreturn(Val_unit);
}
CAMLprim value ko_vt_resize(value v,value cols,value rows) {
  CAMLparam3(v,cols,rows); check_size(cols,rows);
  check(ghostty_terminal_resize(T(v),Long_val(cols),Long_val(rows),8,16)); CAMLreturn(Val_unit);
}
static bool append(void *ud,const uint8_t *data,size_t len) { return !ko_append(ud,data,len); }
CAMLprim value ko_vt_dump(value v,value format) {
  CAMLparam2(v,format); int vt_format=Int_val(format)==1; CAMLlocal1(result); GhosttyFormatter f=NULL;
  GhosttyFormatterTerminalOptions options={.size=sizeof(options),
    .emit=vt_format?GHOSTTY_FORMATTER_FORMAT_VT:GHOSTTY_FORMATTER_FORMAT_PLAIN,.trim=false};
  options.extra.size=sizeof(options.extra);
  if(vt_format){
  options.extra.modes=true; options.extra.scrolling_region=true; options.extra.keyboard=true;
  options.extra.screen=(GhosttyFormatterScreenExtra){.size=sizeof(GhosttyFormatterScreenExtra),
    .cursor=true,.style=true,.hyperlink=true,.protection=true,.kitty_keyboard=true,.charsets=true};
  }
  GhosttyTerminal vt=T(v);uint16_t cols=0,rows=0;
  GhosttySelection selection={.size=sizeof(selection)};
  GhosttyResult r=ghostty_terminal_get(vt,GHOSTTY_TERMINAL_DATA_COLS,&cols);
  if(r==GHOSTTY_SUCCESS)r=ghostty_terminal_get(vt,GHOSTTY_TERMINAL_DATA_ROWS,&rows);
  GhosttyPoint start={.tag=GHOSTTY_POINT_TAG_ACTIVE,.value.coordinate={0,0}};
  GhosttyPoint end={.tag=GHOSTTY_POINT_TAG_ACTIVE,.value.coordinate={cols-1,rows-1}};
  if(r==GHOSTTY_SUCCESS)r=ghostty_terminal_grid_ref(vt,start,&selection.start);
  if(r==GHOSTTY_SUCCESS)r=ghostty_terminal_grid_ref(vt,end,&selection.end);
  options.selection=&selection;
  if(r==GHOSTTY_SUCCESS)r=ghostty_formatter_terminal_new(NULL,&f,vt,options);
  struct ko_buffer b={0};
  if(r==GHOSTTY_SUCCESS) r=ghostty_formatter_format(f,(GhosttyWriter){append,&b});
  ghostty_formatter_free(f);
  if(r!=GHOSTTY_SUCCESS) { free(b.p); check(r); }
  result=caml_alloc_initialized_string(b.n,(char *)b.p); free(b.p); CAMLreturn(result);
}
static int emit(void *ud,const uint8_t *b,size_t n) { return ko_append(ud,b,n); }
CAMLprim value ko_vt_snapshot(value v,value screen,value images) {
  CAMLparam3(v,screen,images); CAMLlocal1(result);
  struct ko_cut cut={.screen=Bool_val(screen),.images=Bool_val(images)};
  struct ko_buffer out={0};
  GhosttyResult r=ko_snapshot_encode(T(v),&cut,emit,&out);
  if(r!=GHOSTTY_SUCCESS) { free(out.p); check(r); }
  result=caml_alloc_initialized_string(out.n,(char *)out.p); free(out.p); CAMLreturn(result);
}
struct reader { value callback; value exception; };
static bool read_ocaml(void *ud,uint8_t *buffer,size_t capacity,size_t *count) {
  CAMLparam0(); CAMLlocal1(chunk); struct reader *r=ud;
  chunk=caml_callback_exn(r->callback,Val_long(capacity));
  if(Is_exception_result(chunk)) { caml_modify_generational_global_root(&r->exception,Extract_exception(chunk)); CAMLreturnT(bool,false); }
  size_t len=caml_string_length(chunk);
  if(len>capacity) CAMLreturnT(bool,false);
  memcpy(buffer,String_val(chunk),len); *count=len; CAMLreturnT(bool,true);
}
CAMLprim value ko_vt_decode(value callback,value full) {
  CAMLparam2(callback,full); CAMLlocal2(v,exception);
  struct reader reader={callback,Val_unit};
  caml_register_generational_global_root(&reader.callback);
  caml_register_generational_global_root(&reader.exception);
  GhosttySnapshotDecoder decoder=NULL; GhosttyTerminal vt=NULL;
  GhosttyResult r=ghostty_snapshot_decoder_new(NULL,&decoder,(GhosttyReader){read_ocaml,&reader});
  if(r==GHOSTTY_SUCCESS) r=ghostty_snapshot_decoder_ready(decoder,&vt);
  if(r==GHOSTTY_SUCCESS && Bool_val(full)) {
    while((r=ghostty_snapshot_decoder_next(decoder))==GHOSTTY_SUCCESS) {}
    if(r==GHOSTTY_NO_VALUE) r=GHOSTTY_SUCCESS;
  }
  ghostty_snapshot_decoder_free(decoder);
  exception=reader.exception;
  caml_remove_generational_global_root(&reader.callback); caml_remove_generational_global_root(&reader.exception);
  if(exception!=Val_unit || r!=GHOSTTY_SUCCESS) {
    if(vt) ghostty_terminal_free(vt);
    if(exception!=Val_unit) caml_raise(exception);
    check(r);
  }
  v=wrap(vt);CAMLreturn(v);
}
CAMLprim value ko_vt_cursor(value v) {
  CAMLparam1(v); CAMLlocal1(result); GhosttyTerminal vt=T(v);
  uint16_t x=0,y=0;bool wrap=false;
  GhosttyResult r=ghostty_terminal_get(vt,GHOSTTY_TERMINAL_DATA_CURSOR_X,&x);
  if(r==GHOSTTY_SUCCESS) r=ghostty_terminal_get(vt,GHOSTTY_TERMINAL_DATA_CURSOR_Y,&y);
  if(r==GHOSTTY_SUCCESS) r=ghostty_terminal_get(vt,GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP,&wrap);
  check(r); result=caml_alloc_tuple(3);
  Store_field(result,0,Val_int(x));Store_field(result,1,Val_int(y));Store_field(result,2,Val_bool(wrap));CAMLreturn(result);
}
CAMLprim value ko_vt_mode(value v,value number) {
  CAMLparam2(v,number); GhosttyTerminalModeConfig mode={.mode=Int_val(number)};
  check(ghostty_terminal_get(T(v),GHOSTTY_TERMINAL_DATA_MODE,&mode));CAMLreturn(Val_bool(mode.value));
}
CAMLprim value ko_vt_total_rows(value v) {
  CAMLparam1(v); size_t rows=0;
  check(ghostty_terminal_get(T(v),GHOSTTY_TERMINAL_DATA_TOTAL_ROWS,&rows));CAMLreturn(Val_long(rows));
}
