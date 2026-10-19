#include "DeviceBridge.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

// Stable public C ABI; the upstream library remains an external dependency.
static void *library;
static _Thread_local char last_error[2048];
static _Thread_local int last_error_code;
#define FN(ret, name, args) static ret (*p_##name) args
FN(int, idevice_get_device_list, (char ***, int *));
FN(int, idevice_device_list_free, (char **));
FN(int, idevice_new, (void **, const char *));
FN(int, idevice_free, (void *));
FN(int, lockdownd_client_new_with_handshake, (void *, void **, const char *));
FN(int, lockdownd_client_free, (void *));
FN(int, lockdownd_start_service, (void *, const char *, void **));
FN(int, lockdownd_service_descriptor_free, (void *));
FN(int, house_arrest_client_new, (void *, void *, void **));
FN(int, lockdownd_get_value, (void *, const char *, const char *, void **));
FN(int, instproxy_client_start_service, (void *, void **, const char *));
FN(int, instproxy_client_free, (void *));
FN(int, instproxy_browse, (void *, void *, void **));
FN(int, property_list_service_client_new, (void *, void *, void **));
FN(int, property_list_service_client_free, (void *));
FN(int, property_list_service_send_xml_plist, (void *, void *));
FN(int, property_list_service_receive_plist_with_timeout, (void *, void **, unsigned int));
FN(int, sbservices_client_start_service, (void *, void **, const char *));
FN(int, sbservices_client_free, (void *));
FN(int, sbservices_get_icon_pngdata, (void *, const char *, char **, uint64_t *));
FN(int, house_arrest_client_start_service, (void *, void **, const char *));
FN(int, house_arrest_client_free, (void *));
FN(int, house_arrest_send_command, (void *, const char *, const char *));
FN(int, house_arrest_get_result, (void *, void **));
FN(int, afc_client_new_from_house_arrest_client, (void *, void **));
FN(int, afc_client_start_service, (void *, void **, const char *));
FN(int, afc_client_free, (void *));
FN(int, afc_read_directory, (void *, const char *, char ***));
FN(int, afc_get_file_info, (void *, const char *, char ***));
FN(int, afc_dictionary_free, (char **));
FN(int, afc_file_open, (void *, const char *, int, uint64_t *));
FN(int, afc_file_close, (void *, uint64_t));
FN(int, afc_file_read, (void *, uint64_t, char *, uint32_t, uint32_t *));
FN(int, afc_file_write, (void *, uint64_t, const char *, uint32_t, uint32_t *));
FN(int, afc_rename_path, (void *, const char *, const char *));
FN(int, afc_remove_path, (void *, const char *));
FN(int, afc_make_directory, (void *, const char *));
FN(void *, plist_new_dict, (void));
FN(void *, plist_new_array, (void));
FN(void *, plist_new_string, (const char *));
FN(void, plist_dict_set_item, (void *, const char *, void *));
FN(void *, plist_dict_get_item, (void *, const char *));
FN(const char *, plist_get_string_ptr, (void *, uint64_t *));
FN(void, plist_array_append_item, (void *, void *));
FN(int, plist_to_xml, (void *, char **, uint32_t *));
FN(void, plist_mem_free, (void *));
FN(void, plist_free, (void *));

static int fail(const char *operation, int code) {
    last_error_code = code ? code : -999;
    snprintf(last_error, sizeof(last_error), "%s（错误码 %d）", operation, code);
    return code ? code : -999;
}
const char *df_error(void) { return last_error; }
int df_error_code(void) { return last_error_code; }
void df_free(void *memory) { free(memory); }

int df_load(const char *framework_directory) {
    if (library) return 0;
    const char *paths[] = {"/opt/homebrew/lib/libimobiledevice-1.0.dylib",
        "/usr/local/lib/libimobiledevice-1.0.dylib",
        "/opt/homebrew/opt/libimobiledevice/lib/libimobiledevice-1.0.dylib", NULL};
    char bundled[4096];
    char bundled_error[1024] = "";
    if (framework_directory && *framework_directory) {
        snprintf(bundled, sizeof(bundled), "%s/libimobiledevice-1.0.dylib", framework_directory);
        library = dlopen(bundled, RTLD_NOW | RTLD_LOCAL);
        if (!library) { const char *error = dlerror(); snprintf(bundled_error, sizeof(bundled_error), "%s", error ? error : "未知原因"); }
    }
    for (int i = 0; !library && paths[i]; i++) library = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        snprintf(last_error, sizeof(last_error), "设备连接组件加载失败。请重新解压完整的 iFileSpan.app，确认 Contents/Frameworks 目录完整。详细信息：%s", bundled_error[0] ? bundled_error : "未找到 libimobiledevice");
        return -1;
    }
