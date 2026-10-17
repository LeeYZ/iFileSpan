#include "DeviceBridge.h"
#include <stdio.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
static pthread_mutex_t error_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t error_condition = PTHREAD_COND_INITIALIZER;
static int error_waiting;
struct error_probe { int kind; int passed; };
static void *check_thread_error(void *argument) {
    struct error_probe *probe = argument;
    const char *expected;
    if (probe->kind == 0) {
        df_browser_connect(NULL, "", 1); expected = "无效的 App 请求（错误码 -1）";
    } else {
        df_browser_icon(NULL, "", NULL, NULL); expected = "无效的图标请求（错误码 -1）";
    }
    pthread_mutex_lock(&error_mutex);
    error_waiting++;
    pthread_cond_broadcast(&error_condition);
    while (error_waiting < 2) pthread_cond_wait(&error_condition, &error_mutex);
    pthread_mutex_unlock(&error_mutex);
    probe->passed = !strcmp(df_error(), expected) && df_error_code() == -1;
    return NULL;
}
int main(int argc, char **argv) {
    if (argc != 2 && argc != 3) { fprintf(stderr, "Usage: library-check APP/Contents/Frameworks [--devices]\n"); return 2; }
    char path[4096];
    snprintf(path, sizeof(path), "%s/libimobiledevice-1.0.dylib", argv[1]);
    void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "Bundled library failed: %s\n", dlerror()); return 1; }
    if (df_load(argv[1]) != 0) { fprintf(stderr, "%s\n", df_error()); return 1; }
    puts("Bundled libraries and all required symbols loaded successfully.");
    void *(*new_dict)(void) = dlsym(library, "plist_new_dict");
    void *(*new_string)(const char *) = dlsym(library, "plist_new_string");
    void (*set_item)(void *, const char *, void *) = dlsym(library, "plist_dict_set_item");
    int (*to_xml)(void *, char **, uint32_t *) = dlsym(library, "plist_to_xml");
    void (*free_node)(void *) = dlsym(library, "plist_free");
    void (*free_memory)(void *) = dlsym(library, "plist_mem_free");
    void *dict = new_dict();
    set_item(dict, "probe", new_string("iFileSpan"));
    char *xml = NULL; uint32_t length = 0;
    int result = to_xml(dict, &xml, &length);
    if (result || !xml || !strstr(xml, "iFileSpan")) { fprintf(stderr, "libplist roundtrip failed\n"); return 1; }
    free_memory(xml); free_node(dict);
    int (*random_bytes)(unsigned char *, int) = dlsym(library, "RAND_bytes");
    unsigned char random[16];
    if (!random_bytes || random_bytes(random, sizeof(random)) != 1) { fprintf(stderr, "OpenSSL runtime failed\n"); return 1; }
    puts("libplist serialization and OpenSSL runtime checks passed.");
    pthread_t threads[2]; struct error_probe probes[2] = {{0, 0}, {1, 0}};
    if (pthread_create(&threads[0], NULL, check_thread_error, &probes[0]) ||
        pthread_create(&threads[1], NULL, check_thread_error, &probes[1])) return 1;
    pthread_join(threads[0], NULL); pthread_join(threads[1], NULL);
    if (!probes[0].passed || !probes[1].passed) { fputs("Thread-local error check failed\n", stderr); return 1; }
    puts("Concurrent bridge error isolation passed.");
    if (argc == 3) {
        char **devices = NULL; int count = 0;
        int result = df_devices(&devices, &count);
        df_devices_free(devices);
        if (result) { fprintf(stderr, "%s\n", df_error()); return 1; }
        printf("USB discovery succeeded. Connected devices: %d\n", count);
    }
    return 0;
}
