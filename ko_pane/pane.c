#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include "protocol.h"
#include "buffer.h"
#include "snapshot_cut.h"
#include <ghostty/vt.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

struct pane {
  struct ko_ring *ring; uint64_t head,offset; GhosttyTerminal vt;
  int master,alive,stopping,eof,callbacks,reaped,status,full,depth; pid_t pid; uint32_t serial;
  struct ko_buffer input,output,pty_input,events,deferred;
};
static int sigchld[2]={-1,-1};
static void on_sigchld(int signo) {
  (void)signo;int saved=errno;ssize_t n=write(sigchld[1],"",1);(void)n;errno=saved;
}
static int frame(struct ko_buffer *b,unsigned kind,const void *p,size_t n) {
  uint8_t h[5];ko_put(h,n+1,4);h[4]=kind;
  return ko_append(b,h,5)||ko_append(b,p,n);
}
static int flush(int fd,struct ko_buffer *b) {
  while(b->pos<b->n) {
    ssize_t n=write(fd,b->p+b->pos,b->n-b->pos);
    if(n>0)b->pos+=(size_t)n;
    else if(n<0&&errno==EINTR)continue;
    else if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK))return 0;
    else return -1;
  }
  b->pos=b->n=0;return 0;
}
static uint8_t *at_head(struct pane *p) { return p->ring->data+p->head%p->ring->capacity; }
static void put_record(struct pane *p,unsigned kind,size_t n) {
  uint64_t before=p->head;uint8_t *b=at_head(p);
  b[0]=kind;ko_put(b+1,n,4);ko_put(b+5,p->offset,8);
  p->head+=KO_HEADER+n;
  if(kind==KO_BYTES)p->offset+=n;
  atomic_store(&p->ring->head,p->head);
  if(atomic_load(&p->ring->tail)==before){uint8_t h[8];ko_put(h,p->head,8);if(frame(&p->output,KO_HEAD,h,8))p->stopping=1;}
}
static size_t available(struct pane *p) {
  uint64_t tail=atomic_load(&p->ring->tail);
  if(tail>p->head||p->head-tail>p->ring->capacity){p->stopping=1;return 0;}
  uint64_t free=p->ring->capacity-(p->head-tail);
  size_t end=p->ring->capacity-p->head%p->ring->capacity;
  if(end<=2*KO_HEADER) {
    if(free<end)return 0;
    put_record(p,KO_PAD,end-KO_HEADER);free-=end;end=p->ring->capacity;
  }
  size_t n=free<end?free:end;
  if(n<=2*KO_HEADER)return 0;
  return n-2*KO_HEADER;
}
static void announce_full(struct pane *p) {
  if(p->full)return;
  p->full=1;uint8_t b[8];ko_put(b,atomic_load(&p->ring->tail),8);
  if(frame(&p->output,KO_FULL,b,8))p->stopping=1;
}
static void commit(struct pane *p,unsigned kind,size_t n) {
  put_record(p,kind,n);
  if(p->events.n){if(ko_append(&p->output,p->events.p,p->events.n))p->stopping=1;p->events.n=0;}
}
static void reply(GhosttyTerminal t,void *ud,const uint8_t *b,size_t n) {
  (void)t;struct pane *p=ud;if(ko_append(&p->pty_input,b,n))p->stopping=1;
}
static void string_event(struct pane *p,unsigned kind,GhosttyString s) {
  uint8_t b[4];ko_put(b,s.len,4);
  uint8_t h[5];ko_put(h,s.len+5,4);h[4]=kind;
  if(ko_append(&p->events,h,5)||ko_append(&p->events,b,4)||ko_append(&p->events,s.ptr,s.len))p->stopping=1;
}
static void title(GhosttyTerminal t,void *ud) {
  GhosttyString s={0};ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_TITLE,&s);string_event(ud,KO_TITLE,s);
}
static void pwd(GhosttyTerminal t,void *ud) {
  GhosttyString s={0};ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_PWD,&s);string_event(ud,KO_PWD,s);
}
static void prompt(GhosttyTerminal t,void *ud,const GhosttyTerminalSemanticPrompt *e) {
  (void)t;struct pane *p=ud;struct ko_buffer b={0};uint8_t h[10];
  h[0]=e->kind;h[1]=e->has_exit_code;ko_put(h+2,(uint32_t)e->exit_code,4);ko_put(h+6,e->command.len,4);
  if(ko_append(&b,h,10)||ko_append(&b,e->command.ptr,e->command.len)||frame(&p->events,KO_PROMPT,b.p,b.n))p->stopping=1;
  free(b.p);
}
static void record(GhosttyTerminal t,void *ud,const GhosttyTerminalProgramStatus *e) {
  (void)t;struct pane *p=ud;struct ko_buffer b={0};uint8_t h[7];
  ko_put(h,++p->serial,4);h[4]=e->state;h[5]=e->kind;h[6]=(uint8_t)e->progress;int failed=ko_append(&b,h,7);
  GhosttyString strings[]={e->id,e->app,e->title,e->message};
  for(unsigned i=0;i<4;i++){uint8_t len[4];ko_put(len,strings[i].len,4);
    failed|=ko_append(&b,len,4)||ko_append(&b,strings[i].ptr,strings[i].len);}
  if(failed||frame(&p->events,KO_RECORD,b.p,b.n))p->stopping=1;
  free(b.p);
}
struct cursor {const uint8_t *p;size_t n;int error;};
static uint64_t number(struct cursor *c,unsigned n) {
  if(c->error||c->n<n){c->error=1;return 0;}uint64_t v=ko_get(c->p,n);c->p+=n;c->n-=n;return v;
}
static char *string(struct cursor *c) {
  size_t n=number(c,4);if(c->error||n>c->n||memchr(c->p,0,n)){c->error=1;return NULL;}
  char *s=malloc(n+1);if(!s){c->error=1;return NULL;}memcpy(s,c->p,n);s[n]=0;c->p+=n;c->n-=n;return s;
}
static char **strings(struct cursor *c) {
  size_t count=number(c,4);if(count>4096){c->error=1;return NULL;}
  char **v=calloc(count+1,sizeof(char *));if(!v){c->error=1;return NULL;}
  for(size_t i=0;i<count&&!c->error;i++)v[i]=string(c);return v;
}
static void free_strings(char **v){if(v){for(size_t i=0;v[i];i++)free(v[i]);free(v);}}
static int init(struct pane *p,const uint8_t *b,size_t n) {
  struct cursor c={b,n,0};unsigned version=number(&c,2);
  uint16_t cols=number(&c,2),rows=number(&c,2),cw=number(&c,2),ch=number(&c,2);
  size_t scrollback=number(&c,8),apc=number(&c,8);uint64_t kitty=number(&c,8);
  unsigned media=number(&c,1);size_t continuation=number(&c,8);
  char *cwd=string(&c);char **argv=strings(&c),**env=strings(&c);char *id=string(&c);
  int result=-1,slave=-1;struct winsize size={.ws_row=rows,.ws_col=cols,.ws_xpixel=cols*cw,.ws_ypixel=rows*ch};
  if(c.error||c.n||version!=1||!cols||!rows||!argv||!argv[0]||argv[0][0]!='/')goto done;
  if(ghostty_terminal_new(NULL,&p->vt,cols,rows)!=GHOSTTY_SUCCESS)goto done;
  ghostty_terminal_resize(p->vt,cols,rows,cw,ch);
  ghostty_terminal_set(p->vt,GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,&scrollback);
  ghostty_terminal_set(p->vt,GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES,&apc);
  ghostty_terminal_set(p->vt,GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,&kitty);
  ghostty_terminal_set(p->vt,GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES,&continuation);
  bool enabled=(media&1)!=0;ghostty_terminal_set(p->vt,GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE,&enabled);
  const char *tmp=getenv("TMPDIR");if(!tmp||!*tmp)tmp="/tmp";
  GhosttyString tmpdir={(const uint8_t *)tmp,strlen(tmp)};
  ghostty_terminal_set(p->vt,GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE,media&2?&tmpdir:NULL);
  enabled=(media&4)!=0;ghostty_terminal_set(p->vt,GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM,&enabled);
  ghostty_terminal_set(p->vt,GHOSTTY_TERMINAL_OPT_USERDATA,p);
  ghostty_terminal_set(p->vt,GHOSTTY_TERMINAL_OPT_WRITE_PTY,reply);
  if(p->callbacks){
    ghostty_terminal_set(p->vt,GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,title);
    ghostty_terminal_set(p->vt,GHOSTTY_TERMINAL_OPT_PWD_CHANGED,pwd);
    ghostty_terminal_set(p->vt,GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT,prompt);
    ghostty_terminal_set(p->vt,GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS,record);
  }
  if(openpty(&p->master,&slave,NULL,NULL,&size)<0)goto done;
  p->pid=fork();
  if(p->pid==0) {
    if(setsid()<0||ioctl(slave,TIOCSCTTY,0)<0||dup2(slave,0)<0||dup2(slave,1)<0||dup2(slave,2)<0||chdir(cwd)<0)_exit(126);
    close(slave);close(p->master);close(3);
    signal(SIGPIPE,SIG_DFL);signal(SIGHUP,SIG_DFL);signal(SIGINT,SIG_DFL);signal(SIGTERM,SIG_DFL);
    execve(argv[0],argv,env);_exit(127);
  }
  if(p->pid<0)goto done;
  fcntl(p->master,F_SETFL,O_NONBLOCK);fcntl(p->master,F_SETFD,FD_CLOEXEC);
  p->alive=1;uint8_t pid[4];ko_put(pid,p->pid,4);frame(&p->output,KO_READY,pid,4);result=0;
done:
  if(slave>=0)close(slave);free(cwd);free(id);free_strings(argv);free_strings(env);return result;
}
static int control(struct pane *p,int snapshots);
static int wait_space(struct pane *p,size_t minimum) {
  while(available(p)<minimum&&!p->stopping){
    announce_full(p);
    struct pollfd f={0,POLLIN|(p->output.n?POLLOUT:0),0};
    if(poll(&f,1,-1)<0){if(errno==EINTR)continue;return -1;}
    if(flush(1,&p->output))return -1;
    if(f.revents&(POLLIN|POLLHUP|POLLERR)&&control(p,0))return -1;
  }
  return p->stopping?-1:0;
}
struct slices {struct pane *p;size_t used,room;int first,screen;};
static void slice_commit(struct slices *s) {
  if(!s->room)return;
  uint8_t *dst=at_head(s->p)+KO_HEADER;
  dst[0]=s->first?1:0;dst[1]=s->screen?1:0;s->first=0;
  commit(s->p,KO_SNAPSHOT_SLICE,s->used+2);s->used=s->room=0;
}
static int slice_emit(void *ud,const uint8_t *b,size_t n) {
  struct slices *s=ud;
  while(n) {
    if(s->used==s->room){slice_commit(s);if(wait_space(s->p,3))return -1;s->room=available(s->p)-2;}
    size_t take=s->room-s->used;if(take>n)take=n;
    memcpy(at_head(s->p)+KO_HEADER+2+s->used,b,take);
    s->used+=take;b+=take;n-=take;
  }
  return 0;
}
static int snapshot(struct pane *p,const uint8_t *b,size_t n) {
  struct cursor c={b,n,0};uint32_t req=number(&c,4);
  int screen=number(&c,1),images=number(&c,1);char *file=string(&c);
  if(c.error||c.n||!file||*file){free(file);return -1;}free(file);
  struct ko_cut cut={.screen=screen,.images=images};
  struct slices s={.p=p,.first=1,.screen=screen};
  if(ko_snapshot_encode(p->vt,&cut,slice_emit,&s)!=GHOSTTY_SUCCESS)return -1;
  slice_commit(&s);
  if(wait_space(p,2))return -1;
  uint8_t *dst=at_head(p)+KO_HEADER;dst[0]=2;dst[1]=screen?1:0;
  commit(p,KO_SNAPSHOT_SLICE,2);uint8_t q[4];ko_put(q,req,4);return frame(&p->output,KO_SNAPSHOT_DONE,q,4);
}
static int dispatch(struct pane *p,unsigned kind,const uint8_t *b,size_t n,int snapshots) {
  if(!p->vt)return kind==KO_INIT?init(p,b,n):-1;
  switch(kind) {
  case KO_TAIL:if(n!=8)return -1;p->full=0;return 0;
  case KO_TEXT:return ko_append(&p->pty_input,b,n);
  case KO_RESIZE:{if(n!=8)return -1;
    uint16_t cols=ko_get(b,2),rows=ko_get(b+2,2),cw=ko_get(b+4,2),ch=ko_get(b+6,2);
    if(wait_space(p,8))return -1;
    if(ghostty_terminal_resize(p->vt,cols,rows,cw,ch)!=GHOSTTY_SUCCESS)return -1;
    struct winsize size={.ws_row=rows,.ws_col=cols,.ws_xpixel=cols*cw,.ws_ypixel=rows*ch};
    ioctl(p->master,TIOCSWINSZ,&size);
    uint8_t *marker=at_head(p)+KO_HEADER;ko_put(marker,cols,2);ko_put(marker+2,rows,2);ko_put(marker+4,cw,2);ko_put(marker+6,ch,2);
    commit(p,KO_MARKER,8);return 0;}
  case KO_SNAPSHOT:return snapshots?snapshot(p,b,n):-1;
  case KO_EXIT:p->stopping=1;return 0;
  default:return -1;
  }
}
static int run_deferred(struct pane *p) {
  struct ko_buffer pending=p->deferred;p->deferred=(struct ko_buffer){0};
  int r=0;
  for(size_t pos=0;!r&&pos<pending.n;){size_t size=ko_get(pending.p+pos,4)+4;
    r=dispatch(p,pending.p[pos+4],pending.p+pos+5,size-5,1);pos+=size;}
  free(pending.p);return r;
}
static int control(struct pane *p,int snapshots) {
  int eof=0;
  for(;;){
    if(p->input.n-p->input.pos>=KO_MAX_FRAME+4||ko_reserve(&p->input,65536))return -1;
    ssize_t n=read(0,p->input.p+p->input.n,p->input.cap-p->input.n);
    if(n>0)p->input.n+=(size_t)n;
    else if(n==0){eof=1;break;}
    else if(errno==EINTR)continue;
    else if(errno==EAGAIN||errno==EWOULDBLOCK)break;
    else return -1;
  }
  p->depth++;
  int failed=0;
  while(!failed&&p->input.n-p->input.pos>=4){size_t size;
    int complete=ko_frame_size(p->input.p+p->input.pos,p->input.n-p->input.pos,&size);
    if(complete<0){failed=1;break;}if(!complete)break;
    size_t at=p->input.pos;p->input.pos+=size;unsigned kind=p->input.p[at+4];
    if(!snapshots&&kind!=KO_TAIL&&kind!=KO_EXIT)failed=ko_append(&p->deferred,p->input.p+at,size);
    else failed=dispatch(p,kind,p->input.p+at+5,size-5,snapshots);
    if(failed)fprintf(stderr,"control frame %u failed (%zu bytes)\n",kind,size-5);
  }
  if(--p->depth==0){memmove(p->input.p,p->input.p+p->input.pos,p->input.n-p->input.pos);p->input.n-=p->input.pos;p->input.pos=0;}
  while(!failed&&snapshots&&p->deferred.n)failed=run_deferred(p);
  if(failed)return -1;
  if(eof)p->stopping=1;
  return 0;
}
static void read_pty(struct pane *p,int *drained) {
  size_t room=available(p),used=0;
  if(!room){announce_full(p);return;}
  uint8_t *dst=at_head(p)+KO_HEADER;
  while(used<room){ssize_t got=read(p->master,dst+used,room-used);
    if(got>0)used+=(size_t)got;
    else if(got<0&&errno==EINTR)continue;
    else {if(got==0||(got<0&&errno==EIO))p->eof=1;*drained=1;break;}
  }
  if(used){ghostty_terminal_vt_write(p->vt,dst,used);commit(p,KO_BYTES,used);}
}
int main(int argc,char **argv) {
  signal(SIGPIPE,SIG_IGN);struct stat st;if(fstat(3,&st)||st.st_size<(off_t)(sizeof(struct ko_ring)+64))return 2;
  struct pane p={.master=-1,.callbacks=!(argc==2&&!strcmp(argv[1],"--no-callbacks"))};
  p.ring=mmap(NULL,st.st_size,PROT_READ|PROT_WRITE,MAP_SHARED,3,0);
  if(p.ring==MAP_FAILED||p.ring->capacity>(uint64_t)st.st_size-sizeof(struct ko_ring)||p.ring->capacity<64)return 2;
  if(pipe(sigchld))return 2;
  for(int i=0;i<2;i++){fcntl(sigchld[i],F_SETFL,O_NONBLOCK);fcntl(sigchld[i],F_SETFD,FD_CLOEXEC);}
  struct sigaction action={.sa_handler=on_sigchld,.sa_flags=SA_RESTART|SA_NOCLDSTOP};
  sigemptyset(&action.sa_mask);if(sigaction(SIGCHLD,&action,NULL))return 2;
  fcntl(0,F_SETFL,O_NONBLOCK);fcntl(1,F_SETFL,O_NONBLOCK);
  int failure=0;
  while(!p.stopping){
    int reading=p.vt&&!p.eof&&!p.full;
    struct pollfd f[3]={{0,POLLIN|(p.output.n?POLLOUT:0),0},
      {reading||p.pty_input.n?p.master:-1,(reading?POLLIN:0)|(p.pty_input.n?POLLOUT:0),0},
      {sigchld[0],POLLIN,0}};
    if(poll(f,3,-1)<0){if(errno==EINTR)continue;failure=1;break;}
    if(f[0].revents&(POLLIN|POLLHUP|POLLERR)&&control(&p,1)){fprintf(stderr,"pane control failed\n");failure=1;break;}
    if(p.master>=0&&flush(p.master,&p.pty_input)){p.pty_input.n=p.pty_input.pos=0;}
    if(f[2].revents&POLLIN){char drain[64];while(read(sigchld[0],drain,sizeof(drain))>0){}
      if(p.alive&&!p.reaped&&waitpid(p.pid,&p.status,WNOHANG)==p.pid)p.reaped=1;}
    int drained=p.eof;
    if(p.vt&&!p.eof&&(f[1].revents&(POLLIN|POLLHUP|POLLERR)||p.reaped))read_pty(&p,&drained);
    if(p.reaped&&drained){p.alive=p.reaped=0;uint8_t b[8];
      ko_put(b,WIFEXITED(p.status)?WEXITSTATUS(p.status):0,4);
      ko_put(b+4,WIFSIGNALED(p.status)?WTERMSIG(p.status):0,4);frame(&p.output,KO_DEAD,b,8);}
    if(flush(1,&p.output)){failure=1;break;}
  }
  if(p.alive&&!p.reaped){kill(-p.pid,SIGHUP);struct timespec start,now;clock_gettime(CLOCK_MONOTONIC,&start);
    for(;;){if(waitpid(p.pid,NULL,WNOHANG)==p.pid)break;clock_gettime(CLOCK_MONOTONIC,&now);
      if((now.tv_sec-start.tv_sec)*1000000000L+now.tv_nsec-start.tv_nsec>=500000000L){kill(-p.pid,SIGKILL);waitpid(p.pid,NULL,0);break;}
      poll(NULL,0,5);
    }
  }
  if(p.master>=0)close(p.master);
  if(p.vt)ghostty_terminal_free(p.vt);munmap(p.ring,st.st_size);
  free(p.input.p);free(p.output.p);free(p.pty_input.p);free(p.events.p);free(p.deferred.p);return failure?2:0;
}
