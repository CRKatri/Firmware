#import "DeviceInfo.h"

@implementation DeviceInfo {
    struct utsname _systemInfo;
    NSString *_model;
}

+ (instancetype)sharedDevice {
    static DeviceInfo *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[DeviceInfo alloc] init];
        [sharedInstance initCpuArchitecture];
        [sharedInstance initCpuSubArchitecture];
        uname(&(sharedInstance->_systemInfo));
        [sharedInstance initModel];
    });
    return sharedInstance;
}

- (void)exitWithError:(NSError *)error andMessage:(NSString *)message {
    NSLog(@"[Firmware] %@", message);
    if (error) {
        NSLog(@"[Firmware] Error: %@", error);
    }
    exit(1);
}

- (void)initCpuArchitecture {
    cpu_type_t type;
    size_t size = sizeof(type);

    NXArchInfo const *ai;
    char *cpu = NULL;
    if (sysctlbyname("hw.cputype", &type, &size, NULL, 0) == 0 && (ai = NXGetArchInfoFromCpuType(type, CPU_SUBTYPE_MULTIPLE)) != NULL) {
        cpu = (char *)ai->name;
    } else {
        [self exitWithError:nil andMessage:@"Error getting cpu architecture"];
    }

    self->_cpuArchitecture = [NSString stringWithCString:cpu encoding:NSUTF8StringEncoding];

    NXFreeArchInfo(ai);
}

- (void)initCpuSubArchitecture {
    cpu_subtype_t subtype;
    size_t size = sizeof(subtype);

    char *cpu = NULL;
    if (sysctlbyname("hw.cpusubtype", &subtype, &size, NULL, 0) == 0) {
        if (subtype == CPU_SUBTYPE_ARM_V6) {
            cpu = "armv6";
        } else if (subtype == CPU_SUBTYPE_ARM_V7) {
            cpu = "armv7";
        } else if (subtype == CPU_SUBTYPE_ARM_V7S) {
            cpu = "armv7s";
        } else if (subtype == CPU_SUBTYPE_ARM_V7K) {
            cpu = "armv7k";
        } else if (subtype == CPU_SUBTYPE_ARM64_ALL) {
            cpu = "arm64";
        } else if (subtype == CPU_SUBTYPE_ARM64_V8) {
            cpu = "arm64v8";
        } else if (subtype == CPU_SUBTYPE_ARM64E) {
            cpu = "arm64e";
        } else if (subtype == CPU_SUBTYPE_X86_64_ALL) {
            cpu = "x86_64";
        } else {
            [self exitWithError:nil andMessage:@"Unknown cpu sub-architecture"];
        }
    } else {
        [self exitWithError:nil andMessage:@"Error getting cpu sub-architecture"];
    }

    self->_cpuSubArchitecture = [NSString stringWithCString:cpu encoding:NSUTF8StringEncoding];
}

- (void)initModel {
#if (TARGET_OS_IPHONE)
        self->_model = [NSString stringWithCString:self->_systemInfo.machine encoding:NSUTF8StringEncoding];
#else
        size_t size;
        char *model;

        sysctlbyname("hw.model", NULL, &size, NULL, 0);
        model = malloc(size);
        sysctlbyname("hw.model", model, &size, NULL, 0);

        self->_model = [NSString stringWithCString:model encoding:NSUTF8StringEncoding];
        free(model);
#endif
}

- (NSRegularExpression *)regexWithPattern:(NSString *)pattern {
    NSError *error;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&error];

    if (!regex) {
        [self exitWithError:error andMessage:[NSString stringWithFormat:@"Error parsing regex: '%@'", pattern]];
    }

    return regex;
}

- (NSString *)getOperatingSystemVersion {
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    NSString *versionString = [NSString stringWithFormat:@"%d.%d.%d", (int)version.majorVersion, (int)version.minorVersion, (int)version.patchVersion];
    return versionString;
}

