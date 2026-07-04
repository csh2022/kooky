#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

#include <cstddef>
#include <cstring>
#include <string>
#include <vector>

#include "KookyCEFBridge.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_command_line_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/cef_application_mac.h"
#include "include/cef_api_hash.h"
#include "include/internal/cef_string.h"
#include "include/wrapper/cef_library_loader.h"

@interface KookyCEFApplication : NSApplication <CefAppProtocol> {
 @private
  BOOL handlingSendEvent_;
}
- (BOOL)isHandlingSendEvent;
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent;
@end

@implementation KookyCEFApplication
- (BOOL)isHandlingSendEvent {
  return handlingSendEvent_;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  handlingSendEvent_ = handlingSendEvent;
}
@end

namespace {

struct KookyCEFBrowser;

struct KookyCEFClient {
  cef_client_t client;
  cef_display_handler_t display;
  cef_life_span_handler_t life_span;
  cef_load_handler_t load;
  KookyCEFBrowser* owner;
};

struct KookyCEFApp {
  cef_app_t app;
};

struct KookyCEFBrowser {
  NSView* container;
  cef_browser_t* browser;
  KookyCEFClient* client;
  KookyCEFStateCallback callback;
  void* callback_context;
  std::string title;
  std::string url;
  std::string pending_url;
  int can_go_back;
  int can_go_forward;
  int is_loading;
};

bool g_initialized = false;
void* g_library_loader = nullptr;
KookyCEFApp* g_app = nullptr;
NSTimer* g_message_loop_timer = nil;

template <typename T>
void InitBase(T* value) {
  memset(value, 0, sizeof(T));
  value->base.size = sizeof(T);
  value->base.add_ref = [](cef_base_ref_counted_t*) {};
  value->base.release = [](cef_base_ref_counted_t*) -> int { return 0; };
  value->base.has_one_ref = [](cef_base_ref_counted_t*) -> int { return 1; };
  value->base.has_at_least_one_ref = [](cef_base_ref_counted_t*) -> int { return 1; };
}

std::string CefStringToStdString(const cef_string_t* value) {
  if (!value || !value->str || value->length == 0) {
    return "";
  }
  cef_string_utf8_t utf8 = {};
  cef_string_utf16_to_utf8(value->str, value->length, &utf8);
  std::string result;
  if (utf8.str && utf8.length > 0) {
    result.assign(utf8.str, utf8.length);
  }
  cef_string_utf8_clear(&utf8);
  return result;
}

void SetCefString(cef_string_t* target, const char* value) {
  cef_string_utf8_to_utf16(value ? value : "", strlen(value ? value : ""), target);
}

void AppendSwitch(cef_command_line_t* command_line, const char* name) {
  cef_string_t cef_name = {};
  SetCefString(&cef_name, name);
  command_line->append_switch(command_line, &cef_name);
  cef_string_clear(&cef_name);
}

void AppendSwitchWithValue(cef_command_line_t* command_line, const char* name, const char* value) {
  cef_string_t cef_name = {};
  cef_string_t cef_value = {};
  SetCefString(&cef_name, name);
  SetCefString(&cef_value, value);
  command_line->append_switch_with_value(command_line, &cef_name, &cef_value);
  cef_string_clear(&cef_name);
  cef_string_clear(&cef_value);
}

std::string KookyChromiumRootPath() {
  NSString* path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/kooky/chromium-root"];
  return path ? std::string([path fileSystemRepresentation]) : "";
}

void OnBeforeCommandLineProcessing(
    cef_app_t*,
    const cef_string_t*,
    cef_command_line_t* command_line) {
  if (!command_line) {
    return;
  }
  AppendSwitchWithValue(command_line, "password-store", "basic");
  AppendSwitch(command_line, "use-mock-keychain");
  std::string user_data_dir = KookyChromiumRootPath();
  if (!user_data_dir.empty()) {
    AppendSwitchWithValue(command_line, "user-data-dir", user_data_dir.c_str());
  }
  AppendSwitchWithValue(command_line, "user-agent-product", "KookyChromium/1.0");
}

KookyCEFApp* MakeApp() {
  auto* app = new KookyCEFApp();
  InitBase(&app->app);
  app->app.on_before_command_line_processing = OnBeforeCommandLineProcessing;
  return app;
}

std::string MainBundlePath() {
  NSString* path = [[NSBundle mainBundle] bundlePath];
  return path ? std::string([path fileSystemRepresentation]) : "";
}

std::string HelperExecutablePath() {
  std::string app_path = MainBundlePath();
  if (app_path.empty()) {
    return "";
  }
  return app_path + "/Contents/Frameworks/Kooky Helper.app/Contents/MacOS/Kooky Helper";
}

std::string ParentDirectory(const std::string& path) {
  size_t slash = path.find_last_of('/');
  if (slash == std::string::npos || slash == 0) {
    return path;
  }
  return path.substr(0, slash);
}

KookyCEFBrowser* OwnerFromClient(cef_client_t* self) {
  return reinterpret_cast<KookyCEFClient*>(self)->owner;
}

KookyCEFBrowser* OwnerFromDisplay(cef_display_handler_t* self) {
  return reinterpret_cast<KookyCEFClient*>(
      reinterpret_cast<char*>(self) - offsetof(KookyCEFClient, display))->owner;
}

KookyCEFBrowser* OwnerFromLifeSpan(cef_life_span_handler_t* self) {
  return reinterpret_cast<KookyCEFClient*>(
      reinterpret_cast<char*>(self) - offsetof(KookyCEFClient, life_span))->owner;
}

KookyCEFBrowser* OwnerFromLoad(cef_load_handler_t* self) {
  return reinterpret_cast<KookyCEFClient*>(
      reinterpret_cast<char*>(self) - offsetof(KookyCEFClient, load))->owner;
}

void Publish(KookyCEFBrowser* owner) {
  if (!owner || !owner->callback) {
    return;
  }
  owner->callback(
      owner->callback_context,
      owner->title.c_str(),
      owner->url.c_str(),
      owner->can_go_back,
      owner->can_go_forward,
      owner->is_loading);
}

void LoadURLOnBrowser(KookyCEFBrowser* owner, const char* url) {
  if (!owner || !owner->browser) {
    return;
  }
  auto* frame = owner->browser->get_main_frame(owner->browser);
  if (!frame) {
    return;
  }
  cef_string_t cef_url = {};
  SetCefString(&cef_url, url ? url : "about:blank");
  frame->load_url(frame, &cef_url);
  cef_string_clear(&cef_url);
}

cef_display_handler_t* GetDisplayHandler(cef_client_t* self) {
  return &reinterpret_cast<KookyCEFClient*>(self)->display;
}

cef_life_span_handler_t* GetLifeSpanHandler(cef_client_t* self) {
  return &reinterpret_cast<KookyCEFClient*>(self)->life_span;
}

cef_load_handler_t* GetLoadHandler(cef_client_t* self) {
  return &reinterpret_cast<KookyCEFClient*>(self)->load;
}

void OnAddressChange(
    cef_display_handler_t* self,
    cef_browser_t*,
    cef_frame_t*,
    const cef_string_t* url) {
  auto* owner = OwnerFromDisplay(self);
  owner->url = CefStringToStdString(url);
  Publish(owner);
}

void OnTitleChange(cef_display_handler_t* self, cef_browser_t*, const cef_string_t* title) {
  auto* owner = OwnerFromDisplay(self);
  owner->title = CefStringToStdString(title);
  Publish(owner);
}

void OnAfterCreated(cef_life_span_handler_t* self, cef_browser_t* browser) {
  auto* owner = OwnerFromLifeSpan(self);
  owner->browser = browser;
  if (browser && browser->base.add_ref) {
    browser->base.add_ref(&browser->base);
  }
  if (!owner->pending_url.empty()) {
    LoadURLOnBrowser(owner, owner->pending_url.c_str());
    owner->pending_url.clear();
  }
  Publish(owner);
}

void OnBeforeClose(cef_life_span_handler_t* self, cef_browser_t* browser) {
  auto* owner = OwnerFromLifeSpan(self);
  if (owner->browser == browser) {
    owner->browser = nullptr;
  }
  Publish(owner);
}

void OnLoadingStateChange(
    cef_load_handler_t* self,
    cef_browser_t*,
    int isLoading,
    int canGoBack,
    int canGoForward) {
  auto* owner = OwnerFromLoad(self);
  owner->is_loading = isLoading;
  owner->can_go_back = canGoBack;
  owner->can_go_forward = canGoForward;
  Publish(owner);
}

KookyCEFClient* MakeClient(KookyCEFBrowser* owner) {
  auto* client = new KookyCEFClient();
  InitBase(&client->client);
  InitBase(&client->display);
  InitBase(&client->life_span);
  InitBase(&client->load);
  client->owner = owner;
  client->client.get_display_handler = GetDisplayHandler;
  client->client.get_life_span_handler = GetLifeSpanHandler;
  client->client.get_load_handler = GetLoadHandler;
  client->display.on_address_change = OnAddressChange;
  client->display.on_title_change = OnTitleChange;
  client->life_span.on_after_created = OnAfterCreated;
  client->life_span.on_before_close = OnBeforeClose;
  client->load.on_loading_state_change = OnLoadingStateChange;
  return client;
}

}  // namespace

