// vcam-camera-gate: keep the physical webcam closed unless some app is using the OBS Virtual Camera.
//
// Why a plugin: on macOS, OBS 33's Video Capture Device source has no "deactivate when not showing" option, and the
// virtual camera extension never tells OBS whether a client is connected. CoreMediaIO's
// kCMIODevicePropertyDeviceIsRunningSomewhere on the virtual camera is the clean signal, but OBS's own feed into the
// extension (the sink stream) also counts, so the flag stays 1 for as long as OBS's virtual camera output runs.
//
// How it works:
//   IDLE    Virtual camera output stopped, webcam released. The flag now means "a client is streaming", so
//           0 -> 1 is a reliable arrival signal: restore the webcam and start the output (ACTIVE).
//   ACTIVE  The flag is useless here (OBS holds it at 1), so clients are tracked from CoreMediaIO's own log lines:
//           every process logs "CMIODeviceStartStream (device stream)" and the matching stop. Object IDs differ from
//           process to process, so a log line cannot say which camera it was; instead, any process that started a
//           camera stream just before or while the virtual camera is in use counts as a client. When none of those
//           has a stream left (or its process exited) for a few seconds: VERIFY.
//   VERIFY  Stop the output, wait, then read the flag again. 0: release the webcam (IDLE). 1: a client is still
//           there that the log missed, so start again (ACTIVE) and re-check with a back-off.
// The log only decides when to look; the flag decides what is true, so a wrong guess corrects itself.
//
// Releasing the webcam: macos-avcapture only stops its capture session when its "device" setting is cleared, so the
// plugin clears it and keeps the real device in a backup key on the same source. The backup survives a crash or quit
// while idle, and the plugin puts the device back whenever it turns the camera on or is switched off.

#import <Foundation/Foundation.h>
#import <CoreMediaIO/CMIOHardware.h>

#include <errno.h>
#include <signal.h>
#include <unistd.h>

#include <obs-module.h>
#include <obs-frontend-api.h>
#include <util/platform.h>

OBS_DECLARE_MODULE()

#define TAG "[vcam-camera-gate] "
#define LOG(level, fmt, ...) blog(level, TAG fmt, ##__VA_ARGS__)

static NSString *const kVirtualCameraUID = @"7626645E-4425-469E-9D8B-97E0FA59AC75";  // OBS's mac-camera-extension
static NSString *const kVirtualCameraName = @"OBS Virtual Camera";
static const char *const kBackupKey = "vcam_gate_device";

static const double kGraceSeconds = 3.0;        // a client stopping and restarting (Zoom does this) stays ACTIVE
static const double kSinkSettleSeconds = 0.6;   // after OBS's feed stops, before the flag is trusted
static const double kVerifyTimeoutSeconds = 5.0;
static const double kMaxBackoffSeconds = 120.0;

typedef enum { GATE_OFF, GATE_IDLE, GATE_ACTIVE, GATE_VERIFY } gate_state;

// Everything below is touched on the main queue only (OBS's UI thread).
static gate_state state = GATE_OFF;
static bool enabled = true;
static bool started = false;
static CMIOObjectID vcam = kCMIOObjectUnknown;
static CMIOObjectPropertyListenerBlock flagListener;
static NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *streams;  // pid -> running camera streams
static NSMutableDictionary<NSNumber *, NSNumber *> *lastStart;               // pid -> uptime of its last start
static NSMutableSet<NSNumber *> *attributed;  // pids taken to be virtual camera clients while ACTIVE
static NSTask *logTask;
static dispatch_source_t reaper;
static unsigned long generation;  // bumps on every state change; stale timers check it and do nothing
static double unknownBackoff;      // >0 while a client is present that the log never showed

static const char *state_name(gate_state s)
{
    switch (s) {
        case GATE_OFF:
            return "off";
        case GATE_IDLE:
            return "idle";
        case GATE_ACTIVE:
            return "active";
        case GATE_VERIFY:
            return "verify";
    }
    return "?";
}

static void after(double seconds, dispatch_block_t block)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (seconds * NSEC_PER_SEC)), dispatch_get_main_queue(),
                   block);
}

static void set_state(gate_state s)
{
    if (s != state)
        LOG(LOG_INFO, "%s -> %s", state_name(state), state_name(s));
    state = s;
    generation++;
}

#pragma mark - CoreMediaIO

