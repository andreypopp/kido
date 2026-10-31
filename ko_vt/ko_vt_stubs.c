#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/callback.h>
#include <caml/threads.h>
#define HOLD_SECONDS 0.15
#include <ghostty/vt.h>
#include "snapshot_cut.h"
#include "buffer.h"
#include "compress.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct terminal { GhosttyTerminal vt; GhosttyRenderState render;
  GhosttyRenderStateRowIterator rows; GhosttyRenderStateRowCells cells;
  struct ko_compress compress; bool held; double hold_started; uintnat hold_id; GhosttyResult render_error; };
#define S(v) (*(struct terminal **)Data_custom_val(v))
static struct terminal *live(value v) {
  if(!S(v)) caml_invalid_argument("closed terminal");return S(v);
}
#define T(v) (live(v)->vt)
static void finalize(value v) {
  if(!S(v)) return;
  ghostty_render_state_row_cells_free(S(v)->cells);
  ghostty_render_state_row_iterator_free(S(v)->rows);
  ghostty_render_state_free(S(v)->render);
  if (T(v)) ghostty_terminal_free(T(v));
  free(S(v));S(v)=NULL;
}
CAMLprim value ko_vt_close(value v) {
  CAMLparam1(v);finalize(v);CAMLreturn(Val_unit);
}
static struct custom_operations ops = { .identifier="ko.vt", .finalize=finalize,
  .compare=custom_compare_default, .hash=custom_hash_default,
  .serialize=custom_serialize_default, .deserialize=custom_deserialize_default,
  .compare_ext=custom_compare_ext_default, .fixed_length=custom_fixed_length_default };
