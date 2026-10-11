#ifndef MACXTERM_RDP_BRIDGE_H
#define MACXTERM_RDP_BRIDGE_H
#include <stdint.h>
#include <stddef.h>

typedef struct MXRDP MXRDP;
typedef void (*MXRDPStateCallback)(void *user, int state, const char *message);
typedef int (*MXRDPCertificateCallback)(void *user, const char *host, const char *subject,
                                      const char *issuer, const char *fingerprint);
MXRDP *mxrdp_new(const char *host, int port, const char *username, const char *password,
                const char *domain, int width, int height, int negotiate,
                void *user, MXRDPStateCallback state, MXRDPCertificateCallback certificate);
/* Run exactly once on a dedicated worker. Free only after run has returned. */
void mxrdp_run(MXRDP *session);
/* Thread-safe cancellation, input queue, and latest-frame copy. */
void mxrdp_stop(MXRDP *session);
int mxrdp_mouse(MXRDP *session, uint16_t flags, uint16_t x, uint16_t y);
int mxrdp_key(MXRDP *session, uint32_t scan_code, int down);
int mxrdp_unicode(MXRDP *session, uint16_t character);
uint8_t *mxrdp_copy_frame(MXRDP *session, int *width, int *height, int *stride, size_t *size);
void mxrdp_free(MXRDP *session);
const char *mxrdp_version(void);
#endif