static NSString *copy_string_property(CMIOObjectID object, CMIOObjectPropertySelector selector)
{
    CMIOObjectPropertyAddress address = {selector, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
    CFStringRef value = NULL;
    UInt32 used = 0;
    if (CMIOObjectGetPropertyData(object, &address, 0, NULL, sizeof(value), &used, &value) != kCMIOHardwareNoError)
        return nil;
    return CFBridgingRelease(value);
}

static CMIOObjectID find_virtual_camera(void)
{
    CMIOObjectPropertyAddress address = {kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal,
                                         kCMIOObjectPropertyElementMain};
    UInt32 size = 0, used = 0;
    if (CMIOObjectGetPropertyDataSize(kCMIOObjectSystemObject, &address, 0, NULL, &size) != kCMIOHardwareNoError)
        return kCMIOObjectUnknown;
    UInt32 count = size / sizeof(CMIOObjectID);
    CMIOObjectID *devices = calloc(count ? count : 1, sizeof(CMIOObjectID));
    CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &address, 0, NULL, size, &used, devices);

    CMIOObjectID found = kCMIOObjectUnknown;
    for (UInt32 i = 0; i < used / sizeof(CMIOObjectID) && found == kCMIOObjectUnknown; i++) {
        if ([copy_string_property(devices[i], kCMIODevicePropertyDeviceUID) isEqualToString:kVirtualCameraUID] ||
            [copy_string_property(devices[i], kCMIOObjectPropertyName) isEqualToString:kVirtualCameraName])
            found = devices[i];
    }
    free(devices);
    return found;
}

static bool virtual_camera_running_somewhere(void)
{
    CMIOObjectPropertyAddress address = {kCMIODevicePropertyDeviceIsRunningSomewhere, kCMIOObjectPropertyScopeGlobal,
                                         kCMIOObjectPropertyElementMain};
    UInt32 value = 0, used = 0;
    if (CMIOObjectGetPropertyData(vcam, &address, 0, NULL, sizeof(value), &used, &value) != kCMIOHardwareNoError)
        return false;
    return value != 0;
}

#pragma mark - Webcam sources

static bool is_capture_source(obs_source_t *source)
{
    const char *id = obs_source_get_unversioned_id(source);
    return id && (strcmp(id, "macos-avcapture") == 0 || strcmp(id, "macos-avcapture-fast") == 0);
}

static bool release_one(void *param, obs_source_t *source)
{
    if (!is_capture_source(source))
        return true;
    obs_data_t *settings = obs_source_get_settings(source);
    const char *device = obs_data_get_string(settings, "device");
    if (device && *device) {
        obs_data_set_string(settings, kBackupKey, device);
        obs_data_t *update = obs_data_create();
        obs_data_set_string(update, "device", "");
        obs_source_update(source, update);
        obs_data_release(update);
        LOG(LOG_INFO, "released webcam of '%s'", obs_source_get_name(source));
    }
    obs_data_release(settings);
    return true;
}

static bool restore_one(void *param, obs_source_t *source)
{
    if (!is_capture_source(source))
        return true;
    obs_data_t *settings = obs_source_get_settings(source);
    const char *backup = obs_data_get_string(settings, kBackupKey);
    if (backup && *backup) {
        obs_data_t *update = obs_data_create();
        obs_data_set_string(update, "device", backup);
        obs_data_erase(settings, kBackupKey);
        obs_source_update(source, update);
        obs_data_release(update);
        LOG(LOG_INFO, "restored webcam of '%s'", obs_source_get_name(source));
    }
    obs_data_release(settings);
    return true;
}

static void release_webcams(void)
{
    obs_enum_sources(release_one, NULL);
}

static void restore_webcams(void)
{
    obs_enum_sources(restore_one, NULL);
}

#pragma mark - State machine

static void begin_verify(void);

static double uptime(void)
{
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
}

static NSUInteger active_client_count(void)
{
    NSUInteger n = 0;
    for (NSNumber *pid in attributed)
        if (streams[pid].count > 0)
            n++;
    return n;
}

static void schedule_departure_check(void)
{
    if (state != GATE_ACTIVE || active_client_count() > 0)
        return;
    double wait = unknownBackoff > 0 ? unknownBackoff : kGraceSeconds;
    unsigned long gen = generation;
    after(wait, ^{
        if (gen == generation && state == GATE_ACTIVE && active_client_count() == 0)
            begin_verify();
    });
}

