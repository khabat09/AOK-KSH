#import "AudioCapture.h"
#import "AudioInput.h"
#import <AVFoundation/AVFoundation.h>

#include "kernel/errno.h"
#include "util/sync.h"

// The same figures the playback device uses, so the two directions of a later
// /dev/dsp agree with each other. The ring is ~2.7 s of 48 kHz mono S16LE.
static const size_t kAudioCaptureRingCapacity = 256 * 1024;
static const size_t kAudioCaptureFragmentSize = 4096;
static const int kAudioCaptureDefaultSampleRate = 48000;
static const int kAudioCaptureDefaultChannels = 1;
static const int kAudioCaptureMinSampleRate = 8000;
static const int kAudioCaptureMaxSampleRate = 48000;

typedef NS_ENUM(int, AudioCapturePermission) {
    AudioCapturePermissionUndetermined = 0,
    AudioCapturePermissionGranted,
    AudioCapturePermissionDenied,
};

@interface AudioCapture () <AudioInputSink> {
    lock_t _lock;
    cond_t _dataAvailable;
    cond_t _stateChanged;

    uint8_t *_buffer;
    size_t _capacity;
    size_t _readOffset;
    size_t _writeOffset;
    size_t _used;
    uint64_t _overrunCount;
    uint64_t _droppedBytes;

    int _sampleRate;
    int _channels;
    int _sampleFormat;

    int _readers;
    BOOL _started;
    BOOL _starting;

    // Permission is requested once per process and every caller that arrives
    // while the prompt is up waits for the same answer.
    lock_t _permissionLock;
    cond_t _permissionChanged;
    BOOL _permissionRequested;
    BOOL _permissionAnswered;
    BOOL _permissionGranted;

    AudioInput *_input;

    // The session state this core found, so the last release can put it back.
    NSString *_savedCategory;
    NSString *_savedMode;
    AVAudioSessionCategoryOptions _savedOptions;

    NSHashTable *_listeners;
}

- (int)startCapture;
- (BOOL)configureSession;
- (void)restoreSession;
- (AudioCapturePermission)recordPermissionStatus;
- (int)ensureRecordPermission;
- (void)requestRecordPermission;
- (size_t)spaceLocked;
- (size_t)copyIntoRingLocked:(const uint8_t *)src size:(size_t)size;
- (void)dropOldestLocked:(size_t)size;
- (size_t)consumeLocked:(void *)dst size:(size_t)size;
- (void)notifyListeners;

@end

@implementation AudioCapture

