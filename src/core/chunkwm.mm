#define CHUNKWM_CORE

#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>
#include <getopt.h>

#include <execinfo.h>
#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>

#include "dispatch/carbon.h"
#include "dispatch/workspace.h"
#include "dispatch/display.h"
#include "dispatch/event.h"

#include "hotloader.h"
#include "state.h"
#include "plugin.h"
#include "wqueue.h"
#include "cvar.h"
#include "constants.h"

#include "clog.h"
#include "clog.c"

#include "../common/misc/carbon.cpp"
#include "../common/misc/workspace.mm"

#include "../common/accessibility/observer.cpp"
#include "../common/accessibility/application.cpp"
#include "../common/accessibility/window.cpp"
#include "../common/accessibility/element.cpp"

#include "../common/ipc/daemon.cpp"
#include "../common/config/tokenize.cpp"
#include "../common/config/cvar.cpp"

#include "dispatch/carbon.cpp"
#include "dispatch/workspace.mm"
#include "dispatch/event.cpp"
#include "dispatch/display.cpp"

#include "hotloader.cpp"
#include "state.cpp"
#include "callback.cpp"
#include "plugin.cpp"
#include "wqueue.cpp"
#include "config.cpp"
#include "cvar.cpp"

#define internal static
#define local_persist static

internal carbon_event_handler Carbon;
internal char *ConfigAbsolutePath;

inline void
Fail(const char *Format, ...)
{
    va_list Args;
    va_start(Args, Format);
    vfprintf(stderr, Format, Args);
    va_end(Args);
    exit(EXIT_FAILURE);
}

inline AXUIElementRef
SystemWideElement()
{
    local_persist AXUIElementRef Element;
    local_persist dispatch_once_t Token;

    dispatch_once(&Token, ^{
        Element = AXUIElementCreateSystemWide();
    });

    return Element;
}

internal void
ForkExecWait(char *Command)
{
    static const char *Shell = "/bin/bash";
    static const char *Arg   = "-c";

    int Pid = fork();
    if (Pid == -1) {
        c_log(C_LOG_LEVEL_ERROR, "chunkwm: fork failed, config-file did not execute!\n");
    } else if (Pid > 0) {
        int Status;
        waitpid(Pid, &Status, 0);
    } else {
        char *Exec[] = { (char*)Shell, (char*)Arg, Command, NULL};
        int StatusCode = execvp(Exec[0], Exec);
        exit(StatusCode);
    }
}

inline bool
CheckAccessibilityPrivileges()
{
    const void *Keys[] = { kAXTrustedCheckOptionPrompt };
    const void *Values[] = { kCFBooleanTrue };

    CFDictionaryRef Options = CFDictionaryCreate(kCFAllocatorDefault,
                                                 Keys,
                                                 Values,
                                                 sizeof(Keys) / sizeof(*Keys),
                                                 &kCFCopyStringDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);

    bool Result = AXIsProcessTrustedWithOptions(Options);
    CFRelease(Options);

    return Result;
}

inline void
SetConfigFile(char *ConfigFile, size_t Size)
{
    if (ConfigAbsolutePath) {
        snprintf(ConfigFile, Size, "%s", ConfigAbsolutePath);
    } else {
        const char *HomeEnv = getenv("HOME");
        if (!HomeEnv) {
            Fail("chunkwm: 'env HOME' not set! abort..\n");
        }

        snprintf(ConfigFile, Size, "%s/%s", HomeEnv, CHUNKWM_CONFIG);
    }

}

internal bool
ParseArguments(int Count, char **Args)
{
    int Option;
    const char *Short = "vc:";
    struct option Long[] = {
        { "version", no_argument, NULL, 'v' },
        { "config", required_argument, NULL, 'c' },
        { NULL, 0, NULL, 0 }
    };

    while ((Option = getopt_long(Count, Args, Short, Long, NULL)) != -1) {
        switch (Option) {
        case 'v': {
            printf("chunkwm %d.%d.%d\n",
                    CHUNKWM_MAJOR,
                    CHUNKWM_MINOR,
                    CHUNKWM_PATCH);
            return true;
        } break;
        case 'c': {
            ConfigAbsolutePath = strdup(optarg);
        } break;
        }
    }

    optind = 1;
    return false;
}

int main(int Count, char **Args)
{
    if (ParseArguments(Count, Args)) {
        return EXIT_SUCCESS;
    }

    if (!CheckAccessibilityPrivileges()) {
        Fail("chunkwm: could not access accessibility features! abort..\n");
    }

    if (!StartDaemon(CHUNKWM_PORT, DaemonCallback)) {
        Fail("chunkwm: failed to initialize daemon! abort..\n");
    }

    if (!BeginCVars()) {
        Fail("chunkwm: failed to initialize cvars! abort..\n");
    }

    if (!BeginPlugins()) {
        Fail("chunkwm: failed to initialize critical mutex! abort..\n");
    }

    if (!BeginEventLoop()) {
        Fail("chunkwm: could not initialize event-loop! abort..\n");
    }

    NSApplicationLoad();
    AXUIElementSetMessagingTimeout(SystemWideElement(), 1.0);

    char ConfigFile[MAX_LEN];
    ConfigFile[0] = '\0';
    SetConfigFile(ConfigFile, MAX_LEN);

    struct stat Buffer;
    if (stat(ConfigFile, &Buffer) != 0) {
        Fail("chunkwm: config '%s' not found!\n", ConfigFile);
    }

    // NOTE(koekeishiya): The config file is just an executable bash script!
    ForkExecWait(ConfigFile);

    if (!InitState()) {
        Fail("chunkwm: failed to initialize critical mutex! abort..\n");
    }

    if (!BeginCallbackThreads(CHUNKWM_THREAD_COUNT)) {
        c_log(C_LOG_LEVEL_WARN, "chunkwm: could not get semaphore, callback multi-threading disabled..\n");
    }

    if (!BeginCarbonEventHandler(&Carbon)) {
        Fail("chunkwm: failed to install carbon eventhandler! abort..\n");
    }

    if (!BeginDisplayHandler()) {
        c_log(C_LOG_LEVEL_WARN, "chunkwm: could not register for display notifications..\n");
    }

    // NOTE(koekeishiya): Read plugin directory from cvar.
    char *PluginDirectory = CVarStringValue(CVAR_PLUGIN_DIR);
    if (PluginDirectory && CVarIntegerValue(CVAR_PLUGIN_HOTLOAD)) {
        HotloaderAddPath(PluginDirectory);
        HotloaderInit();
    }

    BeginSharedWorkspace();
    StartEventLoop();
    CFRunLoopRun();

    return EXIT_SUCCESS;
}
