#include "RDPBridge.h"
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <freerdp/update.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct { rdpContext base; MXRDP *owner; } MXContext;
typedef struct { int kind; uint32_t code; uint16_t flags, x, y; } MXInput;
#define MX_INPUT_CAPACITY 8192
struct MXRDP {
    freerdp *instance;
    void *user;
    MXRDPStateCallback state;
    MXRDPCertificateCallback certificate;
    atomic_bool stopped;
    pthread_mutex_t mutex;
    MXInput input[MX_INPUT_CAPACITY];
    size_t head, tail;
    uint8_t *frame;
    int width, height, stride;
    size_t frame_size;
    int dirty;
};
static pthread_once_t log_once = PTHREAD_ONCE_INIT;
static void configure_log(void) { WLog_SetLogLevel(WLog_GetRoot(), WLOG_FATAL); }
static MXRDP *owner(rdpContext *context) { return ((MXContext *)context)->owner; }
static BOOL begin_paint(rdpContext *context) {
    context->gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}
static BOOL end_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (gdi->primary->hdc->hwnd->invalid->null) return TRUE;
    MXRDP *s = owner(context);
    /* Bound allocations before trusting server-controlled framebuffer dimensions. */
    if (gdi->width < 1 || gdi->height < 1 || gdi->width > 8192 || gdi->height > 8192 ||
        gdi->stride < gdi->width * 4 || gdi->stride > 8192 * 4) return FALSE;
    size_t size = (size_t)gdi->stride * gdi->height;
    pthread_mutex_lock(&s->mutex);
    if (s->frame_size != size) {
        uint8_t *next = realloc(s->frame, size);
        if (!next) { pthread_mutex_unlock(&s->mutex); return FALSE; }
        s->frame = next;
        s->frame_size = size;
    }
    memcpy(s->frame, gdi->primary_buffer, size);
    s->width = gdi->width; s->height = gdi->height; s->stride = gdi->stride; s->dirty = 1;
    pthread_mutex_unlock(&s->mutex);
    return TRUE;
}
static BOOL desktop_resize(rdpContext *context) {
    UINT32 w = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    UINT32 h = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (w < 1 || h < 1 || w > 8192 || h > 8192) return FALSE;
    return gdi_resize(context->gdi, w, h);
}
static BOOL post_connect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;
    instance->context->update->BeginPaint = begin_paint;
    instance->context->update->EndPaint = end_paint;
    instance->context->update->DesktopResize = desktop_resize;
    return TRUE;
}
static void post_disconnect(freerdp *instance) { gdi_free(instance); }
static DWORD verify_certificate(freerdp *instance, const char *host, UINT16 port,
    const char *common_name, const char *subject, const char *issuer, const char *fingerprint, DWORD flags) {
    MXRDP *s = owner(instance->context);
    if (atomic_load(&s->stopped) || !s->certificate) return 0;
    /* Temporary trust only. No automatic certificate bypass or on-disk trust mutation. */
    return s->certificate(s->user, host, subject, issuer, fingerprint) ? 2 : 0;
}
static DWORD verify_changed_certificate(freerdp *instance, const char *host, UINT16 port,
    const char *common_name, const char *subject, const char *issuer, const char *fingerprint,
    const char *old_subject, const char *old_issuer, const char *old_fingerprint, DWORD flags) {
    return verify_certificate(instance, host, port, common_name, subject, issuer, fingerprint, flags);
}
MXRDP *mxrdp_new(const char *host, int port, const char *username, const char *password,
    const char *domain, int width, int height, int negotiate, void *user,
    MXRDPStateCallback state, MXRDPCertificateCallback certificate) {
    pthread_once(&log_once, configure_log);
    MXRDP *s = calloc(1, sizeof(MXRDP));
    if (!s) return NULL;
    pthread_mutex_init(&s->mutex, NULL);
    atomic_init(&s->stopped, 0);
    s->user = user; s->state = state; s->certificate = certificate;
    s->instance = freerdp_new();
    if (!s->instance) { mxrdp_free(s); return NULL; }
    s->instance->ContextSize = sizeof(MXContext);
    s->instance->PostConnect = post_connect;
    s->instance->PostDisconnect = post_disconnect;
    s->instance->VerifyCertificateEx = verify_certificate;
    s->instance->VerifyChangedCertificateEx = verify_changed_certificate;
    if (!freerdp_context_new(s->instance)) { mxrdp_free(s); return NULL; }
    ((MXContext *)s->instance->context)->owner = s;
    rdpSettings *settings = s->instance->context->settings;
#define SET_STRING(name, value) if (!freerdp_settings_set_string(settings, FreeRDP_##name, value)) goto fail
#define SET_INT(name, value) if (!freerdp_settings_set_uint32(settings, FreeRDP_##name, value)) goto fail
#define SET_BOOL(name, value) if (!freerdp_settings_set_bool(settings, FreeRDP_##name, value)) goto fail
    SET_STRING(ServerHostname, host); SET_INT(ServerPort, port);
    SET_STRING(Username, username); SET_STRING(Password, password); SET_STRING(Domain, domain);
    SET_INT(DesktopWidth, width); SET_INT(DesktopHeight, height); SET_INT(ColorDepth, 32);
    SET_INT(TcpConnectTimeout, 10000);
    SET_BOOL(TlsSecurity, TRUE); SET_BOOL(NlaSecurity, negotiate != 0); SET_BOOL(RdpSecurity, FALSE);
    SET_BOOL(NegotiateSecurityLayer, TRUE); SET_BOOL(IgnoreCertificate, FALSE);
    SET_BOOL(AutoLogonEnabled, password && password[0]); SET_BOOL(SoftwareGdi, TRUE); SET_BOOL(UnicodeInput, TRUE);
    SET_BOOL(SupportGraphicsPipeline, FALSE); SET_BOOL(SupportDynamicChannels, FALSE);
    SET_BOOL(BitmapCachePersistEnabled, FALSE); SET_BOOL(MouseMotion, TRUE);
    SET_INT(GlyphSupportLevel, 0);
    return s;
fail:
    mxrdp_free(s); return NULL;
}
static int enqueue(MXRDP *s, MXInput event) {
    if (!s || atomic_load(&s->stopped)) return 0;
    pthread_mutex_lock(&s->mutex);
    size_t next = (s->tail + 1) % MX_INPUT_CAPACITY;
    if (next == s->head) { pthread_mutex_unlock(&s->mutex); return 0; }
    s->input[s->tail] = event; s->tail = next;
    pthread_mutex_unlock(&s->mutex); return 1;
}
int mxrdp_mouse(MXRDP *s, uint16_t flags, uint16_t x, uint16_t y) {
    return enqueue(s, (MXInput){ .kind = 0, .flags = flags, .x = x, .y = y });
}
int mxrdp_key(MXRDP *s, uint32_t code, int down) {
    return enqueue(s, (MXInput){ .kind = 1, .code = code, .flags = down != 0 });
}
int mxrdp_unicode(MXRDP *s, uint16_t character) {
    return enqueue(s, (MXInput){ .kind = 2, .code = character });
}
static BOOL send_input(MXRDP *s) {
    for (int i = 0; i < 512; i++) {
        pthread_mutex_lock(&s->mutex);
        if (s->head == s->tail) { pthread_mutex_unlock(&s->mutex); break; }
        MXInput e = s->input[s->head]; s->head = (s->head + 1) % MX_INPUT_CAPACITY;
        pthread_mutex_unlock(&s->mutex);
        rdpInput *input = s->instance->context->input;
        BOOL ok = TRUE;
        if (e.kind == 0) ok = freerdp_input_send_mouse_event(input, e.flags, e.x, e.y);
        if (e.kind == 1) ok = freerdp_input_send_keyboard_event_ex(input, e.flags, FALSE, e.code);
        if (e.kind == 2) {
            ok = freerdp_input_send_unicode_keyboard_event(input, KBD_FLAGS_DOWN, (UINT16)e.code);
            if (ok) ok = freerdp_input_send_unicode_keyboard_event(input, KBD_FLAGS_RELEASE, (UINT16)e.code);
        }
        if (!ok) return FALSE;
    }
    return TRUE;
}
void mxrdp_run(MXRDP *s) {
    if (!s || atomic_load(&s->stopped)) return;
    BOOL connected = freerdp_connect(s->instance);
    if (connected && !atomic_load(&s->stopped)) {
        if (s->state) s->state(s->user, 1, "RDP 桌面已连接");
        while (!atomic_load(&s->stopped) && !freerdp_shall_disconnect_context(s->instance->context)) {
            HANDLE handles[64];
            DWORD count = freerdp_get_event_handles(s->instance->context, handles, 64);
            if (!count || count > 64) break;
            DWORD result = WaitForMultipleObjects(count, handles, FALSE, 10);
            if (result == WAIT_FAILED || !send_input(s) || !freerdp_check_event_handles(s->instance->context)) break;
        }
    }
    UINT32 code = freerdp_get_last_error(s->instance->context);
    if (!atomic_load(&s->stopped) && s->state) {
        if (!connected || code) {
            char message[512];
            snprintf(message, sizeof(message), "RDP 连接结束：%s (0x%08X)",
                     freerdp_get_last_error_string(code), code);
            s->state(s->user, 2, message);
        } else s->state(s->user, 0, "远端桌面会话已结束");
    }
    BOOL disconnected = freerdp_disconnect(s->instance);
    (void)disconnected;
}
void mxrdp_stop(MXRDP *s) {
    if (!s) return;
    atomic_store(&s->stopped, 1);
    if (s->instance && s->instance->context) {
        BOOL aborted = freerdp_abort_connect_context(s->instance->context);
        (void)aborted;
    }
}
uint8_t *mxrdp_copy_frame(MXRDP *s, int *w, int *h, int *stride, size_t *size) {
    if (!s) return NULL;
    pthread_mutex_lock(&s->mutex);
    uint8_t *copy = NULL;
    if (s->dirty && s->frame_size && (copy = malloc(s->frame_size))) {
        memcpy(copy, s->frame, s->frame_size);
        *w = s->width; *h = s->height; *stride = s->stride; *size = s->frame_size;
        s->dirty = 0;
    }
    pthread_mutex_unlock(&s->mutex); return copy;
}
void mxrdp_free(MXRDP *s) {
    if (!s) return;
    if (s->instance) { freerdp_context_free(s->instance); freerdp_free(s->instance); }
    free(s->frame); pthread_mutex_destroy(&s->mutex); free(s);
}
const char *mxrdp_version(void) { return freerdp_get_version_string(); }