#define LOAD(name) do { *(void **)(&p_##name) = dlsym(library, #name); if (!p_##name) { snprintf(last_error, sizeof(last_error), "连接组件缺少接口 %s，请更新 libimobiledevice / libplist。", #name); goto invalid; } } while(0)
    LOAD(idevice_get_device_list); LOAD(idevice_device_list_free); LOAD(idevice_new); LOAD(idevice_free);
    LOAD(lockdownd_client_new_with_handshake); LOAD(lockdownd_client_free); LOAD(lockdownd_get_value);
    LOAD(lockdownd_start_service); LOAD(lockdownd_service_descriptor_free); LOAD(house_arrest_client_new);
    LOAD(instproxy_client_start_service); LOAD(instproxy_client_free); LOAD(instproxy_browse);
    LOAD(property_list_service_client_new); LOAD(property_list_service_client_free);
    LOAD(property_list_service_send_xml_plist); LOAD(property_list_service_receive_plist_with_timeout);
    LOAD(sbservices_client_start_service); LOAD(sbservices_client_free); LOAD(sbservices_get_icon_pngdata);
    LOAD(house_arrest_client_start_service); LOAD(house_arrest_client_free);
    LOAD(house_arrest_send_command); LOAD(house_arrest_get_result);
    LOAD(afc_client_new_from_house_arrest_client); LOAD(afc_client_start_service); LOAD(afc_client_free);
    LOAD(afc_read_directory); LOAD(afc_get_file_info); LOAD(afc_dictionary_free);
    LOAD(afc_file_open); LOAD(afc_file_close); LOAD(afc_file_read); LOAD(afc_file_write);
    LOAD(afc_rename_path); LOAD(afc_remove_path); LOAD(afc_make_directory);
    LOAD(plist_new_dict); LOAD(plist_new_array); LOAD(plist_new_string);
    LOAD(plist_dict_set_item); LOAD(plist_dict_get_item); LOAD(plist_get_string_ptr);
    LOAD(plist_array_append_item); LOAD(plist_to_xml); LOAD(plist_mem_free); LOAD(plist_free);
    return 0;
invalid:
    dlclose(library); library = NULL; return -1;
}
int df_devices(char ***devices, int *count) {
    int r = p_idevice_get_device_list(devices, count);
    return r ? fail("无法检测 USB 设备，请检查连接", r) : 0;
}
void df_devices_free(char **devices) { if (devices) p_idevice_device_list_free(devices); }