static void attribute(NSNumber *pid)
{
    if (![attributed containsObject:pid]) {
        [attributed addObject:pid];
        LOG(LOG_INFO, "client: pid %d", pid.intValue);
    }
}

static void activate(const char *why)
{
    LOG(LOG_INFO, "client present (%s): webcam on", why);
    set_state(GATE_ACTIVE);
    // Whoever started a camera stream just now is the likely client; its log line may also still be on its way, in
    // which case handle_stream_event attributes it.
    double now = uptime();
    [lastStart enumerateKeysAndObjectsUsingBlock:^(NSNumber *pid, NSNumber *at, BOOL *stop) {
        if (now - at.doubleValue <= kGraceSeconds && streams[pid].count > 0)
            attribute(pid);
    }];
    restore_webcams();
    if (!obs_frontend_virtualcam_active())
        obs_frontend_start_virtualcam();
    schedule_departure_check();
}

static void go_idle(void)
{
    LOG(LOG_INFO, "no client: webcam off");
    set_state(GATE_IDLE);
    unknownBackoff = 0;
    [attributed removeAllObjects];
    release_webcams();
    if (virtual_camera_running_somewhere())  // a client arrived in between
        activate("flag");
}

static void verify_poll(unsigned long gen, double startedAt, double sinkStoppedAt)
{
    if (gen != generation || state != GATE_VERIFY)
        return;
    double now = uptime();

    if (obs_frontend_virtualcam_active()) {
        if (now - startedAt > kVerifyTimeoutSeconds) {
            LOG(LOG_WARNING, "virtual camera output did not stop; staying on");
            activate("timeout");
            return;
        }
    } else if (sinkStoppedAt == 0) {
        sinkStoppedAt = now;
    } else if (now - sinkStoppedAt >= kSinkSettleSeconds) {
        if (!virtual_camera_running_somewhere()) {
            go_idle();
            return;
        }
        if (active_client_count() == 0) {
            // Someone is streaming, but the log never showed who. Keep running and look again later, backing off so
            // a client we cannot see does not get a placeholder frame every few seconds.
            unknownBackoff = unknownBackoff > 0 ? fmin(unknownBackoff * 2, kMaxBackoffSeconds) : 15.0;
            LOG(LOG_WARNING, "client present but not seen in the log; re-checking in %.0f s", unknownBackoff);
        }
        activate("flag");
        return;
    }
    after(0.1, ^{
        verify_poll(gen, startedAt, sinkStoppedAt);
    });
}

static void begin_verify(void)
{
    set_state(GATE_VERIFY);
    if (obs_frontend_virtualcam_active())
        obs_frontend_stop_virtualcam();
    unsigned long gen = generation;
    double now = uptime();
    after(0.1, ^{
        verify_poll(gen, now, 0);
    });
}

static void clients_changed(void)
{
    if (active_client_count() > 0)
        unknownBackoff = 0;
    else if (state == GATE_ACTIVE)
        schedule_departure_check();
}

#pragma mark - Client tracking from the CoreMediaIO log

static void handle_stream_event(pid_t pid, bool start, CMIOObjectID stream)
{
    if (pid == getpid() || !started)
        return;
    NSNumber *key = @(pid);
    NSMutableSet *running = streams[key];
    if (start) {
        if (!running)
            streams[key] = running = [NSMutableSet set];
        [running addObject:@(stream)];
        lastStart[key] = @(uptime());
        if (state == GATE_ACTIVE || state == GATE_VERIFY)
            attribute(key);
    } else if (running) {
        [running removeObject:@(stream)];
        if (running.count == 0) {
            [streams removeObjectForKey:key];
            if ([attributed containsObject:key])
                LOG(LOG_INFO, "client pid %d stopped its camera", pid);
        }
    }
    clients_changed();
}

static void reap_dead_clients(void)
{
    bool changed = false;
    for (NSNumber *pid in streams.allKeys) {
        if (kill(pid.intValue, 0) != 0 && errno == ESRCH) {
            if ([attributed containsObject:pid]) {
                LOG(LOG_INFO, "client pid %d exited", pid.intValue);
                changed = true;
            }
            [streams removeObjectForKey:pid];
            [attributed removeObject:pid];
        }
    }
    double now = uptime();
    for (NSNumber *pid in lastStart.allKeys)
        if (now - lastStart[pid].doubleValue > 60 && !streams[pid])
            [lastStart removeObjectForKey:pid];
    if (changed)
        clients_changed();
}