int KookyCEFInstallApplication(void) {
  if (NSApp) {
    return [NSApp isKindOfClass:[KookyCEFApplication class]] ? 1 : 0;
  }
  [KookyCEFApplication sharedApplication];
  return [NSApp isKindOfClass:[KookyCEFApplication class]] ? 1 : 0;
}

int KookyCEFInitialize(const char* cache_path) {
  if (g_initialized) {
    return 1;
  }
  if (!KookyCEFInstallApplication()) {
    return 0;
  }
  g_library_loader = cef_scoped_library_loader_create(0);
  if (!g_library_loader) {
    return 0;
  }
  cef_api_hash(CEF_API_VERSION, 0);

  std::vector<std::string> arg_values;
  std::vector<char*> argv;
  NSArray<NSString*>* arguments = [[NSProcessInfo processInfo] arguments];
  for (NSString* argument in arguments) {
    arg_values.emplace_back([argument UTF8String]);
  }
  argv.reserve(arg_values.size());
  for (auto& argument : arg_values) {
    argv.push_back(argument.data());
  }

  cef_main_args_t args = {};
  args.argc = static_cast<int>(argv.size());
  args.argv = argv.empty() ? nullptr : argv.data();

  cef_settings_t settings = {};
  settings.size = sizeof(settings);
  settings.no_sandbox = 1;
  settings.external_message_pump = 0;
  SetCefString(&settings.user_agent_product, "KookyChromium/1.0");
  std::string helper_path = HelperExecutablePath();
  if (!helper_path.empty()) {
    SetCefString(&settings.browser_subprocess_path, helper_path.c_str());
  }
  if (cache_path && strlen(cache_path) > 0) {
    std::string root_path = ParentDirectory(cache_path);
    SetCefString(&settings.cache_path, cache_path);
    SetCefString(&settings.root_cache_path, root_path.c_str());
  }

  if (!g_app) {
    g_app = MakeApp();
  }
  if (!cef_initialize(&args, &settings, &g_app->app, nullptr)) {
    cef_string_clear(&settings.user_agent_product);
    cef_string_clear(&settings.browser_subprocess_path);
    cef_string_clear(&settings.cache_path);
    cef_string_clear(&settings.root_cache_path);
    return 0;
  }
  cef_string_clear(&settings.user_agent_product);
  cef_string_clear(&settings.browser_subprocess_path);
  cef_string_clear(&settings.cache_path);
  cef_string_clear(&settings.root_cache_path);

  g_message_loop_timer = [NSTimer scheduledTimerWithTimeInterval:0.01
                                                        repeats:YES
                                                          block:^(NSTimer*) {
                                                            cef_do_message_loop_work();
                                                          }];
  g_initialized = true;
  return 1;
}