static char *xml_copy(void *plist) {
    if (!plist) { fail("设备没有返回数据", -1); return NULL; }
    char *xml = NULL; uint32_t length = 0;
    p_plist_to_xml(plist, &xml, &length);
    char *copy = xml ? strndup(xml, length) : NULL;
    if (xml) p_plist_mem_free(xml);
    if (!copy) fail("无法解析设备数据", -1);
    return copy;
}
static void *new_device(const char *udid) {
    void *device = NULL;
    int r = p_idevice_new(&device, udid);
    if (r) { fail("设备已断开，请重新连接", r); return NULL; }
    return device;
}
static int handshake(void *device, void **lockdown) {
    int r = p_lockdownd_client_new_with_handshake(device, lockdown, "iFileSpan");
    return r ? fail("连接失败，请解锁设备并选择“信任此电脑”", r) : 0;
}
char *df_device_info(const char *udid) {
    void *d = new_device(udid), *l = NULL, *value = NULL; char *xml = NULL;
    if (!d) return NULL;
    if (handshake(d, &l)) goto done;
    int r = p_lockdownd_get_value(l, NULL, NULL, &value);
    if (r) fail("读取设备信息失败", r); else xml = xml_copy(value);
done:
    if (value) p_plist_free(value);
    if (l) p_lockdownd_client_free(l);
    p_idevice_free(d); return xml;
}
char *df_apps(const char *udid) {
    void *d = new_device(udid), *l = NULL, *client = NULL, *result = NULL;
    void *options = NULL; char *xml = NULL;
    if (!d) return NULL;
    if (handshake(d, &l)) goto done;
    int r = p_instproxy_client_start_service(d, &client, "iFileSpan");
    if (r) { fail("无法读取 App 列表", r); goto done; }
    options = p_plist_new_dict();
    p_plist_dict_set_item(options, "ApplicationType", p_plist_new_string("Any"));
    void *attributes = p_plist_new_array();
    const char *keys[] = {"CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "UIFileSharingEnabled", "CFBundleShortVersionString", "ApplicationType", NULL};
    for (int i = 0; keys[i]; i++) p_plist_array_append_item(attributes, p_plist_new_string(keys[i]));
    p_plist_dict_set_item(options, "ReturnAttributes", attributes);
    r = p_instproxy_browse(client, options, &result);
    if (r) fail("读取 App 列表失败", r); else xml = xml_copy(result);
done:
    if (options) p_plist_free(options);
    if (result) p_plist_free(result);
    if (client) p_instproxy_client_free(client);
    if (l) p_lockdownd_client_free(l);
    p_idevice_free(d); return xml;
}
int df_app_icon(const char *udid, const char *bundle_id, char **png, uint64_t *size) {
    if (!png || !size) return fail("无效的图标请求", -1);
    *png = NULL; *size = 0;
    void *d = new_device(udid), *client = NULL;
    if (!d) return -1;
    int r = p_sbservices_client_start_service(d, &client, "iFileSpan");
    if (!r) r = p_sbservices_get_icon_pngdata(client, bundle_id, png, size);
    if (client) p_sbservices_client_free(client);
    p_idevice_free(d);
    if (r || !*png || !*size || *size > 8 * 1024 * 1024) {
        free(*png); *png = NULL; *size = 0;
        return fail("无法读取 App 图标", r ? r : -1);
    }
    return 0;
}
struct DFSession { void *device; void *house; void *afc; };
void df_disconnect(DFSession *s) {
    if (!s) return;
    if (s->afc) p_afc_client_free(s->afc);
    if (s->house) p_house_arrest_client_free(s->house);
    if (s->device) p_idevice_free(s->device);
    free(s);
}
static int house_result_denied(void *result, int container) {
    void *error = p_plist_dict_get_item(result, "Error");
    if (error) {
        const char *message = p_plist_get_string_ptr(error, NULL);
        // Only explicit app-access errors count as restricted. Transport/lock errors stay unknown.
        last_error_code = message && (!strcmp(message, "InstallationLookupFailed") ||
            !strcmp(message, "ApplicationLookupFailed") || !strcmp(message, "PermissionDenied") ||
            !strcmp(message, "AccessDenied") || !strcmp(message, "NotAllowed")) ? -10001 : -999;
        snprintf(last_error, sizeof(last_error), "设备拒绝 %s：%s。%s", container ? "容器根目录访问" : "Documents 访问", message ? message : "未知原因", container ? "设备未授权读取此 App 的容器；显示 App 不代表能读取其私有目录。" : "请确认 App 已安装且开启文件共享。");
        return 1;
    }
    return 0;
}
DFSession *df_connect(const char *udid, const char *bundle_id, int container) {
    last_error_code = 0;
    DFSession *s = calloc(1, sizeof(*s));
    if (!s) { fail("内存不足", -1); return NULL; }
    void *l = NULL, *result = NULL;
    s->device = new_device(udid); if (!s->device) goto bad;
    int r;
    if (!bundle_id || !*bundle_id) {
        r = p_afc_client_start_service(s->device, &s->afc, "iFileSpan");
        if (r) { fail("共享媒体目录连接失败", r); goto bad; }
        return s;
    }
    r = p_house_arrest_client_start_service(s->device, &s->house, "iFileSpan");
    if (r) { fail("App 文件服务连接失败", r); goto bad; }
    r = p_house_arrest_send_command(s->house, container ? "VendContainer" : "VendDocuments", bundle_id);
    if (r) { fail("无法请求 App 目录", r); goto bad; }
    r = p_house_arrest_get_result(s->house, &result);
    if (r) { fail("设备未返回目录访问结果", r); goto bad; }
    if (!result) { fail("设备返回了空的访问结果", -1); goto bad; }
    if (house_result_denied(result, container)) goto bad;
    p_plist_free(result); result = NULL;
    r = p_afc_client_new_from_house_arrest_client(s->house, &s->afc);
    if (r) { fail("无法打开 App 文件连接", r); goto bad; }
    return s;
bad:
    if (result) p_plist_free(result);
    if (l) p_lockdownd_client_free(l);
    df_disconnect(s); return NULL;
}
#define AFC_RESULT(op, description) do { int r = (op); return r ? fail(description, r) : 0; } while(0)
int df_list(DFSession *s, const char *p, char ***v) { AFC_RESULT(p_afc_read_directory(s->afc,p,v), "读取目录失败"); }
int df_stat(DFSession *s, const char *p, char ***v) { AFC_RESULT(p_afc_get_file_info(s->afc,p,v), "读取文件信息失败"); }
void df_dictionary_free(char **v) { if (v) p_afc_dictionary_free(v); }
int df_open(DFSession *s,const char *p,int w,uint64_t *h) { AFC_RESULT(p_afc_file_open(s->afc,p,w ? 3 : 1,h), "打开文件失败"); }
int df_close(DFSession *s,uint64_t h) { AFC_RESULT(p_afc_file_close(s->afc,h), "关闭文件失败"); }
int df_read(DFSession *s,uint64_t h,char *b,uint32_t l,uint32_t *n) {
    int r = p_afc_file_read(s->afc,h,b,l,n);
    if (r == 14 && *n == 0) return 0;
    return r ? fail("读取文件失败",r) : 0;
}
int df_write(DFSession *s,uint64_t h,const char *b,uint32_t l,uint32_t *n) { AFC_RESULT(p_afc_file_write(s->afc,h,b,l,n), "写入文件失败"); }
int df_move(DFSession *s,const char *f,const char *t) { AFC_RESULT(p_afc_rename_path(s->afc,f,t), "提交文件失败"); }
int df_remove(DFSession *s,const char *p) { AFC_RESULT(p_afc_remove_path(s->afc,p), "移除设备文件失败"); }
int df_mkdir(DFSession *s,const char *p) { AFC_RESULT(p_afc_make_directory(s->afc,p), "新建文件夹失败"); }

struct DFInstaller { void *device; void *service; };
void df_installer_free(DFInstaller *i) {
    if (!i) return;
    if (i->service) p_property_list_service_client_free(i->service);
    if (i->device) p_idevice_free(i->device);
    free(i);
}
DFInstaller *df_installer_new(const char *udid) {
    if (!library || !udid || !*udid) { fail("请先连接设备", -1); return NULL; }
    DFInstaller *i = calloc(1, sizeof(*i));
    if (!i) { fail("内存不足", -1); return NULL; }
    void *lockdown = NULL, *descriptor = NULL;
    i->device = new_device(udid);
    if (!i->device || handshake(i->device, &lockdown)) goto bad;
    int r = p_lockdownd_start_service(lockdown, "com.apple.mobile.installation_proxy", &descriptor);
    if (!r) r = p_property_list_service_client_new(i->device, descriptor, &i->service);
    if (descriptor) p_lockdownd_service_descriptor_free(descriptor);
    p_lockdownd_client_free(lockdown);
    if (r) { fail("无法连接设备的 App 安装服务，请解锁设备并确认信任", r); df_installer_free(i); return NULL; }
    return i;
bad:
    if (lockdown) p_lockdownd_client_free(lockdown);
    df_installer_free(i); return NULL;
}
int df_installer_start(DFInstaller *i, const char *path, const char *bundle_id) {
    // Keep commands inside our own staging area, never install a user-selected device path.
    if (!i || !path || !bundle_id || !*bundle_id || strncmp(path, "PublicStaging/iFileSpan-", 24) || strstr(path, ".."))
        return fail("无效的安装请求", -1);
    void *command = p_plist_new_dict();
    p_plist_dict_set_item(command, "Command", p_plist_new_string("Install"));
    p_plist_dict_set_item(command, "PackagePath", p_plist_new_string(path));
    void *options = p_plist_new_dict();
    p_plist_dict_set_item(options, "CFBundleIdentifier", p_plist_new_string(bundle_id));
    p_plist_dict_set_item(command, "ClientOptions", options);
    int r = p_property_list_service_send_xml_plist(i->service, command);
    p_plist_free(command);
    return r ? fail("安装请求发送失败，结果尚未确认，请在设备上检查后重试", r) : 0;
}
int df_installer_receive(DFInstaller *i, char **status) {
    if (!i || !status) return fail("无效的安装状态请求", -1);
    *status = NULL;
    void *node = NULL;
    int r = p_property_list_service_receive_plist_with_timeout(i->service, &node, 1000);
    if (r) {
        if (node) p_plist_free(node);
        if (r == -5) return 1; // PROPERTY_LIST_SERVICE_E_RECEIVE_TIMEOUT
        return fail("与设备安装服务的连接中断，安装结果尚未确认，请在设备上检查", r);
    }
    *status = xml_copy(node);
    if (node) p_plist_free(node);
    return *status ? 0 : -1;
}

// Use macOS's system libarchive through its stable public C ABI. Nothing is extracted.
int df_ipa_info(const char *path, char **info, uint64_t *size) {
    if (!path || !info || !size) return fail("无效的 IPA 请求", -1);
    *info = NULL; *size = 0;
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    struct stat attributes;
    if (fd < 0) return fail("无法读取 IPA 文件", -1);
    if (fstat(fd, &attributes) || !S_ISREG(attributes.st_mode)) {
        close(fd); return fail("IPA 必须是普通文件", -1);
    }
    void *lib = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!lib) { close(fd); return fail("系统压缩包读取组件不可用", -1); }
    void *(*read_new)(void) = dlsym(lib, "archive_read_new");
    int (*support_zip)(void *) = dlsym(lib, "archive_read_support_format_zip");
    int (*open_fd)(void *, int, size_t) = dlsym(lib, "archive_read_open_fd");
    int (*next)(void *, void **) = dlsym(lib, "archive_read_next_header");
    const char *(*pathname)(void *) = dlsym(lib, "archive_entry_pathname");
    unsigned int (*filetype)(void *) = dlsym(lib, "archive_entry_filetype");
    int64_t (*entry_size)(void *) = dlsym(lib, "archive_entry_size");
    ssize_t (*read_data)(void *, void *, size_t) = dlsym(lib, "archive_read_data");
    int (*read_free)(void *) = dlsym(lib, "archive_read_free");
    int result = -1, matches = 0, entries = 0;
    void *archive = NULL, *entry = NULL;
    const char *message = "IPA 损坏或不是有效的 ZIP 安装包";
    if (!read_new || !support_zip || !open_fd || !next || !pathname || !filetype || !entry_size || !read_data || !read_free) {
        message = "系统压缩包读取组件缺少接口"; goto done;
    }
    archive = read_new();
    if (!archive || support_zip(archive) || open_fd(archive, fd, 65536)) goto done;
    int r;
    while ((r = next(archive, &entry)) == 0) {
        if (++entries > 250000) { message = "IPA 包含过多项目"; goto done; }
        const char *name = pathname(entry);
        if (!name || !*name || *name == '/' || strchr(name, '\\')) { message = "IPA 包含无效路径"; goto done; }
        for (const char *segment = name; *segment;) {
            const char *end = strchr(segment, '/');
            size_t length = end ? (size_t)(end - segment) : strlen(segment);
            if (!length || (length == 1 && segment[0] == '.') || (length == 2 && !memcmp(segment, "..", 2))) {
                message = "IPA 包含无效路径"; goto done;
            }
            if (!end) break;
            segment = end + 1;
        }
        if (strncmp(name, "Payload/", 8)) continue;
        const char *slash = strchr(name + 8, '/');
        if (!slash || slash - (name + 8) <= 4 || memcmp(slash - 4, ".app", 4) || strcmp(slash + 1, "Info.plist")) continue;
        if (++matches != 1) { message = "IPA 中有多个主应用，无法确定安装目标"; goto done; }
        int64_t length = entry_size(entry);
        if (filetype(entry) != S_IFREG || length <= 0 || length > 4 * 1024 * 1024) {
            message = "IPA 的主应用 Info.plist 无效或过大"; goto done;
        }
        *info = malloc((size_t)length);
        if (!*info) { message = "内存不足"; goto done; }
        size_t offset = 0;
        while (offset < (size_t)length) {
            ssize_t count = read_data(archive, *info + offset, (size_t)length - offset);
            if (count <= 0) goto done;
            offset += (size_t)count;
        }
        char extra;
        if (read_data(archive, &extra, 1) != 0) goto done;
        *size = (uint64_t)length;
    }
    if (r != 1) goto done; // ARCHIVE_EOF
    if (matches != 1) { message = "IPA 缺少 Payload/*.app/Info.plist"; goto done; }
    result = 0;
done:
    if (archive) read_free(archive);
    dlclose(lib); close(fd);
    if (result) { free(*info); *info = NULL; *size = 0; return fail(message, -1); }
    return 0;
}