- (NSString *)getModelName {
    NSRegularExpression *nameRegex = [self regexWithPattern:@"([A-Za-z]+)"];

    NSRange match = [nameRegex firstMatchInString:self->_model options:0 range:NSMakeRange(0, [self->_model length])].range;

    return [[self->_model substringWithRange:match] lowercaseString];
}

- (NSString *)getModelVersion {
    NSRegularExpression *versionRegex = [self regexWithPattern:@"([0-9]+,[0-9]+)"];

    NSRange match = [versionRegex firstMatchInString:self->_model options:0 range:NSMakeRange(0, [self->_model length])].range;

    return [[self->_model substringWithRange:match] stringByReplacingOccurrencesOfString:@"," withString:@"."];
}

- (NSString *)getDebianArchitecture {
    return @"all";
}

- (NSString *)getOperatingSystem {
#if (TARGET_OS_IOS)
    return @"iphoneos";
#elif (TARGET_OS_TV)
    return @"appletvos";
#elif (TARGET_OS_WATCH)
    return @"watchos";
#elif (TARGET_OS_OSX) 
    return @"macos";
#else
    return @"unknown";
#endif
}

- (NSString *)getDPKGDataDirectory {
    // TODO: This (and a lotta other parts of this code) should detect install prefix.
    return [NSString stringWithFormat:@"/%@/var/lib/dpkg", PREFIX];
}

- (NSDictionary *)getCapabilities {
    NSTask *task = [[NSTask alloc] init];
    
    [task setLaunchPath:[NSString stringWithFormat:@"/%@/%@/bin/gssc", PREFIX, EXECPREFIX]];

    NSPipe *outPipe = [NSPipe pipe];
    [task setStandardOutput:outPipe];

    [task launch];
    [task waitUntilExit];

    NSData *gsscData = [[outPipe fileHandleForReading] readDataToEndOfFile];

    NSError *error;
    NSDictionary *unfilteredCapabilities = [NSPropertyListSerialization propertyListWithData:gsscData options:NSPropertyListMutableContainersAndLeaves format:nil error:&error];

    if (!unfilteredCapabilities) {
        [self exitWithError:error andMessage:@"Error parsing device capabilites from GSSC"];
    }

    NSRegularExpression *numberRegex = [self regexWithPattern:@"^[0-9]+$"];
    NSRegularExpression *uppercaseRegex = [self regexWithPattern:@"([A-Z])"];

    NSMutableDictionary *capabilities = [[NSMutableDictionary alloc] init];

    for (NSString *name in unfilteredCapabilities) {
        id value = [unfilteredCapabilities valueForKey:name];

        if ([value isKindOfClass:[NSString class]]
            && ![(NSString *)value isEqual:@"0"]
            && [numberRegex firstMatchInString:value options:0 range:NSMakeRange(0, [value length])]) {

            NSString *modifiedName = [[uppercaseRegex stringByReplacingMatchesInString:name
                                                                              options:0
                                                                                range:NSMakeRange(0, [name length])
                                                                         withTemplate:@"-$1"]
                                     lowercaseString];

            if ([modifiedName hasPrefix:@"-"]) {
                [capabilities setObject:value forKey:[modifiedName substringFromIndex:1]];
            } else {
                [capabilities setObject:value forKey:modifiedName];
            }
        }
    }
    
    return (NSDictionary *)capabilities;
}

- (NSString *)getCoreFoundationVersion {
    return [NSString stringWithFormat:@"%.2f", kCFCoreFoundationVersionNumber];
}

- (NSString *)getOperatingSystemType {
    return [[NSString stringWithCString:self->_systemInfo.sysname encoding:NSUTF8StringEncoding] lowercaseString];
}

- (NSString *)getOperatingSystemRelease {
    return [NSString stringWithCString:self->_systemInfo.release encoding:NSUTF8StringEncoding];
}

@end