+ (AudioCapture *)sharedCapture {
    static AudioCapture *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [AudioCapture new];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        lock_init(&_lock, "audio_capture\0");
        cond_init(&_dataAvailable);
        cond_init(&_stateChanged);
        lock_init(&_permissionLock, "audio_capture_perm\0");
        cond_init(&_permissionChanged);
        _capacity = kAudioCaptureRingCapacity;
        _buffer = calloc(1, _capacity);
        if (_buffer == NULL)
            return nil;
        _sampleRate = kAudioCaptureDefaultSampleRate;
        _channels = kAudioCaptureDefaultChannels;
        _sampleFormat = AudioCaptureSampleFormatS16LE;
        _listeners = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (void)dealloc {
    free(_buffer);
    cond_destroy(&_dataAvailable);
    cond_destroy(&_stateChanged);
    cond_destroy(&_permissionChanged);
}

#pragma mark - Parameters

- (int)setSampleRate:(int)sampleRate {
    if (sampleRate < kAudioCaptureMinSampleRate || sampleRate > kAudioCaptureMaxSampleRate)
        return _EINVAL;
    lock(&_lock, 0);
    if (_started || _starting) {
        unlock(&_lock);
        return _EBUSY;
    }
    _sampleRate = sampleRate;
    unlock(&_lock);
    return 0;
}

- (int)setChannels:(int)channels {
    if (channels != 1 && channels != 2)
        return _EINVAL;
    lock(&_lock, 0);
    if (_started || _starting) {
        unlock(&_lock);
        return _EBUSY;
    }
    _channels = channels;
    unlock(&_lock);
    return 0;
}

- (int)setSampleFormat:(int)format {
    if (format != AudioCaptureSampleFormatS16LE)
        return _EINVAL;
    lock(&_lock, 0);
    if (_started || _starting) {
        unlock(&_lock);
        return _EBUSY;
    }
    _sampleFormat = format;
    unlock(&_lock);
    return 0;
}

- (int)sampleRate {
    lock(&_lock, 0);
    int value = _sampleRate;
    unlock(&_lock);
    return value;
}

- (int)channels {
    lock(&_lock, 0);
    int value = _channels;
    unlock(&_lock);
    return value;
}

- (int)sampleFormat {
    lock(&_lock, 0);
    int value = _sampleFormat;
    unlock(&_lock);
    return value;
}

#pragma mark - Reference counting

- (int)acquire {
    for (;;) {
        lock(&_lock, 0);
        if (_starting) {
            int err = wait_for(&_stateChanged, &_lock, NULL);
            unlock(&_lock);
            if (err < 0)
                return err;
            continue;
        }
        if (_started) {
            _readers++;
            unlock(&_lock);
            return 0;
        }
        // Nobody is reading: this opener starts the capture. An earlier opener
        // that failed has already left (_readers is back to 0), and a failure
        // is not remembered -- the audio route or the permission may since have
        // changed -- so this attempt is fresh.
        _readers = 1;
        _starting = YES;
        unlock(&_lock);

        int err = [self startCapture];

        lock(&_lock, 0);
        _starting = NO;
        if (err < 0)
            _readers = 0;
        notify(&_stateChanged);
        unlock(&_lock);
        return err;
    }
}

- (void)releaseCapture {
    AudioInput *input = nil;
    lock(&_lock, 0);
    if (_readers == 0) {
        unlock(&_lock);
        return;
    }
    _readers--;
    if (_readers == 0) {
        input = _input;
        _input = nil;
        _started = NO;
    }
    // Wake any reader parked in readIntoBuffer: it re-checks _started and gives
    // up with _EIO rather than waiting for data that will not come.
    notify(&_dataAvailable);
    notify(&_stateChanged);
    unlock(&_lock);

    if (input != nil) {
        [input stop];
        [self restoreSession];
        lock(&_lock, 0);
        _readOffset = 0;
        _writeOffset = 0;
        _used = 0;
        _overrunCount = 0;
        _droppedBytes = 0;
        unlock(&_lock);
    }
}

- (int)readerCount {
    lock(&_lock, 0);
    int count = _readers;
    unlock(&_lock);
    return count;
}

#pragma mark - Starting and stopping

- (int)startCapture {
    int err = [self ensureRecordPermission];
    if (err < 0)
        return err;

    if (![self configureSession])
        return _EIO;

    AudioInput *input = [[AudioInput alloc] initWithSampleRate:_sampleRate
                                                      channels:_channels
                                                          sink:self];

    // Marked started before the queue runs: the first buffers arrive on the
    // audio thread within milliseconds, and a producer that finds the core not
    // started would discard them as stale.
    lock(&_lock, 0);
    _readOffset = 0;
    _writeOffset = 0;
    _used = 0;
    _overrunCount = 0;
    _droppedBytes = 0;
    _input = input;
    _started = YES;
    unlock(&_lock);

    if (![input start]) {
        lock(&_lock, 0);
        _started = NO;
        _input = nil;
        unlock(&_lock);
        [self restoreSession];
        return _EIO;
    }
    return 0;
}

// Recording needs its own category, and the category is per process -- the
// player engine sets Playback for the whole app. PlayAndRecord with
// MixWithOthers and DefaultToSpeaker is the least disruptive choice: playback
// from the engine or from /dev/dsp keeps working, and capture is not routed to
// the receiver. The category found at start is put back on the last close.
- (BOOL)configureSession {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    if (_savedCategory == nil) {
        _savedCategory = session.category;
        _savedMode = session.mode;
        _savedOptions = session.categoryOptions;
    }

    NSError *error = nil;
    BOOL ok = [session setCategory:AVAudioSessionCategoryPlayAndRecord
                              mode:AVAudioSessionModeDefault
                           options:AVAudioSessionCategoryOptionMixWithOthers |
                                   AVAudioSessionCategoryOptionDefaultToSpeaker
                             error:&error];
    if (!ok) {
        NSLog(@"AudioCapture: setCategory(PlayAndRecord) failed: %@", error);
        return NO;
    }
    if (![session setActive:YES error:&error]) {
        NSLog(@"AudioCapture: setActive failed: %@", error);
        return NO;
    }
    return YES;
}

- (void)restoreSession {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSString *category = _savedCategory;
    NSString *mode = _savedMode;
    AVAudioSessionCategoryOptions options = _savedOptions;
    _savedCategory = nil;
    _savedMode = nil;
    _savedOptions = 0;
    if (category == nil)
        return;

    NSError *error = nil;
    if (![session setCategory:category mode:mode ?: AVAudioSessionModeDefault options:options error:&error])
        NSLog(@"AudioCapture: restoring category %@ failed: %@", category, error);
    // Deliberately not setActive:NO. The player engine shares this session and
    // deactivating it would stop whatever it is playing.
}

#pragma mark - Permission

- (AudioCapturePermission)recordPermissionStatus {
    if (@available(iOS 17.0, *)) {
        switch (AVAudioApplication.sharedInstance.recordPermission) {
            case AVAudioApplicationRecordPermissionGranted:
                return AudioCapturePermissionGranted;
            case AVAudioApplicationRecordPermissionDenied:
                return AudioCapturePermissionDenied;
            case AVAudioApplicationRecordPermissionUndetermined:
                return AudioCapturePermissionUndetermined;
        }
        return AudioCapturePermissionUndetermined;
    }
    switch (AVAudioSession.sharedInstance.recordPermission) {
        case AVAudioSessionRecordPermissionGranted:
            return AudioCapturePermissionGranted;
        case AVAudioSessionRecordPermissionDenied:
            return AudioCapturePermissionDenied;
        case AVAudioSessionRecordPermissionUndetermined:
            return AudioCapturePermissionUndetermined;
    }
    return AudioCapturePermissionUndetermined;
}

// Blocks until the app has an answer, so a guest read that opened the device
// sees EACCES rather than silence. If nothing can present the prompt the caller
// waits -- this is the same bargain every iOS permission prompt makes.
- (int)ensureRecordPermission {
    AudioCapturePermission status = [self recordPermissionStatus];
    if (status == AudioCapturePermissionGranted)
        return 0;
    if (status == AudioCapturePermissionDenied)
        return _EACCES;

    lock(&_permissionLock, 0);
    if (!_permissionRequested) {
        _permissionRequested = YES;
        unlock(&_permissionLock);
        [self requestRecordPermission];
        lock(&_permissionLock, 0);
    }
    while (!_permissionAnswered) {
        int err = wait_for(&_permissionChanged, &_permissionLock, NULL);
        if (err < 0) {
            unlock(&_permissionLock);
            return err;
        }
    }
    BOOL granted = _permissionGranted;
    unlock(&_permissionLock);
    return granted ? 0 : _EACCES;
}

- (void)requestRecordPermission {
    void (^response)(BOOL) = ^(BOOL granted) {
        lock(&self->_permissionLock, 0);
        self->_permissionAnswered = YES;
        self->_permissionGranted = granted;
        notify(&self->_permissionChanged);
        unlock(&self->_permissionLock);
    };
    // The prompt is UI, so ask on the main queue even when the open came from a
    // guest thread (the queue here is our own serial work, not the caller's).
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 17.0, *))
            [AVAudioApplication requestRecordPermissionWithCompletionHandler:response];
        else
            [AVAudioSession.sharedInstance requestRecordPermission:response];
    });
}

