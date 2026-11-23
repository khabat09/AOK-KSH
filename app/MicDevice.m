#import <Foundation/Foundation.h>
#include "MicDevice.h"
#include "AudioCapture.h"
#include "fs/devices.h"
#include "fs/poll.h"
#include "kernel/errno.h"

// One open descriptor. Everything about capture -- the queue, the buffer, the
// permission, the session -- lives in AudioCapture; this object only attaches
// an fd to it and turns "bytes arrived" into a poll wakeup.
@interface MicDeviceFile : NSObject <AudioCaptureListener>

@property (nonatomic, assign) struct fd *guestFD;
@property (nonatomic, strong) AudioCapture *capture;

- (int)attach;
- (void)detach;
- (ssize_t)readIntoBuffer:(void *)buf size:(size_t)size nonBlocking:(BOOL)nonBlocking;
- (int)pollMask;

@end

@implementation MicDeviceFile

- (int)attach {
    self.capture = [AudioCapture sharedCapture];
    int err = [self.capture acquire];
    if (err < 0) {
        self.capture = nil;
        return err;
    }
    [self.capture addListener:self];
    return 0;
}

- (void)detach {
    if (self.capture == nil)
        return;
    [self.capture removeListener:self];
    [self.capture releaseCapture];
    self.capture = nil;
}

- (ssize_t)readIntoBuffer:(void *)buf size:(size_t)size nonBlocking:(BOOL)nonBlocking {
    return [self.capture readIntoBuffer:buf size:size nonBlocking:nonBlocking];
}

- (int)pollMask {
    return [self.capture bytesAvailable] != 0 ? POLL_READ : 0;
}

// Called by the core with no core lock held, so the wakeup it takes poll locks
// under is safe.
- (void)audioCaptureDidProduceBytes:(AudioCapture *)capture {
    (void) capture;
    if (self.guestFD != NULL)
        poll_wakeup(self.guestFD, POLL_READ);
}

@end

static int mic_open(int major, int minor, struct fd *fd) {
    (void) major;
    if (minor != DEV_MIC_MINOR)
        return _ENODEV;

    MicDeviceFile *file = [MicDeviceFile new];
    if (file == nil)
        return _ENOMEM;
    file.guestFD = fd;
    // Permission refused, or the queue would not start: the open fails, which
    // is the one place a guest can be told why. _EACCES for permission, _EIO or
    // _EINTR from the core's start path.
    int err = [file attach];
    if (err < 0) {
        file.guestFD = NULL;
        return err;
    }
    fd->data = (void *) CFBridgingRetain(file);
    return 0;
}

static int mic_close(struct fd *fd) {
    void *retainedFile = fd->data;
    MicDeviceFile *file = (__bridge MicDeviceFile *) retainedFile;
    fd->data = NULL;
    [file detach];
    CFBridgingRelease(retainedFile);
    return 0;
}

static ssize_t mic_read(struct fd *fd, void *buf, size_t bufsize) {
    MicDeviceFile *file = (__bridge MicDeviceFile *) fd->data;
    return [file readIntoBuffer:buf size:bufsize nonBlocking:(fd->flags & O_NONBLOCK_) != 0];
}

static int mic_poll(struct fd *fd) {
    MicDeviceFile *file = (__bridge MicDeviceFile *) fd->data;
    return [file pollMask];
}

// No write and no ioctl: a write reaches generic_write() with no ->write and
// gets _EBADF, an ioctl reaches fd_ioctl() with no ->ioctl_size and gets
// _ENOTTY. That is how the other read-only dynamic devices here behave
// (/dev/location, /dev/url), and it is the honest answer for a capture node.
const struct dev_ops mic_dev = {
    .open = mic_open,
    .fd.read = mic_read,
    .fd.poll = mic_poll,
    .fd.close = mic_close,
};
