#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The one sample format the core delivers today. An enum rather than a bare
// constant so a front-end never has to learn an OSS spelling.
typedef NS_ENUM(int, AudioCaptureSampleFormat) {
    AudioCaptureSampleFormatS16LE = 0,
};

@class AudioCapture;

// Called, with no core lock held, from the audio queue's thread whenever bytes
// land in the ring. A front-end uses it to wake its own poll waiters.
@protocol AudioCaptureListener <NSObject>
- (void)audioCaptureDidProduceBytes:(AudioCapture *)capture;
@end

// The capture side of the emulator's audio, deliberately ignorant of what
// opens it: no OSS constants, no struct fd, no device paths. /dev/mic is one
// thin front-end over this; a read path on /dev/dsp would be another, over the
// same instance.
//
// One stream per process, shared by every opener: bytes are handed to whoever
// reads first rather than duplicated per reader. Capture runs while the
// reference count is non-zero and stops when the last opener closes.
@interface AudioCapture : NSObject

+ (AudioCapture *)sharedCapture;

// Parameters hold for one capture run: set them before the first acquire, or
// again after the last release. A change while capture is running or starting
// fails with _EBUSY instead of being ignored.
- (int)setSampleRate:(int)sampleRate;   // 8000...48000 Hz; anything else _EINVAL
- (int)setChannels:(int)channels;       // 1 or 2; anything else _EINVAL
- (int)setSampleFormat:(int)format;     // AudioCaptureSampleFormatS16LE only
- (int)sampleRate;
- (int)channels;
- (int)sampleFormat;

// Reference counting. The first acquire asks for microphone permission (the
// caller blocks until the user answers), sets the recording session up and
// starts the queue; a later acquire joins the capture already running.
// Returns 0 or a negative guest errno: _EACCES when permission is refused,
// _EIO when the session or the queue would not start, _EINTR when a signal
// interrupted the wait for the permission prompt.
- (int)acquire;
- (void)releaseCapture;
- (int)readerCount;

// Blocking read. Returns bytes copied, or a negative guest errno: _EAGAIN when
// nonBlocking and the ring is empty, _EINTR when a signal interrupted the wait,
// _EIO when capture is not running.
- (ssize_t)readIntoBuffer:(void *)buffer size:(size_t)size nonBlocking:(BOOL)nonBlocking;

// Query hooks for a front-end that has ioctls of its own (a /dev/dsp read path
// would answer GETISPACE and GETBLKSIZE from these, and report overruns).
- (size_t)bytesAvailable;
- (size_t)fragmentSize;
- (uint64_t)overrunCount;   // appends that had to discard data because the ring was full
- (uint64_t)droppedBytes;   // how many bytes those appends discarded

- (void)addListener:(id<AudioCaptureListener>)listener;
- (void)removeListener:(id<AudioCaptureListener>)listener;

@end

NS_ASSUME_NONNULL_END
