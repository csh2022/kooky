#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*KookyCEFStateCallback)(
    void* context,
    const char* title,
    const char* url,
    int can_go_back,
    int can_go_forward,
    int is_loading);

int KookyCEFInstallApplication(void);
int KookyCEFInitialize(const char* cache_path);
void KookyCEFDoMessageLoopWork(void);
void* KookyCEFCreateBrowser(const char* url, KookyCEFStateCallback callback, void* context);
void* KookyCEFGetView(void* browser);
void KookyCEFLoadURL(void* browser, const char* url);
void KookyCEFReload(void* browser);
void KookyCEFStopLoading(void* browser);
void KookyCEFGoBack(void* browser);
void KookyCEFGoForward(void* browser);
void KookyCEFCloseBrowser(void* browser);

#ifdef __cplusplus
}
#endif
