// Exercise the real bridge protocol with in-process service stubs. No device is contacted.
#include "../Sources/DeviceBridge/DeviceBridge.c"
#include <assert.h>

static int fake_device, fake_lockdown, fake_descriptor, fake_service;
static int sent, receive_mode, freed_device, freed_lockdown, freed_descriptor, freed_service, reject_service;
static int mock_device_new(void **device, const char *udid) {
    assert(!strcmp(udid, "test-device")); *device = &fake_device; return 0;
}
static int mock_device_free(void *device) { assert(device == &fake_device); freed_device++; return 0; }
static int mock_handshake(void *device, void **client, const char *label) {
    assert(device == &fake_device && !strcmp(label, "iFileSpan")); *client = &fake_lockdown; return 0;
}
static int mock_lockdown_free(void *client) { assert(client == &fake_lockdown); freed_lockdown++; return 0; }
static int mock_start(void *client, const char *name, void **descriptor) {
    assert(client == &fake_lockdown && !strcmp(name, "com.apple.mobile.installation_proxy"));
    if (reject_service) return -17;
    *descriptor = &fake_descriptor; return 0;
}
static int mock_descriptor_free(void *descriptor) { assert(descriptor == &fake_descriptor); freed_descriptor++; return 0; }
static int mock_service_new(void *device, void *descriptor, void **service) {
    assert(device == &fake_device && descriptor == &fake_descriptor); *service = &fake_service; return 0;
}
static int mock_service_free(void *service) { assert(service == &fake_service); freed_service++; return 0; }
static int mock_send(void *service, void *command) {
    assert(service == &fake_service);
    const char *name = p_plist_get_string_ptr(p_plist_dict_get_item(command, "Command"), NULL);
    const char *path = p_plist_get_string_ptr(p_plist_dict_get_item(command, "PackagePath"), NULL);
    assert(name && !strcmp(name, "Install"));
    assert(path && !strcmp(path, "PublicStaging/iFileSpan-test/Package.ipa"));
    void *options = p_plist_dict_get_item(command, "ClientOptions");
    assert(options);
    const char *bundle = p_plist_get_string_ptr(p_plist_dict_get_item(options, "CFBundleIdentifier"), NULL);
    assert(bundle && !strcmp(bundle, "local.test.example"));
    sent++; return 0;
}
static int mock_receive(void *service, void **status, unsigned int timeout) {
    assert(service == &fake_service && timeout == 1000);
    *status = NULL;
    if (receive_mode == 0) return -5;
    if (receive_mode == 3) return -3;
    if (receive_mode == 4) return 0;
    *status = p_plist_new_dict();
    p_plist_dict_set_item(*status, "Status", p_plist_new_string("Complete"));
    if (receive_mode == 2) {
        p_plist_dict_set_item(*status, "Error", p_plist_new_string("ApplicationVerificationFailed"));
        p_plist_dict_set_item(*status, "ErrorDescription", p_plist_new_string("Invalid signature"));
    }
    return 0;
}
int main(int argc, char **argv) {
    if (argc != 2 || df_load(argv[1])) { fprintf(stderr, "%s\n", df_error()); return 1; }
    p_idevice_new = mock_device_new; p_idevice_free = mock_device_free;
    p_lockdownd_client_new_with_handshake = mock_handshake; p_lockdownd_client_free = mock_lockdown_free;
    p_lockdownd_start_service = mock_start; p_lockdownd_service_descriptor_free = mock_descriptor_free;
    p_property_list_service_client_new = mock_service_new; p_property_list_service_client_free = mock_service_free;
    p_property_list_service_send_xml_plist = mock_send;
    p_property_list_service_receive_plist_with_timeout = mock_receive;
    DFInstaller *installer = df_installer_new("test-device");
    assert(installer && freed_lockdown == 1 && freed_descriptor == 1);
    assert(df_installer_start(installer, "PublicStaging/not-ours/Package.ipa", "local.test.example") != 0 && !sent);
    assert(df_installer_start(installer, "PublicStaging/iFileSpan-test/../Package.ipa", "local.test.example") != 0 && !sent);
    assert(df_installer_start(installer, "PublicStaging/iFileSpan-test/Package.ipa", "local.test.example") == 0 && sent == 1);
    char *status = NULL;
    assert(df_installer_receive(installer, &status) == 1 && !status);
    receive_mode = 1;
    assert(df_installer_receive(installer, &status) == 0 && status && strstr(status, "Complete")); df_free(status);
    receive_mode = 2;
    assert(df_installer_receive(installer, &status) == 0 && status && strstr(status, "ApplicationVerificationFailed")); df_free(status);
    receive_mode = 3;
    assert(df_installer_receive(installer, &status) < 0 && !status);
    receive_mode = 4;
    assert(df_installer_receive(installer, &status) < 0 && !status);
    df_installer_free(installer);
    assert(freed_device == 1 && freed_service == 1);
    reject_service = 1;
    assert(!df_installer_new("test-device"));
    assert(freed_device == 2 && freed_lockdown == 2 && freed_service == 1);
    puts("Installation bridge command, status, timeout and cleanup checks passed (no device access).");
    return 0;
}
