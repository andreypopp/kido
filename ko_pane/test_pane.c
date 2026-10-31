#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include "protocol.h"
#include "pixels.h"
#include "ring.h"
#include <ghostty/vt.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>

static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void write_all(int fd,const void *ptr,size_t len){
  const uint8_t *p=ptr;double deadline=now()+10;
  while(len){assert(now()<deadline);ssize_t n=write(fd,p,len);
    if(n>0){p+=n;len-=n;}else if(errno==EINTR)continue;else{assert(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK));struct pollfd f={fd,POLLOUT,0};poll(&f,1,10);}}
}
static void frame(int fd,unsigned kind,const void *b,size_t n){uint8_t h[5];ko_put(h,n+1,4);h[4]=kind;write_all(fd,h,5);if(n)write_all(fd,b,n);}
struct data {uint8_t b[65536];size_t n;};
static void bytes(struct data *d,const void *b,size_t n){assert(d->n+n<=sizeof(d->b));memcpy(d->b+d->n,b,n);d->n+=n;}
static void num(struct data *d,uint64_t v,unsigned n){uint8_t b[8];ko_put(b,v,n);bytes(d,b,n);}
static void str(struct data *d,const char *s){num(d,strlen(s),4);bytes(d,s,strlen(s));}
static unsigned receive(int fd,struct data *d){
  uint8_t h[4];size_t pos=0;double deadline=now()+10;
  while(pos<4){assert(now()<deadline);struct pollfd f={fd,POLLIN,0};poll(&f,1,10);ssize_t n=read(fd,h+pos,4-pos);if(n>0)pos+=n;else assert(n<0&&(errno==EAGAIN||errno==EINTR));}
  size_t size=ko_get(h,4);assert(size&&size<=sizeof(d->b));pos=0;
  while(pos<size){assert(now()<deadline);ssize_t n=read(fd,d->b+pos,size-pos);if(n>0)pos+=n;else{assert(n<0&&(errno==EAGAIN||errno==EINTR));struct pollfd f={fd,POLLIN,0};poll(&f,1,10);}}
  unsigned kind=d->b[0];memmove(d->b,d->b+1,size-1);d->n=size-1;return kind;
}
static bool collect(void *ud,const uint8_t *b,size_t n){struct data *d=ud;bytes(d,b,n);return true;}
static void row_text(GhosttyTerminal vt,uint32_t row,char *out,size_t cap){
  GhosttyFormatterTerminalOptions options={.size=sizeof(options),.emit=GHOSTTY_FORMATTER_FORMAT_PLAIN,.trim=true};
  options.extra.size=sizeof(options.extra);options.extra.screen.size=sizeof(options.extra.screen);
  GhosttySelection selection={.size=sizeof(selection)};
  assert(ghostty_terminal_grid_ref(vt,(GhosttyPoint){.tag=GHOSTTY_POINT_TAG_ACTIVE,.value.coordinate={0,row}},&selection.start)==GHOSTTY_SUCCESS);
  assert(ghostty_terminal_grid_ref(vt,(GhosttyPoint){.tag=GHOSTTY_POINT_TAG_ACTIVE,.value.coordinate={39,row}},&selection.end)==GHOSTTY_SUCCESS);
  options.selection=&selection;GhosttyFormatter f;
  assert(ghostty_formatter_terminal_new(NULL,&f,vt,options)==GHOSTTY_SUCCESS);
  static struct data text;text.n=0;
  assert(ghostty_formatter_format(f,(GhosttyWriter){collect,&text})==GHOSTTY_SUCCESS);ghostty_formatter_free(f);
  assert(text.n<cap);memcpy(out,text.b,text.n);out[text.n]=0;
}
int main(int argc,char **argv){
  assert(argc==2);signal(SIGPIPE,SIG_IGN);alarm(30);
  size_t capacity=4096,size=sizeof(struct ko_ring)+capacity;
  struct ko_ring *ring=NULL;
  int fd=ko_ring_create(capacity,&ring);
  if(fd<0)return 2;
  int sockets[2];assert(!socketpair(AF_UNIX,SOCK_STREAM,0,sockets));
  pid_t child=fork();assert(child>=0);
  if(!child){assert(dup2(sockets[1],0)>=0);assert(dup2(sockets[1],1)>=0);assert(dup2(fd,3)>=0);assert(!fcntl(3,F_SETFD,0));
    for(int i=4;i<32;i++)close(i);execl(argv[1],argv[1],NULL);perror("exec pane");_exit(127);}
  close(sockets[1]);close(fd);int control=sockets[0];fcntl(control,F_SETFL,O_NONBLOCK);
  struct data d={0};num(&d,3,2);num(&d,80,2);num(&d,24,2);num(&d,8,2);num(&d,16,2);
  num(&d,1,1);num(&d,32*1024*1024,8);num(&d,0,1);num(&d,0,8);num(&d,65*1024*1024,8);num(&d,32*1024*1024,8);num(&d,0,1);num(&d,65*1024*1024,8);
  str(&d,"/");num(&d,3,4);str(&d,"/bin/sh");str(&d,"-c");
  str(&d,"printf '\033]2;ko test\007\033]7;file://localhost/tmp\007\033]133;A\007\033]133;C;cmdline_url=echo\007\033]133;D;7\007\033]7501;state=working:app=ko\007\033[?2026h'; i=0; while [ $i -lt 200 ]; do printf '\033]8;;https://example.org\033\\line %s\033]8;;\033\\\r\n' $i; i=$((i+1)); done");
  num(&d,1,4);str(&d,"TERM=xterm-ghostty");str(&d,"pane_1");frame(control,KO_INIT,d.b,d.n);
  uint64_t tail=0,offset=0;int ready=0,dead=0,title=0,pwd=0,snapshot_done=0,markers=0,fulls=0;
  uint8_t *snapshot=NULL;size_t snapshot_len=0,marker_cols=0,marker_rows=0;
  while(!snapshot_done){unsigned kind=receive(control,&d);
    int drain=kind==KO_FULL||kind==KO_DEAD||kind==KO_SNAPSHOT_DONE;
    for(uint64_t head;drain;drain=atomic_load(&ring->head)!=head){
      head=atomic_load(&ring->head);
      while(tail<head){size_t pos=tail%capacity;assert(capacity-pos>=KO_HEADER);uint8_t *b=ring->data+pos;
        size_t len=ko_get(b+1,4);assert(len+KO_HEADER<=capacity-pos);assert(ko_get(b+5,8)==offset);
        if(b[0]==KO_BYTES)offset+=len;
        else if(b[0]==KO_MARKER){if(b[KO_HEADER]==1){assert(len==9);markers++;marker_cols=ko_get(b+KO_HEADER+1,2);marker_rows=ko_get(b+KO_HEADER+3,2);}else assert(b[KO_HEADER]==2&&len==17);}
        else if(b[0]==KO_SNAPSHOT_SLICE){assert(len>=2);size_t n=len-2;void *p=realloc(snapshot,snapshot_len+n);assert(p||!n);snapshot=p;memcpy(snapshot+snapshot_len,b+KO_HEADER+2,n);snapshot_len+=n;}
        else assert(b[0]==KO_PAD);
        tail+=KO_HEADER+len;
      }
      atomic_store(&ring->tail,tail);atomic_store(&ring->read,tail);
    }
    if(kind==KO_READY){ready++;assert(d.n==4);}
    else if(kind==KO_HEAD)assert(d.n==8);
    else if(kind==KO_FULL){fulls++;assert(d.n==8);uint8_t b[8];ko_put(b,tail,8);frame(control,KO_TAIL,b,8);}
    else if(kind==KO_TITLE)title++;
    else if(kind==KO_PWD)pwd++;
    else if(kind==KO_DEAD){dead++;assert(d.n==16&&ko_get(d.b,8)==0&&ko_get(d.b+8,8)>0);
      uint8_t resize[8];ko_put(resize,40,2);ko_put(resize+2,20,2);ko_put(resize+4,8,2);ko_put(resize+6,16,2);frame(control,KO_RESIZE,resize,8);
      uint8_t request[10]={0};ko_put(request,1,4);request[4]=1;frame(control,KO_SNAPSHOT,request,10);
    }
    else if(kind==KO_SNAPSHOT_DONE)snapshot_done++;
    else assert(!"unexpected frame");
  }
  assert(ready==1&&dead==1&&title==1&&pwd==1&&markers==1&&fulls>0&&offset>8000&&snapshot_len>10);
  assert(marker_cols==40&&marker_rows==20);
  GhosttySnapshotDecoder decoder=NULL;GhosttyTerminal vt=NULL;
  assert(ghostty_snapshot_decoder_new_buf(NULL,&decoder,snapshot,snapshot_len)==GHOSTTY_SUCCESS);
  assert(ghostty_snapshot_decoder_ready(decoder,&vt)==GHOSTTY_SUCCESS);
  GhosttyTerminalModeConfig mode={.mode=GHOSTTY_MODE_SYNC_OUTPUT};assert(ghostty_terminal_get(vt,GHOSTTY_TERMINAL_DATA_MODE,&mode)==GHOSTTY_SUCCESS&&!mode.value);
  uint16_t cols=0,rows=0,y=0;
  assert(ghostty_terminal_get(vt,GHOSTTY_TERMINAL_DATA_COLS,&cols)==GHOSTTY_SUCCESS&&cols==40);
  assert(ghostty_terminal_get(vt,GHOSTTY_TERMINAL_DATA_ROWS,&rows)==GHOSTTY_SUCCESS&&rows==20);
  assert(ghostty_terminal_get(vt,GHOSTTY_TERMINAL_DATA_CURSOR_Y,&y)==GHOSTTY_SUCCESS&&y==19);
  char last[64];row_text(vt,18,last,sizeof(last));assert(!strcmp(last,"line 199"));
  row_text(vt,0,last,sizeof(last));assert(!strcmp(last,"line 181"));
  ghostty_snapshot_decoder_free(decoder);ghostty_terminal_free(vt);free(snapshot);
  frame(control,KO_EXIT,NULL,0);close(control);int status;assert(waitpid(child,&status,0)==child&&WIFEXITED(status)&&WEXITSTATUS(status)==0);
  munmap(ring,size);
  assert(ko_pixels(65535, 65535) == 65535 && ko_pixels(80, 8) == 640 && ko_pixels(0, 8) == 0);
  puts("PASS ring full and wrap, callbacks, 40x20 resize marker and screen, dead master snapshot, mode 2026 cleared");return 0;
}
