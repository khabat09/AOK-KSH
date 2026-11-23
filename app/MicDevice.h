#include "fs/dev.h"

// /dev/mic: read-only capture. The device itself is a thin front-end over
// AudioCapture, which owns the queue, buffer, permission and session.
extern const struct dev_ops mic_dev;