void KookyCEFDoMessageLoopWork(void) {
  if (g_initialized) {
    cef_do_message_loop_work();
  }
}

void* KookyCEFCreateBrowser(const char* url, KookyCEFStateCallback callback, void* context) {
  if (!g_initialized) {
    return nullptr;
  }
  auto* owner = new KookyCEFBrowser();
  owner->container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1280, 800)];
  owner->browser = nullptr;
  owner->client = MakeClient(owner);
  owner->callback = callback;
  owner->callback_context = context;
  owner->title = "Chromium";
  owner->url = url ? url : "";
  owner->pending_url = "";
  owner->can_go_back = 0;
  owner->can_go_forward = 0;
  owner->is_loading = 0;

  cef_window_info_t window_info = {};
  window_info.size = sizeof(window_info);
  window_info.parent_view = CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(owner->container);
  window_info.bounds.x = 0;
  window_info.bounds.y = 0;
  window_info.bounds.width = 1280;
  window_info.bounds.height = 800;
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

  cef_browser_settings_t browser_settings = {};
  browser_settings.size = sizeof(browser_settings);
  cef_string_t cef_url = {};
  SetCefString(&cef_url, url ? url : "about:blank");
  int ok = cef_browser_host_create_browser(
      &window_info,
      &owner->client->client,
      &cef_url,
      &browser_settings,
      nullptr,
      nullptr);
  cef_string_clear(&cef_url);
  if (!ok) {
    return nullptr;
  }
  Publish(owner);
  return owner;
}

