#ifndef MACXTERM_SSH_BRIDGE_H
#define MACXTERM_SSH_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
typedef struct MXSSH MXSSH;
typedef void MXChannel;
typedef void MXFile;
typedef void MXForward;
typedef struct MXCommand MXCommand;
typedef struct { uint64_t size; uint32_t permissions; uint64_t modified; uint32_t uid; uint32_t gid; } MXAttributes;
MXSSH *mx_create(void);
void mx_cancel(MXSSH *s);
void mx_destroy(MXSSH *s);
const char *mx_error(MXSSH *s);
int mx_connect(MXSSH *s, const char *host, int port);
const void *mx_hostkey(MXSSH *s, size_t *length, int *type);
int mx_auth_password(MXSSH *s, const char *username, const char *password);
int mx_auth_key(MXSSH *s, const char *username, const char *keypath, const char *passphrase);
MXChannel *mx_terminal(MXSSH *s, int cols, int rows);
MXChannel *mx_exec(MXSSH *s, const char *command);
int mx_exit_status(MXChannel *c);
MXCommand *mx_command_create(void);
int mx_command_step(MXSSH *s, MXCommand *command, const char *text);
MXChannel *mx_command_channel(MXCommand *command);
int mx_command_free_step(MXSSH *s, MXCommand *command, int terminate);
void mx_command_abandon(MXCommand *command);
int mx_resize(MXSSH *s, MXChannel *c, int cols, int rows);
ssize_t mx_read(MXSSH *s, MXChannel *c, void *buffer, size_t count);
ssize_t mx_write(MXSSH *s, MXChannel *c, const void *buffer, size_t count);
int mx_eof(MXChannel *c);
int mx_send_eof(MXSSH *s, MXChannel *c);
void mx_channel_free(MXSSH *s, MXChannel *c);
int mx_keepalive(MXSSH *s);
int mx_sftp_start(MXSSH *s);
int mx_stat(MXSSH *s, const char *path, int follow, MXAttributes *attrs);
int mx_realpath(MXSSH *s, const char *path, char *buffer, size_t count);
MXFile *mx_opendir(MXSSH *s, const char *path);
int mx_readdir(MXSSH *s, MXFile *dir, char *buffer, size_t count, MXAttributes *attrs);
MXFile *mx_open_read(MXSSH *s, const char *path);
MXFile *mx_open_write(MXSSH *s, const char *path, unsigned long mode);
ssize_t mx_file_read(MXSSH *s, MXFile *f, void *buffer, size_t count);
ssize_t mx_file_write(MXSSH *s, MXFile *f, const void *buffer, size_t count);
int mx_file_close(MXSSH *s, MXFile *f);
int mx_mkdir(MXSSH *s, const char *path, unsigned long mode);
int mx_remove(MXSSH *s, const char *path);
int mx_rename(MXSSH *s, const char *from, const char *to, int replace);
int mx_chmod(MXSSH *s, const char *path, unsigned long mode);
MXChannel *mx_direct(MXSSH *s, const char *host, int port);
MXForward *mx_forward_listen(MXSSH *s, const char *host, int port, int *bound);
MXChannel *mx_forward_accept(MXSSH *s, MXForward *listener);
void mx_forward_cancel(MXSSH *s, MXForward *listener);
int mx_socket_listen(const char *host, int port, int *bound);
int mx_socket_connect(const char *host, int port);
int mx_socket_accept(int fd);
ssize_t mx_socket_read(int fd, void *buffer, size_t count);
ssize_t mx_socket_write(int fd, const void *buffer, size_t count);
void mx_socket_close(int fd);
void mx_socket_shutdown_write(int fd);
#endif