#pragma mark - Reading

- (ssize_t)readIntoBuffer:(void *)buffer size:(size_t)size nonBlocking:(BOOL)nonBlocking {
    if (size == 0)
        return 0;

    lock(&_lock, 0);
    for (;;) {
        if (_used != 0) {
            size_t copied = [self consumeLocked:buffer size:size];
            unlock(&_lock);
            return (ssize_t) copied;
        }
        if (!_started) {
            unlock(&_lock);
            return _EIO;
        }
        if (nonBlocking) {
            unlock(&_lock);
            return _EAGAIN;
        }
        int err = wait_for(&_dataAvailable, &_lock, NULL);
        if (err < 0) {
            unlock(&_lock);
            return err;
        }
    }
}

- (size_t)bytesAvailable {
    lock(&_lock, 0);
    size_t available = _used;
    unlock(&_lock);
    return available;
}

- (size_t)fragmentSize {
    return kAudioCaptureFragmentSize;
}

- (uint64_t)overrunCount {
    lock(&_lock, 0);
    uint64_t count = _overrunCount;
    unlock(&_lock);
    return count;
}

- (uint64_t)droppedBytes {
    lock(&_lock, 0);
    uint64_t count = _droppedBytes;
    unlock(&_lock);
    return count;
}

#pragma mark - Ring buffer