void* KookyCEFGetView(void* browser) {
  auto* owner = reinterpret_cast<KookyCEFBrowser*>(browser);
  return owner ? (__bridge void*)owner->container : nullptr;
}

void KookyCEFLoadURL(void* browser, const char* url) {
  auto* owner = reinterpret_cast<KookyCEFBrowser*>(browser);
  if (!owner) {
    return;
  }
  owner->url = url ? url : "about:blank";
  if (!owner->browser) {
    owner->pending_url = owner->url;
    Publish(owner);
    return;
  }
  LoadURLOnBrowser(owner, owner->url.c_str());
}

void KookyCEFReload(void* browser) {
  auto* owner = reinterpret_cast<KookyCEFBrowser*>(browser);
  if (owner && owner->browser) {
    owner->browser->reload(owner->browser);
  }
}

void KookyCEFStopLoading(void* browser) {
  auto* owner = reinterpret_cast<KookyCEFBrowser*>(browser);
  if (owner && owner->browser) {
    owner->browser->stop_load(owner->browser);
  }
}

void KookyCEFGoBack(void* browser) {
  auto* owner = reinterpret_cast<KookyCEFBrowser*>(browser);
  if (owner && owner->browser && owner->browser->can_go_back(owner->browser)) {
    owner->browser->go_back(owner->browser);
  }
}

void KookyCEFGoForward(void* browser) {
  auto* owner = reinterpret_cast<KookyCEFBrowser*>(browser);
  if (owner && owner->browser && owner->browser->can_go_forward(owner->browser)) {
    owner->browser->go_forward(owner->browser);
  }
}

void KookyCEFCloseBrowser(void* browser) {
  auto* owner = reinterpret_cast<KookyCEFBrowser*>(browser);
  if (!owner) {
    return;
  }
  if (owner->browser) {
    auto* host = owner->browser->get_host(owner->browser);
    if (host) {
      host->close_browser(host, 1);
    }
    if (owner->browser->base.release) {
      owner->browser->base.release(&owner->browser->base);
    }
  }
  delete owner->client;
  [owner->container removeFromSuperview];
  delete owner;
}