static void check(GhosttyResult r) { if(r != GHOSTTY_SUCCESS) caml_failwith("libghostty-vt operation failed"); }
static double monotonic(void) {
  struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;
}
static void render_hold(GhosttyTerminal vt,void *userdata,bool held) {
  struct terminal *s=userdata;
  if(held) {
    if(!s->render) s->render_error=ghostty_render_state_new(NULL,&s->render);
    if(s->render_error==GHOSTTY_SUCCESS) s->render_error=ghostty_render_state_update(s->render,vt);
    s->hold_started=monotonic();s->hold_id++;
  }
  s->held=held;
}
static value wrap(GhosttyTerminal vt) {
  value v=caml_alloc_custom(&ops,sizeof(struct terminal *),0,1);
  S(v)=calloc(1,sizeof(struct terminal));
  if(!S(v)) { ghostty_terminal_free(vt); caml_raise_out_of_memory(); }
  T(v)=vt;
  ko_compress_init(&S(v)->compress,ko_now_ns());
  check(ghostty_terminal_set(vt,GHOSTTY_TERMINAL_OPT_USERDATA,S(v)));
  check(ghostty_terminal_set(vt,GHOSTTY_TERMINAL_OPT_RENDER_HOLD,render_hold));
  return v;
}
static void check_size(value cols,value rows) {
  if(Long_val(cols)<1 || Long_val(cols)>65535 || Long_val(rows)<1 || Long_val(rows)>65535)
    caml_invalid_argument("terminal dimensions");
}
static void limits(GhosttyTerminal vt,value limits) {
  value scrollback=Field(limits,0);
  long bytes=0,lines=0;
  int has_bytes=1,has_lines=0;
  if(Is_block(scrollback)) {
    value max_bytes=Field(scrollback,0),max_lines=Field(scrollback,1);
    has_bytes=Is_block(max_bytes);has_lines=Is_block(max_lines);
    if(has_bytes) bytes=Long_val(Field(max_bytes,0));
    if(has_lines) lines=Long_val(Field(max_lines,0));
  }
  value apc=Field(limits,1),kitty=Field(limits,2),continuation=Field(limits,3);
  if(bytes<0 || (has_lines && lines<1) || Long_val(apc)<0 || Long_val(kitty)<0 || Long_val(continuation)<0)
    caml_invalid_argument("terminal limits");
  size_t scrollback_bytes=bytes,scrollback_lines=lines,apc_bytes=Long_val(apc),continuation_bytes=Long_val(continuation);
  uint64_t kitty_bytes=Long_val(kitty);
  check(ghostty_terminal_set(vt,GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,has_bytes?&scrollback_bytes:NULL));
  check(ghostty_terminal_set(vt,GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,has_lines?&scrollback_lines:NULL));
  check(ghostty_terminal_set(vt,GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES,&apc_bytes));
  check(ghostty_terminal_set(vt,GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,&kitty_bytes));
  check(ghostty_terminal_set(vt,GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES,&continuation_bytes));
}
CAMLprim value ko_vt_configure(value v,value lim) {
  CAMLparam2(v,lim);
  limits(T(v),lim);CAMLreturn(Val_unit);
}
CAMLprim value ko_vt_create(value cols,value rows,value lim) {
  CAMLparam3(cols,rows,lim); CAMLlocal1(v);
  check_size(cols,rows);
  GhosttyTerminal vt=NULL;
  check(ghostty_terminal_new(NULL,&vt,Long_val(cols),Long_val(rows)));
  v=wrap(vt);
  limits(vt,lim);
  CAMLreturn(v);
}
CAMLprim value ko_vt_now_ns(value unit) {
  (void)unit; return Val_long(ko_now_ns());
}
CAMLprim value ko_vt_compress_tick(value v,value now) {
  CAMLparam2(v,now); struct terminal *s=live(v); int next;
  caml_enter_blocking_section();
  next=ko_compress_tick(&s->compress,s->vt,Long_val(now));
  caml_leave_blocking_section();
  CAMLreturn(Val_int(next));
}
CAMLprim value ko_vt_memory(value v) {
  CAMLparam1(v); CAMLlocal1(result);
  GhosttyTerminalMemoryUsage usage=GHOSTTY_INIT_SIZED(GhosttyTerminalMemoryUsage);
  check(ghostty_terminal_get(T(v),GHOSTTY_TERMINAL_DATA_MEMORY_USAGE,&usage));
  result=caml_alloc_tuple(3);
  Store_field(result,0,Val_long(usage.primary_pages+usage.alternate_pages));
  Store_field(result,1,Val_long(usage.primary_compressed_pages+usage.alternate_compressed_pages));
  Store_field(result,2,Val_long(usage.primary_resident_bytes+usage.alternate_resident_bytes));
  CAMLreturn(result);
}
CAMLprim value ko_vt_write(value v,value off,value len,value bytes) {
  CAMLparam4(v,off,len,bytes);
  intnat at=Is_block(off)?Long_val(Field(off,0)):0;
  intnat count=Is_block(len)?Long_val(Field(len,0)):(intnat)caml_string_length(bytes)-at;
  if(at<0 || count<0 || (uintnat)at>caml_string_length(bytes) ||
     (uintnat)count>caml_string_length(bytes)-(uintnat)at) caml_invalid_argument("Ko_vt.write");
  GhosttyTerminal vt=T(v);
  uint8_t *copy=malloc(count?count:1);if(!copy)caml_raise_out_of_memory();
  memcpy(copy,String_val(bytes)+at,count);
  caml_enter_blocking_section();
  ghostty_terminal_vt_write(vt,copy,count);
  free(copy);
  caml_leave_blocking_section();CAMLreturn(Val_unit);
}
CAMLprim value ko_vt_resize(value v,value cols,value rows) {
  CAMLparam3(v,cols,rows); check_size(cols,rows);
  check(ghostty_terminal_resize(T(v),Long_val(cols),Long_val(rows),8,16)); CAMLreturn(Val_unit);
}
static bool append(void *ud,const uint8_t *data,size_t len) { return !ko_append(ud,data,len); }
static value dump(value v,value format,int history) {
  CAMLparam2(v,format); int vt_format=Int_val(format)==1; CAMLlocal1(result); GhosttyFormatter f=NULL;
  GhosttyFormatterTerminalOptions options={.size=sizeof(options),
    .emit=vt_format?GHOSTTY_FORMATTER_FORMAT_VT:GHOSTTY_FORMATTER_FORMAT_PLAIN,.trim=false};
  options.extra.size=sizeof(options.extra);
  if(vt_format){
  options.extra.modes=true; options.extra.scrolling_region=true; options.extra.keyboard=true;
  options.extra.screen=(GhosttyFormatterScreenExtra){.size=sizeof(GhosttyFormatterScreenExtra),
    .cursor=true,.style=true,.hyperlink=true,.protection=true,.kitty_keyboard=true,.charsets=true};
  }
  GhosttyTerminal vt=T(v);uint16_t cols=0,rows=0;size_t total=0;
  GhosttySelection selection={.size=sizeof(selection)};
  GhosttyResult r=ghostty_terminal_get(vt,GHOSTTY_TERMINAL_DATA_COLS,&cols);
  if(r==GHOSTTY_SUCCESS)r=ghostty_terminal_get(vt,GHOSTTY_TERMINAL_DATA_ROWS,&rows);
  if(history&&r==GHOSTTY_SUCCESS)r=ghostty_terminal_get(vt,GHOSTTY_TERMINAL_DATA_TOTAL_ROWS,&total);
  GhosttyPoint start={.tag=history?GHOSTTY_POINT_TAG_SCREEN:GHOSTTY_POINT_TAG_ACTIVE,.value.coordinate={0,0}};
  GhosttyPoint end={.tag=history?GHOSTTY_POINT_TAG_SCREEN:GHOSTTY_POINT_TAG_ACTIVE,.value.coordinate={cols-1,history?total-1:rows-1}};
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
CAMLprim value ko_vt_dump(value v,value format) {return dump(v,format,0);}
CAMLprim value ko_vt_dump_history(value v,value format) {return dump(v,format,1);}
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
CAMLprim value ko_vt_decode(value ready,value callback,value full) {
  CAMLparam3(ready,callback,full); CAMLlocal4(v,exception,screen,returned);
  struct reader reader={callback,Val_unit};
  caml_register_generational_global_root(&reader.callback);
  caml_register_generational_global_root(&reader.exception);
  GhosttySnapshotDecoder decoder=NULL; GhosttyTerminal vt=NULL;
  GhosttyResult r=ghostty_snapshot_decoder_new(NULL,&decoder,(GhosttyReader){read_ocaml,&reader});
  bool compress=true;
  if(r==GHOSTTY_SUCCESS) r=ghostty_snapshot_decoder_set(decoder,GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY,&compress);
  if(r==GHOSTTY_SUCCESS) r=ghostty_snapshot_decoder_ready(decoder,&vt);
  if(r==GHOSTTY_SUCCESS && Bool_val(full) && Is_block(ready)) {
    struct ko_cut cut={.screen=1,.images=0}; struct ko_buffer out={0};
    r=ko_snapshot_encode(vt,&cut,emit,&out);
    if(r==GHOSTTY_SUCCESS) {
      screen=caml_alloc_initialized_string(out.n,(char *)out.p);
      returned=caml_callback_exn(Field(ready,0),screen);
      if(Is_exception_result(returned)) {
        caml_modify_generational_global_root(&reader.exception,Extract_exception(returned));r=GHOSTTY_IO_ERROR;
      }
    }
    free(out.p);
  }
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
static int pack_rgb(GhosttyColorRgb rgb) { return 0x1000000 | (rgb.r<<16) | (rgb.g<<8) | rgb.b; }
static value colour(int packed) {
  CAMLparam0();CAMLlocal1(v);
  if(packed<0) CAMLreturn(Val_int(0));
  if(packed<256){v=caml_alloc_tuple(1);Store_field(v,0,Val_int(packed));}
  else {v=caml_alloc(3,1);Store_field(v,0,Val_int((packed>>16)&255));Store_field(v,1,Val_int((packed>>8)&255));Store_field(v,2,Val_int(packed&255));}
  CAMLreturn(v);
}
static int style_color(GhosttyStyleColor c) {
  switch(c.tag) {
    case GHOSTTY_STYLE_COLOR_PALETTE: return c.value.palette;
    case GHOSTTY_STYLE_COLOR_RGB: return pack_rgb(c.value.rgb);
    default: return -1;
  }
}
CAMLprim value ko_vt_scroll(value v,value delta) {
  CAMLparam2(v,delta);
  ghostty_terminal_scroll_viewport(T(v),(GhosttyTerminalScrollViewport){
    .tag=GHOSTTY_SCROLL_VIEWPORT_DELTA,.value.delta=Long_val(delta)});
  CAMLreturn(Val_unit);
}
CAMLprim value ko_vt_bottom(value v) {
  CAMLparam1(v);
  GhosttyTerminalScrollbar before={0},after={0};
  check(ghostty_terminal_get(T(v),GHOSTTY_TERMINAL_DATA_SCROLLBAR,&before));
  ghostty_terminal_scroll_viewport(T(v),(GhosttyTerminalScrollViewport){.tag=GHOSTTY_SCROLL_VIEWPORT_BOTTOM});
  check(ghostty_terminal_get(T(v),GHOSTTY_TERMINAL_DATA_SCROLLBAR,&after));
  CAMLreturn(Val_bool(before.offset!=after.offset));
}
CAMLprim value ko_vt_hold_id(value v) {
  CAMLparam1(v);struct terminal *s=live(v);CAMLreturn(Val_long(s->held?s->hold_id:0));
}
CAMLprim value ko_vt_render_delay(value v) {
  CAMLparam1(v);struct terminal *s=live(v);
  double remaining=s->held?HOLD_SECONDS-(monotonic()-s->hold_started):0;
  CAMLreturn(caml_copy_double(remaining>0?remaining:0));
}
CAMLprim value ko_vt_render(value v) {
  CAMLparam1(v); CAMLlocal4(result,array,cell,text);CAMLlocal2(fg_colour,bg_colour);
  struct terminal *s=live(v);
  if(!s->render) check(ghostty_render_state_new(NULL,&s->render));
  if(!s->rows) check(ghostty_render_state_row_iterator_new(NULL,&s->rows));
  if(!s->cells) check(ghostty_render_state_row_cells_new(NULL,&s->cells));
  check(s->render_error);
  if(s->held && monotonic()-s->hold_started>=HOLD_SECONDS) {
    GhosttyTerminalModeConfig sync={.mode=2026,.value=false};
    check(ghostty_terminal_set(s->vt,GHOSTTY_TERMINAL_OPT_MODE,&sync));s->held=false;
  }
  if(!s->held) check(ghostty_render_state_update(s->render,s->vt));
  uint16_t cols=0,rows=0;
  check(ghostty_render_state_get(s->render,GHOSTTY_RENDER_STATE_DATA_COLS,&cols));
  check(ghostty_render_state_get(s->render,GHOSTTY_RENDER_STATE_DATA_ROWS,&rows));
  array=caml_alloc((mlsize_t)cols*rows,0);
  for(size_t i=0;i<(size_t)cols*rows;i++) Store_field(array,i,Val_unit);
  check(ghostty_render_state_get(s->render,GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,&s->rows));
  size_t i=0;
  while(ghostty_render_state_row_iterator_next(s->rows)) {
    check(ghostty_render_state_row_get(s->rows,GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,&s->cells));
    while(ghostty_render_state_row_cells_next(s->cells)) {
      GhosttyCell raw=0; GhosttyCellWide wide=0; GhosttyCellContentTag tag=0;
      GhosttyStyle style={.size=sizeof(style)};
      check(ghostty_render_state_row_cells_get(s->cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,&raw));
      check(ghostty_render_state_row_cells_get(s->cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,&style));
      check(ghostty_cell_get(raw,GHOSTTY_CELL_DATA_WIDE,&wide));
      check(ghostty_cell_get(raw,GHOSTTY_CELL_DATA_CONTENT_TAG,&tag));
      int bg=style_color(style.bg_color);
      if(tag==GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE) {
        GhosttyColorPaletteIndex index=0;check(ghostty_cell_get(raw,GHOSTTY_CELL_DATA_COLOR_PALETTE,&index));bg=index;
      } else if(tag==GHOSTTY_CELL_CONTENT_BG_COLOR_RGB) {
        GhosttyColorRgb rgb={0};check(ghostty_cell_get(raw,GHOSTTY_CELL_DATA_COLOR_RGB,&rgb));
        bg=pack_rgb(rgb);
      }
      uint8_t local[128]; GhosttyBuffer buf={.ptr=local,.cap=sizeof(local)};
      GhosttyResult r=ghostty_render_state_row_cells_get(s->cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,&buf);
      uint8_t *large=NULL;
      if(r==GHOSTTY_OUT_OF_SPACE) {
        large=malloc(buf.len);if(!large)caml_raise_out_of_memory();buf.ptr=large;buf.cap=buf.len;
        r=ghostty_render_state_row_cells_get(s->cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,&buf);
      }
      if(r!=GHOSTTY_SUCCESS){free(large);check(r);}
      text=caml_alloc_initialized_string(buf.len,(const char *)buf.ptr);free(large);
      fg_colour=colour(style_color(style.fg_color));bg_colour=colour(bg);
      cell=caml_alloc_tuple(5);Store_field(cell,0,text);
      Store_field(cell,1,Val_int(wide==GHOSTTY_CELL_WIDE_WIDE?2:wide==GHOSTTY_CELL_WIDE_SPACER_TAIL?0:1));
      Store_field(cell,2,fg_colour);Store_field(cell,3,bg_colour);
      Store_field(cell,4,Val_int(style.bold | (style.italic<<1) | ((style.underline!=0)<<2) | (style.inverse<<3)
        | (style.faint<<4) | (style.blink<<5) | (style.invisible<<6) | (style.strikethrough<<7) | (style.overline<<8)));
      if(i>=(size_t)cols*rows)caml_failwith("render cell count");Store_field(array,i++,cell);
    }
  }
  if(i!=(size_t)cols*rows)caml_failwith("render cell count");
  GhosttyRenderStateCursor cursor={.size=sizeof(cursor)};
  check(ghostty_render_state_get(s->render,GHOSTTY_RENDER_STATE_DATA_CURSOR,&cursor));
  bool tracking=false;int mouse=0;uint8_t keyboard=0;
  check(ghostty_terminal_get(s->vt,GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,&tracking));
  if(tracking) {
    GhosttyTerminalModeConfig any={.mode=1003},button={.mode=1002};
    check(ghostty_terminal_get(s->vt,GHOSTTY_TERMINAL_DATA_MODE,&any));
    check(ghostty_terminal_get(s->vt,GHOSTTY_TERMINAL_DATA_MODE,&button));
    mouse=any.value?3:button.value?2:1;
  }
  check(ghostty_terminal_get(s->vt,GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS,&keyboard));
  check(ghostty_render_state_clean(s->render));
  result=caml_alloc_tuple(9);
  Store_field(result,0,Val_int(cols));Store_field(result,1,Val_int(rows));Store_field(result,2,array);
  Store_field(result,3,Val_int(cursor.viewport_has_value?cursor.viewport_x:0));
  Store_field(result,4,Val_int(cursor.viewport_has_value?cursor.viewport_y:0));
  Store_field(result,5,Val_bool(cursor.viewport_has_value&&cursor.visible));
  Store_field(result,6,Val_int(cursor.visual_style));Store_field(result,7,Val_int(mouse));
  Store_field(result,8,Val_int(keyboard));
  CAMLreturn(result);
}
CAMLprim value ko_vt_total_rows(value v) {
  CAMLparam1(v); size_t rows=0;
  check(ghostty_terminal_get(T(v),GHOSTTY_TERMINAL_DATA_TOTAL_ROWS,&rows));CAMLreturn(Val_long(rows));
}