// Reuse only the lockdown trust session. Devices may close House Arrest after ANY command.
// A successful command switches to AFC; transfer that client to an independently owned session.
struct DFBrowser { void *device; void *lockdown; void *house; void *icons; };
DFBrowser *df_browser_new(const char *udid) {
    DFBrowser *b = calloc(1, sizeof(*b));
    if (!b) { fail("内存不足", -1); return NULL; }
    b->device = new_device(udid);
    if (!b->device) { free(b); return NULL; }
    return b;
}
void df_browser_free(DFBrowser *b) {
    if (!b) return;
    if (b->icons) p_sbservices_client_free(b->icons);
    if (b->house) p_house_arrest_client_free(b->house);
    if (b->lockdown) p_lockdownd_client_free(b->lockdown);
    if (b->device) p_idevice_free(b->device);
    free(b);
}
DFSession *df_browser_connect(DFBrowser *b, const char *bundle_id, int container) {
    last_error_code = 0;
    if (!b || !bundle_id || !*bundle_id) { fail("无效的 App 请求", -1); return NULL; }
    void *result = NULL;
    int r;
    void *descriptor = NULL;
    // An idle trust session can expire; reconnect it once before reporting a service failure.
    if (!b->lockdown && handshake(b->device, &b->lockdown)) goto failed;
    r = p_lockdownd_start_service(b->lockdown, "com.apple.mobile.house_arrest", &descriptor);
    if (r) {
        if (descriptor) p_lockdownd_service_descriptor_free(descriptor);
        descriptor = NULL;
        p_lockdownd_client_free(b->lockdown); b->lockdown = NULL;
        if (handshake(b->device, &b->lockdown)) goto failed;
        r = p_lockdownd_start_service(b->lockdown, "com.apple.mobile.house_arrest", &descriptor);
    }
    if (r || !descriptor) {
        if (descriptor) p_lockdownd_service_descriptor_free(descriptor);
        fail("App 文件服务连接失败", r); goto failed;
    }
    r = p_house_arrest_client_new(b->device, descriptor, &b->house);
    p_lockdownd_service_descriptor_free(descriptor);
    if (r) { fail("App 文件服务连接失败", r); goto failed; }
    r = p_house_arrest_send_command(b->house, container ? "VendContainer" : "VendDocuments", bundle_id);
    if (r) { fail("无法请求 App 目录", r); goto failed; }
    r = p_house_arrest_get_result(b->house, &result);
    if (r || !result) { fail("设备未返回目录访问结果", r); goto failed; }
    if (house_result_denied(result, container)) {
        p_plist_free(result);
        result = NULL; goto failed;
    }
    p_plist_free(result); result = NULL;
    DFSession *s = calloc(1, sizeof(*s));
    if (!s) { fail("内存不足", -1); goto failed; }
    s->house = b->house; b->house = NULL;
    r = p_afc_client_new_from_house_arrest_client(s->house, &s->afc);
    if (r) { fail("无法打开 App 文件连接", r); df_disconnect(s); return NULL; }
    return s;
failed:
    if (result) p_plist_free(result);
    if (b->house) p_house_arrest_client_free(b->house);
    b->house = NULL;
    return NULL;
}
int df_browser_icon(DFBrowser *b, const char *bundle_id, char **png, uint64_t *size) {
    if (!b || !png || !size) return fail("无效的图标请求", -1);
    *png = NULL; *size = 0;
    int r = 0;
    if (!b->icons) r = p_sbservices_client_start_service(b->device, &b->icons, "iFileSpan");
    if (!r) r = p_sbservices_get_icon_pngdata(b->icons, bundle_id, png, size);
    if (r || !*png || !*size || *size > 8 * 1024 * 1024) {
        free(*png); *png = NULL; *size = 0;
        if (b->icons) p_sbservices_client_free(b->icons);
        b->icons = NULL;
        return fail("无法读取 App 图标", r ? r : -1);
    }
    return 0;
}
