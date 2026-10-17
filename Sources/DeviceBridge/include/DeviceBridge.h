#ifndef DEVICE_BRIDGE_H
#define DEVICE_BRIDGE_H
#include <stdint.h>
typedef struct DFSession DFSession;
typedef struct DFBrowser DFBrowser;
// Calls on each session/browser must be serialized. Call df_load before starting workers.
// Errors are thread-local; read immediately on the calling thread. Buffers use df_free.
int df_load(const char *framework_directory);
const char *df_error(void);
int df_error_code(void);
void df_free(void *memory);
int df_devices(char ***devices, int *count);
void df_devices_free(char **devices);
char *df_device_info(const char *udid);
char *df_apps(const char *udid);
// PNG buffer uses df_free. Does not change the active AFC session.
int df_app_icon(const char *udid, const char *bundle_id, char **png, uint64_t *size);
// Reuses trust/icon connections for read-only sidebar requests. Browser must outlive returned sessions.
DFBrowser *df_browser_new(const char *udid);
void df_browser_free(DFBrowser *browser);
DFSession *df_browser_connect(DFBrowser *browser, const char *bundle_id, int container);
int df_browser_icon(DFBrowser *browser, const char *bundle_id, char **png, uint64_t *size);
DFSession *df_connect(const char *udid, const char *bundle_id, int container);
void df_disconnect(DFSession *session);
int df_list(DFSession *session, const char *path, char ***items);
int df_stat(DFSession *session, const char *path, char ***attributes);
void df_dictionary_free(char **values);
int df_open(DFSession *session, const char *path, int writing, uint64_t *handle);
int df_read(DFSession *session, uint64_t handle, char *buffer, uint32_t length, uint32_t *count);
int df_write(DFSession *session, uint64_t handle, const char *buffer, uint32_t length, uint32_t *count);
int df_close(DFSession *session, uint64_t handle);
int df_move(DFSession *session, const char *from, const char *to);
int df_remove(DFSession *session, const char *path);
int df_mkdir(DFSession *session, const char *path);
#endif