static void parse_log_line(NSData *line)
{
    NSDictionary *event = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![event isKindOfClass:[NSDictionary class]])
        return;
    NSString *message = event[@"eventMessage"];
    NSNumber *pid = event[@"processID"];
    if (![message isKindOfClass:[NSString class]] || ![pid isKindOfClass:[NSNumber class]])
        return;

    // Two spellings of the same thing, depending on whether the client used the C API or AVFoundation:
    //   "CMIOHardware.cpp:741:CMIODeviceStartStream (39 40)"           (device, stream)
    //   "CMIO_DAL_CMIOExtension_Stream.mm:3179:Start (streamID 40 39 0)" (stream, device)
    static NSRegularExpression *api, *dal;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        api = [NSRegularExpression regularExpressionWithPattern:@"CMIODevice(Start|Stop)Stream \\((\\d+) (\\d+)\\)"
                                                        options:0
                                                          error:nil];
        dal = [NSRegularExpression regularExpressionWithPattern:@":(Start|Stop) \\(streamID (\\d+) (\\d+)"
                                                        options:0
                                                          error:nil];
    });
    NSRange all = NSMakeRange(0, message.length);
    NSTextCheckingResult *m;
    // Object IDs are per process, so only the stream ID (to pair a start with its stop) is used.
    bool start;
    CMIOObjectID stream;
    if ((m = [api firstMatchInString:message options:0 range:all])) {
        start = [[message substringWithRange:[m rangeAtIndex:1]] isEqualToString:@"Start"];
        stream = (CMIOObjectID) [message substringWithRange:[m rangeAtIndex:3]].integerValue;
    } else if ((m = [dal firstMatchInString:message options:0 range:all])) {
        start = [[message substringWithRange:[m rangeAtIndex:1]] isEqualToString:@"Start"];
        stream = (CMIOObjectID) [message substringWithRange:[m rangeAtIndex:2]].integerValue;
    } else {
        return;
    }
    pid_t p = pid.intValue;
    dispatch_async(dispatch_get_main_queue(), ^{
        handle_stream_event(p, start, stream);
    });
}

static void start_log_watch(void)
{
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/log"];
    task.arguments = @[
        @"stream", @"--style", @"ndjson", @"--level", @"default", @"--predicate",
        (@"subsystem == \"com.apple.cmio\" AND (eventMessage CONTAINS \"(streamID \" OR "
         @"eventMessage CONTAINS \"CMIODeviceStartStream (\" OR eventMessage CONTAINS \"CMIODeviceStopStream (\")")
    ];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    NSMutableData *buffer = [NSMutableData data];
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) {
            handle.readabilityHandler = nil;
            return;
        }
        [buffer appendData:data];
        for (;;) {
            NSRange newline = [buffer rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0
                                            range:NSMakeRange(0, buffer.length)];
            if (newline.location == NSNotFound)
                break;
            parse_log_line([buffer subdataWithRange:NSMakeRange(0, newline.location)]);
            [buffer replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
        }
    };
    task.terminationHandler = ^(NSTask *ended) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (logTask != ended || !started)
                return;
            LOG(LOG_WARNING, "log stream exited (%d); restarting", ended.terminationStatus);
            logTask = nil;
            after(2.0, ^{
                if (started && !logTask)
                    start_log_watch();
            });
        });
    };

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        LOG(LOG_ERROR, "could not run /usr/bin/log: %s", error.localizedDescription.UTF8String);
        return;
    }
    logTask = task;
}

#pragma mark - Enable / disable

static void save_config(void)
{
    char *path = obs_module_config_path("config.json");
    if (!path)
        return;
    char *dir = obs_module_config_path("");
    os_mkdirs(dir);
    bfree(dir);
    obs_data_t *data = obs_data_create();
    obs_data_set_bool(data, "enabled", enabled);
    obs_data_save_json_safe(data, path, "tmp", "bak");
    obs_data_release(data);
    bfree(path);
}

static void load_config(void)
{
    char *path = obs_module_config_path("config.json");
    obs_data_t *data = path ? obs_data_create_from_json_file_safe(path, "bak") : NULL;
    if (data) {
        obs_data_set_default_bool(data, "enabled", true);
        enabled = obs_data_get_bool(data, "enabled");
        obs_data_release(data);
    }
    bfree(path);
}