- (size_t)spaceLocked {
    return _capacity - _used;
}

- (size_t)copyIntoRingLocked:(const uint8_t *)src size:(size_t)size {
    if (size == 0)
        return 0;

    size_t first = MIN(size, _capacity - _writeOffset);
    memcpy(_buffer + _writeOffset, src, first);
    _writeOffset = (_writeOffset + first) % _capacity;
    size_t remaining = size - first;
    if (remaining != 0) {
        memcpy(_buffer + _writeOffset, src + first, remaining);
        _writeOffset = (_writeOffset + remaining) % _capacity;
    }
    _used += size;
    return size;
}

- (void)dropOldestLocked:(size_t)size {
    if (size > _used)
        size = _used;
    _readOffset = (_readOffset + size) % _capacity;
    _used -= size;
    _droppedBytes += size;
}

- (size_t)consumeLocked:(void *)dst size:(size_t)size {
    if (size > _used)
        size = _used;
    if (size == 0)
        return 0;

    size_t first = MIN(size, _capacity - _readOffset);
    memcpy(dst, _buffer + _readOffset, first);
    _readOffset = (_readOffset + first) % _capacity;
    size_t remaining = size - first;
    if (remaining != 0) {
        memcpy((uint8_t *) dst + first, _buffer + _readOffset, remaining);
        _readOffset = (_readOffset + remaining) % _capacity;
    }
    _used -= size;
    return size;
}

#pragma mark - Listener wakeups

- (void)addListener:(id<AudioCaptureListener>)listener {
    if (listener == nil)
        return;
    lock(&_lock, 0);
    [_listeners addObject:listener];
    unlock(&_lock);
}

- (void)removeListener:(id<AudioCaptureListener>)listener {
    if (listener == nil)
        return;
    lock(&_lock, 0);
    [_listeners removeObject:listener];
    unlock(&_lock);
}

- (void)notifyListeners {
    NSArray *listeners;
    lock(&_lock, 0);
    listeners = _listeners.allObjects;
    unlock(&_lock);
    for (id<AudioCaptureListener> listener in listeners)
        [listener audioCaptureDidProduceBytes:self];
}

#pragma mark - AudioInputSink

// Runs on the audio queue's thread. A ring that fills up must never stall the
// producer (that would mean dropping audio at the device instead), so the
// oldest bytes go: a reader that fell behind loses the past, which is what a
// live capture device does, rather than the present.
- (void)audioInput:(AudioInput *)input receivedBytes:(const void *)bytes length:(size_t)length {
    (void) input;
    if (length == 0)
        return;

    const uint8_t *src = bytes;
    BOOL produced = NO;

    lock(&_lock, 0);
    if (_started) {
        if (length > _capacity) {
            size_t dropped = length - _capacity;
            _droppedBytes += dropped;
            _overrunCount++;
            src += dropped;
            length = _capacity;
        }
        if (length > [self spaceLocked]) {
            [self dropOldestLocked:length - [self spaceLocked]];
            _overrunCount++;
        }
        [self copyIntoRingLocked:src size:length];
        produced = YES;
    }
    unlock(&_lock);

    if (produced) {
        notify(&_dataAvailable);
        [self notifyListeners];
    }
}

@end
