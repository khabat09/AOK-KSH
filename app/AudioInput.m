#import "AudioInput.h"
#import <AudioToolbox/AudioQueue.h>

static const UInt32 kAudioInputBufferCount = 3;
static const UInt32 kAudioInputBufferBytes = 4096;

@interface AudioInput () {
    AudioQueueRef _queue;
    AudioQueueBufferRef _buffers[kAudioInputBufferCount];
    BOOL _running;
}

@property (nonatomic, weak) id<AudioInputSink> sink;
@property (nonatomic) int sampleRate;
@property (nonatomic) int channels;

- (void)enqueueBuffer:(AudioQueueBufferRef)buffer;

@end

static void AudioInputCallback(void *userData, AudioQueueRef queue, AudioQueueBufferRef buffer,
                               const AudioTimeStamp *startTime, UInt32 packetCount,
                               const AudioStreamPacketDescription *packetDescriptions);

@implementation AudioInput

- (instancetype)initWithSampleRate:(int)sampleRate
                          channels:(int)channels
                              sink:(id<AudioInputSink>)sink {
    self = [super init];
    if (self != nil) {
        _sampleRate = sampleRate;
        _channels = channels;
        _sink = sink;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)start {
    if (_running)
        return YES;

    // The same format AudioOutput records playback in, for the input direction:
    // packed signed integer, S16LE in practice.
    AudioStreamBasicDescription format = {
        .mSampleRate = self.sampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        .mFramesPerPacket = 1,
        .mChannelsPerFrame = (UInt32) self.channels,
        .mBitsPerChannel = 16,
        .mBytesPerFrame = (UInt32) (self.channels * sizeof(int16_t)),
        .mBytesPerPacket = (UInt32) (self.channels * sizeof(int16_t)),
    };

    OSStatus status = AudioQueueNewInput(&format, AudioInputCallback, (__bridge void *) self,
                                         NULL, NULL, 0, &_queue);
    if (status != noErr)
        return NO;

    _running = YES;
    for (UInt32 index = 0; index < kAudioInputBufferCount; index++) {
        status = AudioQueueAllocateBuffer(_queue, kAudioInputBufferBytes, &_buffers[index]);
        if (status != noErr)
            break;
        // Input buffers are handed to the queue empty; the queue fills them and
        // the callback takes them back.
        AudioQueueEnqueueBuffer(_queue, _buffers[index], 0, NULL);
    }
    if (status != noErr) {
        [self stop];
        return NO;
    }

    status = AudioQueueStart(_queue, NULL);
    if (status != noErr) {
        [self stop];
        return NO;
    }
    return YES;
}

- (void)stop {
    if (!_running && _queue == NULL)
        return;

    _running = NO;
    if (_queue != NULL) {
        AudioQueueStop(_queue, true);
        AudioQueueDispose(_queue, true);
        _queue = NULL;
    }
    for (UInt32 index = 0; index < kAudioInputBufferCount; index++)
        _buffers[index] = NULL;
}

- (void)enqueueBuffer:(AudioQueueBufferRef)buffer {
    if (!_running || buffer == NULL)
        return;

    AudioQueueEnqueueBuffer(_queue, buffer, 0, NULL);
}

@end

static void AudioInputCallback(void *userData, AudioQueueRef queue, AudioQueueBufferRef buffer,
                               const AudioTimeStamp *startTime, UInt32 packetCount,
                               const AudioStreamPacketDescription *packetDescriptions) {
    (void) queue;
    (void) startTime;
    (void) packetCount;
    (void) packetDescriptions;
    AudioInput *input = (__bridge AudioInput *) userData;
    @autoreleasepool {
        if (buffer != NULL && buffer->mAudioDataByteSize != 0)
            [input.sink audioInput:input receivedBytes:buffer->mAudioData length:buffer->mAudioDataByteSize];
    }
    [input enqueueBuffer:buffer];
}
