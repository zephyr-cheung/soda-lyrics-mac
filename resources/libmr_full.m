#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>

typedef void (^InfoBlock)(NSDictionary *);
typedef void (*GetInfoFn)(dispatch_queue_t, InfoBlock);

static void pump_quick(double seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([[NSDate date] timeIntervalSinceDate:deadline] < 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
}

static NSDictionary *fetch_info(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    GetInfoFn f = h ? (GetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo") : NULL;
    if (!f) return nil;
    __block BOOL got = NO;
    __block NSDictionary *info = nil;
    dispatch_queue_t q = dispatch_queue_create("q", DISPATCH_QUEUE_SERIAL);
    f(q, ^(NSDictionary *d){ got = YES; info = d; });
    pump_quick(0.8);
    return got ? info : nil;
}

static void write_json(NSDictionary *info, char *buf, size_t cap) {
    double dur = [info[@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
    double rate = [info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
    NSDate *cpd = info[@"kMRMediaRemoteNowPlayingInfoCurrentPlaybackDate"];
    NSDate *nowD = [NSDate date];
    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
    double elapsed = cpd ? [nowD timeIntervalSinceDate:cpd] : -1;
    snprintf(buf, cap,
             "{\"title\":\"%s\",\"artist\":\"%s\",\"dur\":%.3f,\"rate\":%.3f,\"elC\":%.3f}",
             title ? [title UTF8String] : "",
             artist ? [artist UTF8String] : "",
             dur, rate, elapsed);
}

// python 代理用：printf 到 stdout
__attribute__((visibility("default")))
void mr_get_full_json(void) {
    @autoreleasepool {
        NSDictionary *info = fetch_info();
        if (!info) { printf("null\n"); return; }
        char buf[2048];
        write_json(info, buf, sizeof buf);
        printf("%s\n", buf);
    }
}

// 备用：返回 static 内存（供未来 Rust FFI 直接调）
__attribute__((visibility("default")))
const char *mr_get_json_str(void) {
    static char buf[2048];
    @autoreleasepool {
        NSDictionary *info = fetch_info();
        if (!info) { snprintf(buf, sizeof buf, "null"); return buf; }
        write_json(info, buf, sizeof buf);
        return buf;
    }
}