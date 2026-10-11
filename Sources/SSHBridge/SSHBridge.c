#include "SSHBridge.h"
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/socket.h>

struct MXSSH { LIBSSH2_SESSION *session; LIBSSH2_SFTP *sftp; int fd; atomic_bool cancelled; char error[512]; double deadline; };
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void initialize(void) { libssh2_init(0); }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static void begin(MXSSH *s) { s->deadline = now() + 15; }
static int fail(MXSSH *s, const char *operation, int code) {
    char *message = NULL;
    if(s->session) libssh2_session_last_error(s->session, &message, NULL, 0);
    if(s->sftp && code == LIBSSH2_ERROR_SFTP_PROTOCOL)
        snprintf(s->error, sizeof(s->error), "%s: SFTP %lu (%s)", operation, libssh2_sftp_last_error(s->sftp), message ? message : "failed");
    else snprintf(s->error, sizeof(s->error), "%s: %s (%d)", operation, message ? message : strerror(errno), code);
    return -1;
}
static int wait_ready(MXSSH *s) {
    if(atomic_load(&s->cancelled)) { snprintf(s->error, sizeof(s->error), "操作已取消"); return -1; }
    if(now() > s->deadline) { snprintf(s->error, sizeof(s->error), "服务器响应超时"); return -1; }
    int directions = libssh2_session_block_directions(s->session);
    struct pollfd p = {s->fd, 0, 0};
    if(directions & LIBSSH2_SESSION_BLOCK_INBOUND) p.events |= POLLIN;
    if(directions & LIBSSH2_SESSION_BLOCK_OUTBOUND) p.events |= POLLOUT;
    if(!p.events) p.events = POLLIN;
    int r = poll(&p, 1, 100);
    if(r < 0 && errno != EINTR) return fail(s, "socket poll", errno);
    if(p.revents & (POLLERR | POLLNVAL)) return fail(s, "连接已中断", -1);
    return 0;
}
#define RETRY_INT(expr, label) do { begin(s); int r; while((r = (int)(expr)) == LIBSSH2_ERROR_EAGAIN) { if(wait_ready(s)) return -1; } return r < 0 ? fail(s, label, r) : r; } while(0)
static void nonblock(int fd) { fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK); fcntl(fd, F_SETFD, FD_CLOEXEC); int one=1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)); }
static int connect_socket(const char *host, int port, MXSSH *s) {
    struct addrinfo hints = {0}, *addresses = NULL; hints.ai_socktype = SOCK_STREAM; hints.ai_family = AF_UNSPEC;
    char service[8]; snprintf(service, sizeof(service), "%d", port);
    int e = getaddrinfo(host, service, &hints, &addresses);
    if(e) { if(s) snprintf(s->error, sizeof(s->error), "地址解析失败: %s", gai_strerror(e)); return -1; }
    int fd = -1;
    for(struct addrinfo *a=addresses; a; a=a->ai_next) {
        if(s && atomic_load(&s->cancelled)) break;
        fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol); if(fd < 0) continue; nonblock(fd);
        if(connect(fd, a->ai_addr, a->ai_addrlen) == 0) break;
        if(errno == EINPROGRESS) {
            double deadline = now()+10; int err=ETIMEDOUT;
            while(now()<deadline && (!s || !atomic_load(&s->cancelled))) {
                struct pollfd p={fd,POLLOUT,0}; int r=poll(&p,1,100);
                if(r>0) { socklen_t n=sizeof(err); getsockopt(fd,SOL_SOCKET,SO_ERROR,&err,&n); break; }
                if(r<0 && errno!=EINTR) break;
            }
            if(!err) break; errno=err;
        }
        close(fd); fd=-1;
    }
    freeaddrinfo(addresses); return fd;
}
MXSSH *mx_create(void) { pthread_once(&once, initialize); MXSSH *s=calloc(1,sizeof(*s)); s->fd=-1; atomic_init(&s->cancelled,0); return s; }
void mx_cancel(MXSSH *s) { atomic_store(&s->cancelled,1); }
const char *mx_error(MXSSH *s) { return s->error; }
int mx_connect(MXSSH *s,const char *host,int port) {
    s->fd=connect_socket(host,port,s); if(s->fd<0) { if(!s->error[0]) snprintf(s->error,sizeof(s->error),"连接失败: %s",strerror(errno)); return -1; }
    s->session=libssh2_session_init(); if(!s->session) return fail(s,"SSH 初始化",-1);
    libssh2_session_set_blocking(s->session,0); libssh2_session_set_timeout(s->session,15000);
    libssh2_keepalive_config(s->session,0,20);
    RETRY_INT(libssh2_session_handshake(s->session,s->fd),"SSH 握手");
}
const void *mx_hostkey(MXSSH *s,size_t *length,int *type) { return libssh2_session_hostkey(s->session,length,type); }
int mx_auth_password(MXSSH *s,const char *user,const char *password) { RETRY_INT(libssh2_userauth_password(s->session,user,password),"密码认证失败"); }
int mx_auth_key(MXSSH *s,const char *user,const char *path,const char *passphrase) { RETRY_INT(libssh2_userauth_publickey_fromfile(s->session,user,NULL,path,passphrase),"密钥认证失败（检查格式与口令）"); }
static LIBSSH2_CHANNEL *open_session(MXSSH *s) {
    begin(s); LIBSSH2_CHANNEL *c;
    while(!(c=libssh2_channel_open_session(s->session))) {
        if(libssh2_session_last_errno(s->session)!=LIBSSH2_ERROR_EAGAIN || wait_ready(s)) { fail(s,"创建终端",-1); return NULL; }
    } return c;
}
MXChannel *mx_terminal(MXSSH *s,int cols,int rows) {
    LIBSSH2_CHANNEL *c=open_session(s); if(!c) return NULL; begin(s); int r;
    while((r=libssh2_channel_request_pty_ex(c,"xterm-256color",14,NULL,0,cols,rows,0,0))==LIBSSH2_ERROR_EAGAIN) if(wait_ready(s)) goto error;
    if(r) { fail(s,"申请 PTY",r); goto error; }
    begin(s); while((r=libssh2_channel_shell(c))==LIBSSH2_ERROR_EAGAIN) if(wait_ready(s)) goto error;
    if(r) { fail(s,"启动 shell",r); goto error; } return c;
error: libssh2_channel_free(c); return NULL;
}
int mx_resize(MXSSH *s,MXChannel *c,int cols,int rows) { RETRY_INT(libssh2_channel_request_pty_size(c,cols,rows),"调整终端尺寸"); }
MXChannel *mx_exec(MXSSH *s,const char *command) {
    LIBSSH2_CHANNEL *c=open_session(s); if(!c) return NULL; begin(s); int r;
    while((r=libssh2_channel_handle_extended_data2(c,LIBSSH2_CHANNEL_EXTENDED_DATA_MERGE))==LIBSSH2_ERROR_EAGAIN) if(wait_ready(s)) goto error;
    if(r) { fail(s,"准备状态通道",r); goto error; }
    begin(s);
    while((r=libssh2_channel_exec(c,command))==LIBSSH2_ERROR_EAGAIN) if(wait_ready(s)) goto error;
    if(r) { fail(s,"执行远端命令",r); goto error; }
    return c;
error: mx_channel_free(s,c); return NULL;
}
int mx_exit_status(MXChannel *c) { return libssh2_channel_get_exit_status(c); }
struct MXCommand { LIBSSH2_CHANNEL *channel; int stage; int closing; };
MXCommand *mx_command_create(void) { return calloc(1,sizeof(MXCommand)); }
int mx_command_step(MXSSH *s,MXCommand *command,const char *text) {
    if(atomic_load(&s->cancelled)) return fail(s,"命令已取消",-1);
    int r;
    if(command->stage==0) {
        command->channel=libssh2_channel_open_session(s->session);
        if(!command->channel) {
            r=libssh2_session_last_errno(s->session);
            return r==LIBSSH2_ERROR_EAGAIN ? 1:fail(s,"创建状态通道",r);
        }
        command->stage=1;
    }
    if(command->stage==1) {
        r=libssh2_channel_handle_extended_data2(command->channel,LIBSSH2_CHANNEL_EXTENDED_DATA_MERGE);
        if(r==LIBSSH2_ERROR_EAGAIN) return 1;
        if(r) return fail(s,"准备状态通道",r);
        command->stage=2;
    }
    if(command->stage==2) {
        r=libssh2_channel_exec(command->channel,text);
        if(r==LIBSSH2_ERROR_EAGAIN) return 1;
        if(r) return fail(s,"读取服务器状态",r);
        command->stage=3;
    }
    return 0;
}
MXChannel *mx_command_channel(MXCommand *command) { return command->channel; }
int mx_command_free_step(MXSSH *s,MXCommand *command,int terminate) {
    if(!command) return 0;
    if(atomic_load(&s->cancelled)) { free(command); return 0; }
    if(command->channel) {
        if(terminate && command->stage==3 && !command->closing) {
            int r=libssh2_channel_signal(command->channel,"TERM");
            if(r==LIBSSH2_ERROR_EAGAIN) return 1;
        }
        command->closing=1;
        if(libssh2_channel_free(command->channel)==LIBSSH2_ERROR_EAGAIN) return 1;
    }
    free(command); return 0;
}
/* On a dead peer the session still owns its channel and releases it on teardown. */
void mx_command_abandon(MXCommand *command) { free(command); }
ssize_t mx_read(MXSSH *s,MXChannel *c,void *buffer,size_t count) {
    if(atomic_load(&s->cancelled)) return -1;
    ssize_t r=libssh2_channel_read(c,buffer,count);
    if(r==LIBSSH2_ERROR_EAGAIN) return -2;
    return r<0?fail(s,"读取通道",(int)r):r;
}
ssize_t mx_write(MXSSH *s,MXChannel *c,const void *buffer,size_t count) {
    begin(s); ssize_t r; while((r=libssh2_channel_write(c,buffer,count))==LIBSSH2_ERROR_EAGAIN) if(wait_ready(s)) return -1;
    return r<0?fail(s,"写入通道",(int)r):r;
}
int mx_eof(MXChannel *c) { return libssh2_channel_eof(c); }
int mx_send_eof(MXSSH *s,MXChannel *c) { RETRY_INT(libssh2_channel_send_eof(c),"关闭发送方向"); }
void mx_channel_free(MXSSH *s,MXChannel *c) {
    if(!c) return; begin(s); int r;
    while((r=libssh2_channel_free(c))==LIBSSH2_ERROR_EAGAIN) if(wait_ready(s)) break;
}
int mx_keepalive(MXSSH *s) { int next=0; RETRY_INT(libssh2_keepalive_send(s->session,&next),"连接保活失败"); }
int mx_sftp_start(MXSSH *s) {
    if(s->sftp) return 0; begin(s);
    while(!(s->sftp=libssh2_sftp_init(s->session))) {
        int r=libssh2_session_last_errno(s->session);
        if(r!=LIBSSH2_ERROR_EAGAIN) return fail(s,"服务器未提供 SFTP",r);
        if(wait_ready(s)) return -1;
    } return 0;
}
static void attrs_copy(MXAttributes *out,LIBSSH2_SFTP_ATTRIBUTES *a) { out->size=a->filesize; out->permissions=(uint32_t)a->permissions; out->modified=a->mtime; out->uid=(uint32_t)a->uid; out->gid=(uint32_t)a->gid; }
int mx_stat(MXSSH *s,const char *path,int follow,MXAttributes *out) {
    LIBSSH2_SFTP_ATTRIBUTES a={0}; begin(s); int r;
    while((r=libssh2_sftp_stat_ex(s->sftp,path,(unsigned)strlen(path),follow?LIBSSH2_SFTP_STAT:LIBSSH2_SFTP_LSTAT,&a))==LIBSSH2_ERROR_EAGAIN) if(wait_ready(s)) return -1;
    if(r) { unsigned long e=libssh2_sftp_last_error(s->sftp); if(e==LIBSSH2_FX_NO_SUCH_FILE || e==LIBSSH2_FX_NO_SUCH_PATH) return 1; return fail(s,"读取文件属性",r); }
    attrs_copy(out,&a); return 0;
}
int mx_realpath(MXSSH *s,const char *path,char *buffer,size_t count) { RETRY_INT(libssh2_sftp_realpath(s->sftp,path,buffer,(unsigned)count),"解析路径"); }
static MXFile *open_file(MXSSH *s,const char *path,unsigned long flags,unsigned long mode,int type) {
    begin(s); LIBSSH2_SFTP_HANDLE *h;
    while(!(h=libssh2_sftp_open_ex(s->sftp,path,(unsigned)strlen(path),flags,(long)mode,type))) {
        int r=libssh2_session_last_errno(s->session);
        if(r!=LIBSSH2_ERROR_EAGAIN) { fail(s,"打开远程文件",r); return NULL; }
        if(wait_ready(s)) return NULL;
    } return h;
}
MXFile *mx_opendir(MXSSH *s,const char *path) { return open_file(s,path,0,0,LIBSSH2_SFTP_OPENDIR); }
MXFile *mx_open_read(MXSSH *s,const char *path) { return open_file(s,path,LIBSSH2_FXF_READ,0,LIBSSH2_SFTP_OPENFILE); }
MXFile *mx_open_write(MXSSH *s,const char *path,unsigned long mode) { return open_file(s,path,LIBSSH2_FXF_WRITE|LIBSSH2_FXF_CREAT|LIBSSH2_FXF_EXCL,mode,LIBSSH2_SFTP_OPENFILE); }
int mx_readdir(MXSSH *s,MXFile *dir,char *buffer,size_t count,MXAttributes *out) {
    LIBSSH2_SFTP_ATTRIBUTES a={0}; begin(s); int r;
    while((r=libssh2_sftp_readdir_ex(dir,buffer,count,NULL,0,&a))==LIBSSH2_ERROR_EAGAIN) if(wait_ready(s)) return -1;
    if(r<0) return fail(s,"读取目录",r); attrs_copy(out,&a); return r;
}
ssize_t mx_file_read(MXSSH *s,MXFile *f,void *buffer,size_t count) { RETRY_INT(libssh2_sftp_read(f,buffer,count),"下载文件"); }
ssize_t mx_file_write(MXSSH *s,MXFile *f,const void *buffer,size_t count) { RETRY_INT(libssh2_sftp_write(f,buffer,count),"上传文件"); }
int mx_file_close(MXSSH *s,MXFile *f) { RETRY_INT(libssh2_sftp_close_handle(f),"关闭文件"); }
int mx_mkdir(MXSSH *s,const char *path,unsigned long mode) { RETRY_INT(libssh2_sftp_mkdir(s->sftp,path,(long)mode),"创建目录"); }
int mx_remove(MXSSH *s,const char *path) { RETRY_INT(libssh2_sftp_unlink(s->sftp,path),"删除临时文件"); }
int mx_chmod(MXSSH *s,const char *path,unsigned long mode) {
    LIBSSH2_SFTP_ATTRIBUTES a={0}; a.flags=LIBSSH2_SFTP_ATTR_PERMISSIONS; a.permissions=mode;
    RETRY_INT(libssh2_sftp_stat_ex(s->sftp,path,(unsigned)strlen(path),LIBSSH2_SFTP_SETSTAT,&a),"保留文件权限");
}
int mx_rename(MXSSH *s,const char *from,const char *to,int replace) {
    if(replace) { RETRY_INT(libssh2_sftp_posix_rename(s->sftp,from,to),"服务器无法原子替换文件，原文件保留"); }
    RETRY_INT(libssh2_sftp_rename_ex(s->sftp,from,(unsigned)strlen(from),to,(unsigned)strlen(to),0),"提交上传文件");
}
MXChannel *mx_direct(MXSSH *s,const char *host,int port) {
    begin(s); LIBSSH2_CHANNEL *c;
    while(!(c=libssh2_channel_direct_tcpip_ex(s->session,host,port,"127.0.0.1",0))) {
        int r=libssh2_session_last_errno(s->session); if(r!=LIBSSH2_ERROR_EAGAIN) { fail(s,"转发目标不可达",r); return NULL; } if(wait_ready(s)) return NULL;
    } return c;
}
MXForward *mx_forward_listen(MXSSH *s,const char *host,int port,int *bound) {
    begin(s); LIBSSH2_LISTENER *l;
    while(!(l=libssh2_channel_forward_listen_ex(s->session,host,port,bound,32))) {
        int r=libssh2_session_last_errno(s->session); if(r!=LIBSSH2_ERROR_EAGAIN) { fail(s,"服务器拒绝远程转发",r); return NULL; } if(wait_ready(s)) return NULL;
    } return l;
}
MXChannel *mx_forward_accept(MXSSH *s,MXForward *l) { return libssh2_channel_forward_accept(l); }
void mx_forward_cancel(MXSSH *s,MXForward *l) { begin(s); while(libssh2_channel_forward_cancel(l)==LIBSSH2_ERROR_EAGAIN) if(wait_ready(s)) break; }
int mx_socket_listen(const char *host,int port,int *bound) {
    struct addrinfo hints={0},*a=NULL; hints.ai_family=AF_UNSPEC; hints.ai_socktype=SOCK_STREAM; hints.ai_flags=AI_PASSIVE;
    char service[8]; snprintf(service,sizeof(service),"%d",port); if(getaddrinfo(host,service,&hints,&a)) return -1;
    int fd=-1;
    for(struct addrinfo *p=a;p;p=p->ai_next) {
        fd=socket(p->ai_family,p->ai_socktype,p->ai_protocol); if(fd<0) continue; nonblock(fd);
        int one=1; setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
        if(bind(fd,p->ai_addr,p->ai_addrlen)==0 && listen(fd,64)==0) break;
        close(fd); fd=-1;
    } freeaddrinfo(a);
    if(fd>=0) { struct sockaddr_storage addr; socklen_t n=sizeof(addr); getsockname(fd,(struct sockaddr*)&addr,&n); *bound=ntohs(addr.ss_family==AF_INET?((struct sockaddr_in*)&addr)->sin_port:((struct sockaddr_in6*)&addr)->sin6_port); }
    return fd;
}
int mx_socket_connect(const char *host,int port) { return connect_socket(host,port,NULL); }
int mx_socket_accept(int fd) { int client=accept(fd,NULL,NULL); if(client>=0) nonblock(client); return client; }
ssize_t mx_socket_read(int fd,void *buffer,size_t count) { ssize_t n=recv(fd,buffer,count,0); return n<0 && (errno==EAGAIN || errno==EWOULDBLOCK)?-2:n; }
ssize_t mx_socket_write(int fd,const void *buffer,size_t count) { ssize_t n=send(fd,buffer,count,0); return n<0 && (errno==EAGAIN || errno==EWOULDBLOCK)?-2:n; }
void mx_socket_close(int fd) { if(fd>=0) { shutdown(fd,SHUT_RDWR); close(fd); } }
void mx_socket_shutdown_write(int fd) { shutdown(fd,SHUT_WR); }
void mx_destroy(MXSSH *s) {
    if(!s) return;
    if(s->fd>=0) { shutdown(s->fd,SHUT_RDWR); close(s->fd); s->fd=-1; }
    if(s->sftp) { libssh2_sftp_shutdown(s->sftp); s->sftp=NULL; }
    if(s->session) libssh2_session_free(s->session);
    free(s);
}
