#include "include/capi/cef_app_capi.h"
#include "include/cef_api_hash.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  void* loader = cef_scoped_library_loader_create(1);
  if (!loader) {
    return 1;
  }
  cef_api_hash(CEF_API_VERSION, 0);
  cef_main_args_t args = {};
  args.argc = argc;
  args.argv = argv;
  int result = cef_execute_process(&args, 0, 0);
  cef_scoped_library_loader_free(loader);
  return result;
}
