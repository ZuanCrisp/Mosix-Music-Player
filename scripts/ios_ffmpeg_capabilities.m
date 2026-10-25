#import <Foundation/Foundation.h>
#import <ffmpegkit/FFmpegKit.h>
#import <ffmpegkit/FFmpegKitConfig.h>
#import <ffmpegkit/ReturnCode.h>

// Standalone simulator probe for the shipped audio frameworks. Pass a writable
// output directory, android/app/src/androidTest/assets, and optionally a remote
// motion fixture URL. The audio package requires the app's Dart TLS proxy for
// HTTPS inputs; pass its HTTP loopback URL to verify that application route.
static BOOL execute(NSArray<NSString *> *arguments) {
    NSArray *command = [@[@"-v", @"error", @"-y"] arrayByAddingObjectsFromArray:arguments];
    FFmpegSession *session = [FFmpegKit executeWithArguments:command];
    if (![ReturnCode isSuccess:[session getReturnCode]]) {
        fprintf(stderr, "FFmpeg failed: %s\n%s\n", [[command description] UTF8String],
                [[session getAllLogsAsString] UTF8String]);
        return NO;
    }
    return YES;
}

static BOOL nonempty(NSString *path) {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return [attributes[NSFileSize] unsignedLongLongValue] > 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *hlsMode = argc == 5 ? [NSString stringWithUTF8String:argv[4]] : @"";
        if (argc < 3 || argc > 5 || (argc == 5 && ![@[@"--allow-hls-extensions", @"--allow-hls-segments", @"--relax-hls-extensions", @"--disable-hls-extension-check"] containsObject:hlsMode])) {
            fprintf(stderr, "Usage: ios_ffmpeg_capabilities OUTPUT_DIR MOTION_FIXTURE_DIR [REMOTE_FIXTURE_URL [--allow-hls-extensions|--allow-hls-segments|--relax-hls-extensions|--disable-hls-extension-check]]\n");
            return 2;
        }
        [FFmpegKitConfig setLogRedirectionStrategy:LogRedirectionStrategyNeverPrintLogs];
        FFmpegSession *protocols = [FFmpegKit executeWithArguments:@[@"-hide_banner", @"-protocols"]];
        NSString *protocolList = [protocols getAllLogsAsString];
        printf("FFmpeg protocols:\n%s\n", [protocolList UTF8String]);
        BOOL supportsHTTPS = NO;
        BOOL supportsHTTP = NO;
        for (NSString *line in [protocolList componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *protocol = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([protocol isEqualToString:@"http"]) supportsHTTP = YES;
            if ([protocol isEqualToString:@"https"]) {
                supportsHTTPS = YES;
            }
        }
        if (!supportsHTTP) {
            fprintf(stderr, "FAIL HTTP protocol unavailable: app TLS proxy cannot work\n");
            return 1;
        }
        printf("PASS HTTP protocol; native HTTPS %s\n", supportsHTTPS ? "available" : "unavailable (requires app TLS proxy)");
        FFmpegSession *hlsOptions = [FFmpegKit executeWithArguments:@[@"-hide_banner", @"-h", @"demuxer=hls"]];
        printf("HLS demuxer options:\n%s\n", [[hlsOptions getAllLogsAsString] UTF8String]);
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        NSString *fixtures = [NSString stringWithUTF8String:argv[2]];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:root
                withIntermediateDirectories:YES attributes:nil error:nil]) return 2;
        for (NSArray<NSString *> *format in @[
            @[@"flac", @"flac"], @[@"m4a", @"alac"], @[@"wav", @"pcm_s24le"],
            @[@"aiff", @"pcm_s24be"], @[@"mp3", @"libmp3lame"], @[@"opus", @"libopus"], @[@"aac", @"aac"]
        ]) {
            NSString *output = [root stringByAppendingPathComponent:[@"track." stringByAppendingString:format[0]]];
            if (!execute(@[@"-f", @"lavfi", @"-i", @"sine=frequency=997:sample_rate=48000",
                    @"-t", @"0.5", @"-c:a", format[1], output]) || !nonempty(output)) return 1;
            if (!execute(@[@"-i", output, @"-map", @"0:a:0", @"-f", @"null", @"-"])) return 1;
            printf("PASS encode/decode %s\n", [format[1] UTF8String]);
        }
        NSString *audio = [root stringByAppendingPathComponent:@"track.flac"];
        NSString *stats = [root stringByAppendingPathComponent:@"analysis.txt"];
        NSString *filter = [NSString stringWithFormat:
            @"astats=metadata=1:reset=0,ebur128=peak=true:metadata=1,ametadata=print:file='%@'", stats];
        if (!execute(@[@"-i", audio, @"-af", filter, @"-f", @"null", @"-"])) return 1;
        NSString *metadata = [NSString stringWithContentsOfFile:stats encoding:NSUTF8StringEncoding error:nil];
        if (![metadata containsString:@"lavfi.astats"] || ![metadata containsString:@"lavfi.r128.I"]) return 1;
        printf("PASS astats/ebur128/ametadata\n");
        NSString *spectrum = [root stringByAppendingPathComponent:@"spectrum.png"];
        if (!execute(@[@"-i", audio, @"-lavfi",
                @"showspectrumpic=s=64x64:legend=0:mode=combined:color=channel:scale=log:fscale=lin:win_func=hann",
                @"-frames:v", @"1", spectrum]) || !nonempty(spectrum)) return 1;
        NSString *cover = [root stringByAppendingPathComponent:@"cover.jpg"];
        if (!execute(@[@"-i", spectrum, @"-vf", @"scale=32:32", @"-frames:v", @"1", cover]) || !nonempty(cover)) return 1;
        printf("PASS spectrum PNG/JPEG scale\n");
        for (NSString *codec in @[@"h264", @"hevc"]) {
            NSString *input = [fixtures stringByAppendingPathComponent:
                [NSString stringWithFormat:@"motion-probe-%@.mp4", codec]];
            if (!execute(@[@"-xerror", @"-err_detect", @"explode", @"-i", input, @"-map", @"0:v:0",
                    @"-an", @"-sn", @"-dn", @"-f", @"null", @"-"])) return 1;
            NSString *output = [root stringByAppendingPathComponent:[codec stringByAppendingString:@"-remux.mp4"]];
            if (!execute(@[@"-i", input, @"-map", @"0:v:0", @"-an", @"-c:v", @"copy",
                    @"-movflags", @"+faststart", output]) || !nonempty(output)) return 1;
            printf("PASS motion decode/remux %s\n", [codec UTF8String]);
        }
        if (argc >= 4) {
            NSString *remote = [NSString stringWithUTF8String:argv[3]];
            NSMutableArray<NSString *> *input = [NSMutableArray arrayWithArray:@[@"-rw_timeout", @"5000000"]];
            if (argc == 5 && ![hlsMode isEqualToString:@"--disable-hls-extension-check"]) {
                [input addObjectsFromArray:@[@"-allowed_extensions", @"ALL"]];
            }
            if ([@[@"--allow-hls-segments", @"--relax-hls-extensions"] containsObject:hlsMode]) {
                [input addObjectsFromArray:@[@"-allowed_segment_extensions", @"ALL"]];
            }
            if ([@[@"--relax-hls-extensions", @"--disable-hls-extension-check"] containsObject:hlsMode]) {
                [input addObjectsFromArray:@[@"-extension_picky", @"0"]];
            }
            [input addObjectsFromArray:@[@"-i", remote]];
            if (!execute([input arrayByAddingObjectsFromArray:@[@"-map", @"0:v:0",
                    @"-an", @"-f", @"null", @"-"]])) return 1;
            NSString *remuxed = [root stringByAppendingPathComponent:@"remote-remux.mp4"];
            if (!execute([input arrayByAddingObjectsFromArray:@[@"-map", @"0:v:0", @"-an", @"-c:v", @"copy",
                    @"-movflags", @"+faststart", remuxed]]) || !nonempty(remuxed)) return 1;
            if (!execute(@[@"-xerror", @"-err_detect", @"explode", @"-i", remuxed, @"-map", @"0:v:0",
                    @"-an", @"-f", @"null", @"-"])) return 1;
            printf("PASS remote motion input %s\n", [remote UTF8String]);
            printf("PASS remote stream-copy remux/decode\n");
        }
        printf("PASS iOS audio FFmpeg capabilities\n");
        return 0;
    }
}
