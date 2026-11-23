#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioInput;

// Where captured bytes go. Called on the audio queue's own thread, so an
// implementation must not block.
@protocol AudioInputSink <NSObject>
- (void)audioInput:(AudioInput *)input receivedBytes:(const void *)bytes length:(size_t)length;
@end

// Microphone capture through AudioQueueNewInput: S16LE, interleaved, the
// requested rate and channel count. The mirror of AudioOutput for the input
// direction, and like it, it knows nothing about devices: session policy and
// buffering belong to AudioCapture.
@interface AudioInput : NSObject

- (instancetype)initWithSampleRate:(int)sampleRate
                          channels:(int)channels
                              sink:(id<AudioInputSink>)sink;
- (BOOL)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