static void apply_enabled(void)
{
    if (!started)
        return;
    if (enabled) {
        LOG(LOG_INFO, "on: the webcam opens only while an app uses the OBS Virtual Camera");
        begin_verify();
    } else {
        LOG(LOG_INFO, "off: OBS controls the webcam and the virtual camera as usual");
        set_state(GATE_OFF);
        [attributed removeAllObjects];
        restore_webcams();
    }
}

static void toggle_menu(void *param)
{
    enabled = !enabled;
    save_config();
    apply_enabled();
}

static void start_gate(void)
{
    vcam = find_virtual_camera();
    if (vcam == kCMIOObjectUnknown) {
        LOG(LOG_WARNING, "OBS Virtual Camera device not found; webcam left alone. Start the virtual camera once so "
                         "macOS installs it, then restart OBS.");
        restore_webcams();
        return;
    }
    started = true;
    streams = [NSMutableDictionary dictionary];
    lastStart = [NSMutableDictionary dictionary];
    attributed = [NSMutableSet set];

    CMIOObjectPropertyAddress address = {kCMIODevicePropertyDeviceIsRunningSomewhere, kCMIOObjectPropertyScopeGlobal,
                                         kCMIOObjectPropertyElementMain};
    flagListener = ^(UInt32 count, const CMIOObjectPropertyAddress *addresses) {
        if (state == GATE_IDLE && virtual_camera_running_somewhere())
            activate("flag");
    };
    CMIOObjectAddPropertyListenerBlock(vcam, &address, dispatch_get_main_queue(), flagListener);

    start_log_watch();

    reaper = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(reaper, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC,
                              NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(reaper, ^{
        reap_dead_clients();
    });
    dispatch_resume(reaper);

    if (enabled) {
        apply_enabled();
    } else {
        set_state(GATE_OFF);
        restore_webcams();
    }
}

static void stop_gate(void)
{
    if (!started)
        return;
    started = false;
    generation++;
    if (flagListener) {
        CMIOObjectPropertyAddress address = {kCMIODevicePropertyDeviceIsRunningSomewhere,
                                             kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
        CMIOObjectRemovePropertyListenerBlock(vcam, &address, dispatch_get_main_queue(), flagListener);
        flagListener = nil;
    }
    if (reaper) {
        dispatch_source_cancel(reaper);
        reaper = nil;
    }
    NSTask *task = logTask;
    logTask = nil;
    if (task.running)
        [task terminate];
    // Webcams stay released on purpose: restoring them here would flash the camera light while OBS quits. The backup
    // key brings the device back the next time the plugin turns the camera on, or when the gate is switched off.
}

static void frontend_event(enum obs_frontend_event event, void *param)
{
    switch (event) {
        case OBS_FRONTEND_EVENT_FINISHED_LOADING:
            start_gate();
            break;
        case OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED:
            // Also fires during startup, before FINISHED_LOADING: leave released webcams alone until the gate runs.
            if (!started)
                break;
            if (state == GATE_IDLE)
                release_webcams();
            else if (state == GATE_OFF || state == GATE_ACTIVE)
                restore_webcams();
            break;
        case OBS_FRONTEND_EVENT_VIRTUALCAM_STARTED:
            // Started by hand while idle: show the webcam; the departure check stops it again if nobody watches.
            if (state == GATE_IDLE)
                activate("virtual camera started by hand");
            break;
        case OBS_FRONTEND_EVENT_VIRTUALCAM_STOPPED:
            // Stopped by hand while a client may still be watching: re-check rather than leave the client stuck.
            if (state == GATE_ACTIVE)
                begin_verify();
            break;
        case OBS_FRONTEND_EVENT_EXIT:
            stop_gate();
            break;
        default:
            break;
    }
}

bool obs_module_load(void)
{
    load_config();
    obs_frontend_add_event_callback(frontend_event, NULL);
    obs_frontend_add_tools_menu_item("Toggle Webcam Only While Virtual Camera Is Used", toggle_menu, NULL);
    LOG(LOG_INFO, "loaded (%s)", enabled ? "on" : "off");
    return true;
}

void obs_module_unload(void)
{
    stop_gate();
}

const char *obs_module_name(void)
{
    return "Virtual Camera Webcam Gate";
}

const char *obs_module_description(void)
{
    return "Opens the webcam only while an app is using the OBS Virtual Camera.";
}
