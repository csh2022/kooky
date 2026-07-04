#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

#include <cstddef>
#include <cstring>
#include <dispatch/dispatch.h>
#include <map>
#include <mutex>
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
#include "include/capi/cef_process_message_capi.h"
#include "include/capi/cef_render_process_handler_capi.h"
#include "include/capi/cef_values_capi.h"
#include "include/capi/cef_v8_capi.h"
#include "include/cef_application_mac.h"
#include "include/cef_api_hash.h"
#include "include/internal/cef_string.h"
#include "include/wrapper/cef_library_loader.h"

static void KookyCEFResizeBrowser(void* owner);

@interface KookyCEFContainerView : NSView
@property(nonatomic, assign) void* browserOwner;
@end

@implementation KookyCEFContainerView
- (BOOL)isFlipped {
  return YES;
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  KookyCEFResizeBrowser(self.browserOwner);
}

- (void)layout {
  [super layout];
  KookyCEFResizeBrowser(self.browserOwner);
}
@end

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

struct KookyCEFEvaluation {
  KookyCEFEvaluateCallback callback;
  void* context;
};

struct KookyCEFApp {
  cef_app_t app;
  cef_render_process_handler_t render;
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
  int closing;
  int next_eval_id;
  std::mutex eval_mutex;
  std::map<int, KookyCEFEvaluation> evaluations;
};

bool g_initialized = false;
void* g_library_loader = nullptr;
KookyCEFApp* g_app = nullptr;
NSTimer* g_message_loop_timer = nil;
std::mutex g_browser_map_mutex;
std::map<int, KookyCEFBrowser*> g_browsers_by_id;
std::mutex g_render_context_mutex;
std::map<std::string, cef_v8_context_t*> g_render_contexts;

constexpr const char* kEvalMessageName = "KookyEval";
constexpr const char* kEvalResultMessageName = "KookyEvalResult";
constexpr const char* kEvalContextNotReadyResult = "__KOOKY_CONTEXT_NOT_READY__";

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

std::string CefUserFreeStringToStdString(cef_string_userfree_t value) {
  if (!value) {
    return "";
  }
  std::string result = CefStringToStdString(value);
  cef_string_userfree_free(value);
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

cef_render_process_handler_t* GetRenderProcessHandler(cef_app_t* self);
void OnContextCreated(
    cef_render_process_handler_t*,
    cef_browser_t* browser,
    cef_frame_t* frame,
    cef_v8_context_t* context);
void OnContextReleased(
    cef_render_process_handler_t*,
    cef_browser_t* browser,
    cef_frame_t* frame,
    cef_v8_context_t* context);
int OnRenderProcessMessageReceived(
    cef_render_process_handler_t*,
    cef_browser_t* browser,
    cef_frame_t* frame,
    cef_process_id_t source_process,
    cef_process_message_t* message);

KookyCEFApp* MakeApp() {
  auto* app = new KookyCEFApp();
  InitBase(&app->app);
  InitBase(&app->render);
  app->app.on_before_command_line_processing = OnBeforeCommandLineProcessing;
  app->app.get_render_process_handler = GetRenderProcessHandler;
  app->render.on_context_created = OnContextCreated;
  app->render.on_context_released = OnContextReleased;
  app->render.on_process_message_received = OnRenderProcessMessageReceived;
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

std::string FrameKey(cef_browser_t* browser, cef_frame_t* frame) {
  if (!browser || !frame) {
    return "";
  }
  std::string frame_id = CefUserFreeStringToStdString(frame->get_identifier(frame));
  return std::to_string(browser->get_identifier(browser)) + ":" + frame_id;
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

KookyCEFBrowser* OwnerFromBrowserId(int browser_id) {
  std::lock_guard<std::mutex> lock(g_browser_map_mutex);
  auto it = g_browsers_by_id.find(browser_id);
  return it == g_browsers_by_id.end() ? nullptr : it->second;
}

void FinishEvaluation(KookyCEFBrowser* owner, int message_id, const std::string& result);

void Publish(KookyCEFBrowser* owner) {
  if (!owner || owner->closing || !owner->callback) {
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

void ResizeBrowser(KookyCEFBrowser* owner) {
  if (!owner || !owner->container || !owner->browser) {
    return;
  }
  auto* host = owner->browser->get_host(owner->browser);
  if (!host) {
    return;
  }
  NSView* browser_view = (__bridge NSView*)host->get_window_handle(host);
  if (browser_view) {
    browser_view.frame = owner->container.bounds;
    browser_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  }
  host->was_resized(host);
}

std::string JSONValueToString(id value) {
  if (!value || value == [NSNull null]) {
    return "";
  }
  if ([value isKindOfClass:[NSString class]]) {
    return [(NSString*)value UTF8String];
  }
  if ([value isKindOfClass:[NSNumber class]]) {
    return [[(NSNumber*)value stringValue] UTF8String];
  }
  NSData* encoded = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
  if (!encoded) {
    return "";
  }
  NSString* json = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
  return json ? [json UTF8String] : "";
}

std::string ParseJSONValueToString(const std::string& json) {
  if (json.empty() || json == "undefined") {
    return "";
  }
  NSData* data = [NSData dataWithBytes:json.data() length:json.size()];
  NSError* error = nil;
  id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  return error ? "" : JSONValueToString(object);
}

std::string JSONStringLiteral(const std::string& value) {
  NSString* string = [[NSString alloc] initWithBytes:value.data()
                                             length:value.size()
                                           encoding:NSUTF8StringEncoding];
  if (!string) {
    string = @"";
  }
  NSArray* array = @[ string ];
  NSData* data = [NSJSONSerialization dataWithJSONObject:array options:0 error:nil];
  NSString* json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[\"\"]";
  if (!json || json.length < 2) {
    return "\"\"";
  }
  NSString* literal = [json substringWithRange:NSMakeRange(1, json.length - 2)];
  return [literal UTF8String] ? [literal UTF8String] : "\"\"";
}

std::string V8ValueToString(cef_v8_value_t* value) {
  if (!value || !value->is_valid(value) || value->is_undefined(value) || value->is_null(value)) {
    return "";
  }
  if (value->is_string(value)) {
    return CefUserFreeStringToStdString(value->get_string_value(value));
  }
  if (value->is_bool(value)) {
    return value->get_bool_value(value) ? "true" : "false";
  }
  if (value->is_int(value)) {
    return std::to_string(value->get_int_value(value));
  }
  if (value->is_uint(value)) {
    return std::to_string(value->get_uint_value(value));
  }
  if (value->is_double(value)) {
    return std::to_string(value->get_double_value(value));
  }
  return "";
}

std::string EvaluateInRenderContext(cef_v8_context_t* context, const std::string& script) {
  if (!context || !context->enter(context)) {
    return "";
  }
  cef_string_t code = {};
  cef_string_t script_url = {};
  SetCefString(&code, script.c_str());
  SetCefString(&script_url, "kooky://eval");
  cef_v8_value_t* retval = nullptr;
  cef_v8_exception_t* exception = nullptr;
  std::string result;
  if (context->eval(context, &code, &script_url, 1, &retval, &exception)) {
    result = V8ValueToString(retval);
  }
  if (retval && retval->base.release) {
    retval->base.release(&retval->base);
  }
  if (exception && exception->base.release) {
    exception->base.release(&exception->base);
  }
  cef_string_clear(&code);
  cef_string_clear(&script_url);
  context->exit(context);
  return result;
}

void FinishEvaluation(KookyCEFBrowser* owner, int message_id, const std::string& result) {
  if (!owner) {
    return;
  }
  KookyCEFEvaluation evaluation = {};
  {
    std::lock_guard<std::mutex> lock(owner->eval_mutex);
    auto it = owner->evaluations.find(message_id);
    if (it == owner->evaluations.end()) {
      return;
    }
    evaluation = it->second;
    owner->evaluations.erase(it);
  }
  if (evaluation.callback) {
    evaluation.callback(evaluation.context, result.c_str());
  }
}

bool FinishEvaluationFromConsoleMessage(KookyCEFBrowser* owner, const std::string& message) {
  static const std::string prefix = "__KOOKY_EVAL_RESULT__";
  if (message.rfind(prefix, 0) != 0) {
    return false;
  }
  size_t marker = message.find("__", prefix.size());
  if (marker == std::string::npos) {
    return false;
  }
  int message_id = atoi(message.substr(prefix.size(), marker - prefix.size()).c_str());
  std::string json = message.substr(marker + 2);
  FinishEvaluation(owner, message_id, ParseJSONValueToString(json));
  return true;
}

void FinishAllEvaluations(KookyCEFBrowser* owner) {
  if (!owner) {
    return;
  }
  std::map<int, KookyCEFEvaluation> evaluations;
  {
    std::lock_guard<std::mutex> lock(owner->eval_mutex);
    evaluations.swap(owner->evaluations);
  }
  for (const auto& item : evaluations) {
    if (item.second.callback) {
      item.second.callback(item.second.context, "");
    }
  }
}

}  // namespace

static void KookyCEFResizeBrowser(void* owner) {
  ResizeBrowser(reinterpret_cast<KookyCEFBrowser*>(owner));
}

namespace {

cef_display_handler_t* GetDisplayHandler(cef_client_t* self) {
  return &reinterpret_cast<KookyCEFClient*>(self)->display;
}

cef_life_span_handler_t* GetLifeSpanHandler(cef_client_t* self) {
  return &reinterpret_cast<KookyCEFClient*>(self)->life_span;
}

cef_load_handler_t* GetLoadHandler(cef_client_t* self) {
  return &reinterpret_cast<KookyCEFClient*>(self)->load;
}

cef_render_process_handler_t* GetRenderProcessHandler(cef_app_t* self) {
  return &reinterpret_cast<KookyCEFApp*>(self)->render;
}

void OnContextCreated(
    cef_render_process_handler_t*,
    cef_browser_t* browser,
    cef_frame_t* frame,
    cef_v8_context_t* context) {
  if (!browser || !frame || !context || !frame->is_main(frame)) {
    return;
  }
  std::string key = FrameKey(browser, frame);
  if (key.empty()) {
    return;
  }
  if (context->base.add_ref) {
    context->base.add_ref(&context->base);
  }
  std::lock_guard<std::mutex> lock(g_render_context_mutex);
  auto existing = g_render_contexts.find(key);
  if (existing != g_render_contexts.end() && existing->second && existing->second->base.release) {
    existing->second->base.release(&existing->second->base);
  }
  g_render_contexts[key] = context;
}

void OnContextReleased(
    cef_render_process_handler_t*,
    cef_browser_t* browser,
    cef_frame_t* frame,
    cef_v8_context_t* context) {
  if (!browser || !frame || !context) {
    return;
  }
  std::string key = FrameKey(browser, frame);
  std::lock_guard<std::mutex> lock(g_render_context_mutex);
  auto existing = g_render_contexts.find(key);
  if (existing != g_render_contexts.end()) {
    if (existing->second && existing->second->base.release) {
      existing->second->base.release(&existing->second->base);
    }
    g_render_contexts.erase(existing);
  }
}

int OnRenderProcessMessageReceived(
    cef_render_process_handler_t*,
    cef_browser_t* browser,
    cef_frame_t* frame,
    cef_process_id_t,
    cef_process_message_t* message) {
  if (!browser || !frame || !message) {
    return 0;
  }
  std::string name = CefUserFreeStringToStdString(message->get_name(message));
  if (name != kEvalMessageName) {
    return 0;
  }
  cef_list_value_t* args = message->get_argument_list(message);
  if (!args || args->get_size(args) < 2) {
    return 1;
  }
  int message_id = args->get_int(args, 0);
  std::string script = CefUserFreeStringToStdString(args->get_string(args, 1));

  cef_v8_context_t* context = nullptr;
  std::string key = FrameKey(browser, frame);
  {
    std::lock_guard<std::mutex> lock(g_render_context_mutex);
    auto it = g_render_contexts.find(key);
    if (it != g_render_contexts.end()) {
      context = it->second;
      if (context && context->base.add_ref) {
        context->base.add_ref(&context->base);
      }
    }
  }
  std::string result = context ? EvaluateInRenderContext(context, script) : kEvalContextNotReadyResult;
  if (context && context->base.release) {
    context->base.release(&context->base);
  }

  cef_string_t result_name = {};
  SetCefString(&result_name, kEvalResultMessageName);
  cef_process_message_t* response = cef_process_message_create(&result_name);
  cef_string_clear(&result_name);
  if (!response) {
    return 1;
  }
  cef_list_value_t* response_args = response->get_argument_list(response);
  response_args->set_int(response_args, 0, message_id);
  cef_string_t result_value = {};
  SetCefString(&result_value, result.c_str());
  response_args->set_string(response_args, 1, &result_value);
  cef_string_clear(&result_value);
  frame->send_process_message(frame, PID_BROWSER, response);
  return 1;
}

int OnClientProcessMessageReceived(
    cef_client_t*,
    cef_browser_t* browser,
    cef_frame_t*,
    cef_process_id_t,
    cef_process_message_t* message) {
  if (!browser || !message) {
    return 0;
  }
  std::string name = CefUserFreeStringToStdString(message->get_name(message));
  if (name != kEvalResultMessageName) {
    return 0;
  }
  cef_list_value_t* args = message->get_argument_list(message);
  if (!args || args->get_size(args) < 2) {
    return 1;
  }
  int message_id = args->get_int(args, 0);
  std::string result = CefUserFreeStringToStdString(args->get_string(args, 1));
  FinishEvaluation(OwnerFromBrowserId(browser->get_identifier(browser)), message_id, result);
  return 1;
}

void OnAddressChange(
    cef_display_handler_t* self,
    cef_browser_t*,
    cef_frame_t*,
    const cef_string_t* url) {
  auto* owner = OwnerFromDisplay(self);
  std::string next_url = CefStringToStdString(url);
  if (next_url == "about:blank" && !owner->url.empty() && owner->url != "about:blank") {
    return;
  }
  owner->url = next_url;
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
  if (browser) {
    std::lock_guard<std::mutex> lock(g_browser_map_mutex);
    g_browsers_by_id[browser->get_identifier(browser)] = owner;
  }
  if (owner->closing) {
    auto* host = browser ? browser->get_host(browser) : nullptr;
    if (host) {
      host->close_browser(host, 1);
    }
    return;
  }
  ResizeBrowser(owner);
  if (!owner->pending_url.empty()) {
    LoadURLOnBrowser(owner, owner->pending_url.c_str());
    owner->pending_url.clear();
  }
  Publish(owner);
}

void OnBeforeClose(cef_life_span_handler_t* self, cef_browser_t* browser) {
  auto* owner = OwnerFromLifeSpan(self);
  if (browser) {
    std::lock_guard<std::mutex> lock(g_browser_map_mutex);
    auto it = g_browsers_by_id.find(browser->get_identifier(browser));
    if (it != g_browsers_by_id.end() && it->second == owner) {
      g_browsers_by_id.erase(it);
    }
  }
  if (owner->browser == browser) {
    if (owner->browser && owner->browser->base.release) {
      owner->browser->base.release(&owner->browser->base);
    }
    owner->browser = nullptr;
  }
  if (owner->closing) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FinishAllEvaluations(owner);
      delete owner->client;
      delete owner;
    });
    return;
  }
  Publish(owner);
}

int OnConsoleMessage(
    cef_display_handler_t* self,
    cef_browser_t*,
    cef_log_severity_t,
    const cef_string_t* message,
    const cef_string_t*,
    int) {
  auto* owner = OwnerFromDisplay(self);
  return FinishEvaluationFromConsoleMessage(owner, CefStringToStdString(message)) ? 1 : 0;
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
  client->client.on_process_message_received = OnClientProcessMessageReceived;
  client->display.on_address_change = OnAddressChange;
  client->display.on_title_change = OnTitleChange;
  client->display.on_console_message = OnConsoleMessage;
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

int KookyCEFExecuteProcess(int argc, char* argv[]) {
  void* loader = cef_scoped_library_loader_create(1);
  if (!loader) {
    return 1;
  }
  cef_api_hash(CEF_API_VERSION, 0);
  cef_main_args_t args = {};
  args.argc = argc;
  args.argv = argv;
  if (!g_app) {
    g_app = MakeApp();
  }
  int result = cef_execute_process(&args, &g_app->app, nullptr);
  cef_scoped_library_loader_free(loader);
  return result;
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

static void* KookyCEFCreateBrowserWithParent(NSView* parent, const char* url, KookyCEFStateCallback callback, void* context) {
  if (!g_initialized) {
    return nullptr;
  }
  auto* owner = new KookyCEFBrowser();
  NSRect frame = parent ? parent.bounds : NSMakeRect(0, 0, 1280, 800);
  if (frame.size.width <= 0 || frame.size.height <= 0) {
    frame = NSMakeRect(0, 0, 1280, 800);
  }
  auto* container = [[KookyCEFContainerView alloc] initWithFrame:frame];
  container.browserOwner = owner;
  container.wantsLayer = YES;
  container.layer.masksToBounds = YES;
  container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  if (parent) {
    [parent addSubview:container];
  }
  owner->container = container;
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
  owner->closing = 0;
  owner->next_eval_id = 1;

  cef_window_info_t window_info = {};
  window_info.size = sizeof(window_info);
  window_info.parent_view = CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(owner->container);
  window_info.bounds.x = 0;
  window_info.bounds.y = 0;
  window_info.bounds.width = static_cast<int>(frame.size.width);
  window_info.bounds.height = static_cast<int>(frame.size.height);
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
    [container removeFromSuperview];
    delete owner->client;
    delete owner;
    return nullptr;
  }
  Publish(owner);
  return owner;
}

void* KookyCEFCreateBrowser(const char* url, KookyCEFStateCallback callback, void* context) {
  return KookyCEFCreateBrowserWithParent(nil, url, callback, context);
}

void* KookyCEFCreateBrowserInView(void* parent_view, const char* url, KookyCEFStateCallback callback, void* context) {
  if (!parent_view) {
    return nullptr;
  }
  NSView* parent = (__bridge NSView*)parent_view;
  return KookyCEFCreateBrowserWithParent(parent, url, callback, context);
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

void KookyCEFEvaluateJavaScript(
    void* browser,
    const char* script,
    KookyCEFEvaluateCallback callback,
    void* context) {
  auto* owner = reinterpret_cast<KookyCEFBrowser*>(browser);
  if (!owner || owner->closing || !owner->browser || !callback) {
    if (callback) {
      callback(context, "");
    }
    return;
  }
  std::string script_copy = script ? script : "";
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!owner || owner->closing || !owner->browser) {
      callback(context, "");
      return;
    }
    auto* frame = owner->browser->get_main_frame(owner->browser);
    if (!frame) {
      callback(context, "");
      return;
    }

    int message_id = owner->next_eval_id++;
    {
      std::lock_guard<std::mutex> lock(owner->eval_mutex);
      owner->evaluations[message_id] = { callback, context };
    }

    cef_string_t name = {};
    SetCefString(&name, kEvalMessageName);
    cef_process_message_t* message = cef_process_message_create(&name);
    cef_string_clear(&name);
    if (!message) {
      FinishEvaluation(owner, message_id, "");
      return;
    }
    cef_list_value_t* args = message->get_argument_list(message);
    args->set_int(args, 0, message_id);
    cef_string_t source = {};
    SetCefString(&source, script_copy.c_str());
    args->set_string(args, 1, &source);
    cef_string_clear(&source);
    frame->send_process_message(frame, PID_RENDERER, message);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      FinishEvaluation(owner, message_id, "");
    });
  });
}

void KookyCEFCloseBrowser(void* browser) {
  auto* owner = reinterpret_cast<KookyCEFBrowser*>(browser);
  if (!owner) {
    return;
  }
  if (owner->closing) {
    return;
  }
  owner->closing = 1;
  owner->callback = nullptr;
  owner->callback_context = nullptr;
  FinishAllEvaluations(owner);
  if (owner->browser) {
    auto* host = owner->browser->get_host(owner->browser);
    if (host) {
      host->close_browser(host, 1);
    }
  }
}
