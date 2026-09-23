#!/usr/bin/env python3
"""
Stream the accelerometer as `x y z` lines of m/s^2 on stdout, one per sample,
for VehicleMotionCues.qml to consume over a Quickshell Process/SplitParser.

WHY THE IIO BUFFER AND NOTHING ELSE. The obvious approach -- poll
/sys/.../in_accel_{x,y,z}_raw from QML with a FileView -- is dead on this class
of hardware. Measured on a Samsung Galaxy Book (HID sensor hub, accel_3d), as
root, while the machine was being deliberately tilted:

    sysfs polling   393 polls, 1 fresh in 12.0s ->   0.1 Hz, axis spread [0,0,0]
    IIO buffer     1186 records in 12.0s        ->  98.8 Hz, axis spread [364519,
                                                                 930312, 1249127]

The hub hands back one frozen cached report no matter how fast you read; the
files only go live if reads are spaced a second or more apart. The trigger
buffer is the interface that genuinely streams, and it also let the sampling
frequency be raised from 10 Hz to 100 Hz. So this helper uses the buffer and,
when it cannot, says why and exits rather than silently degrading to a rate
that cannot draw a motion cue.

ACCESS. The buffer attrs and /dev/iio:device* are root-only on a stock system.
Deploy nix/udev.nix (or the equivalent rule) to hand them to a group; nothing
here needs to run as root at runtime.
"""
import argparse
import os
import struct
import sys

IIO = "/sys/bus/iio/devices"
# x,y,z are le:s32; in_timestamp is le:s64 which the kernel aligns to 8 bytes,
# so a record is 4+4+4+pad(4)+8 = 24 bytes, not 20.
REC = struct.Struct("<iii4xq")


def find_device(name):
    try:
        entries = sorted(os.listdir(IIO))
    except OSError:
        return None
    for entry in entries:
        if not entry.startswith("iio:device"):
            continue
        path = os.path.join(IIO, entry)
        try:
            if open(os.path.join(path, "name")).read().strip() == name:
                return path
        except OSError:
            continue
    return None


def rd(dev, attr, default=None):
    try:
        return open(os.path.join(dev, attr)).read().strip()
    except OSError:
        return default


def wr(dev, attr, value):
    try:
        with open(os.path.join(dev, attr), "w") as f:
            f.write(str(value))
        return True
    except OSError:
        return False


def buffer_dir(dev):
    """Kernels expose either buffer/ or buffer0/; prefer whichever is writable."""
    for name in ("buffer", "buffer0"):
        if os.path.isdir(os.path.join(dev, name)):
            return name
    return "buffer"


def fail(msg):
    print(msg, file=sys.stderr)
    sys.stderr.flush()
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--device", default="", help="IIO device dir; default: autodetect")
    ap.add_argument("--name", default="accel_3d", help="IIO device name to look for")
    ap.add_argument("--rate", type=int, default=100, help="requested sampling frequency (Hz)")
    args = ap.parse_args()

    dev = args.device or find_device(args.name)
    if not dev or not os.path.isdir(dev):
        return fail("no IIO accelerometer found (looked for name=%s under %s)"
                    % (args.name, IIO))

    try:
        scale = float(rd(dev, "in_accel_scale") or 1.0)
    except ValueError:
        scale = 1.0

    buf = buffer_dir(dev)
    node = "/dev/" + os.path.basename(dev)

    if not os.access(node, os.R_OK):
        return fail("DENIED: cannot read %s. Install the udev rule (hosts/<host>/"
                    "accelerometer.nix) so your user may open the IIO buffer." % node)

    # An already-armed buffer is ambiguous: it may be iio-sensor-proxy actively
    # serving an autorotate client, or it may just have been left enabled by
    # something that exited. Those need opposite responses and cannot be told
    # apart from sysfs, so DO NOT re-arm it -- disabling and re-enabling a
    # buffer another process is reading would yank the stream out from under
    # it. Try the read instead and let the kernel answer: a genuine second
    # owner makes the open fail with EBUSY.
    already_armed = rd(dev, buf + "/enable") == "1"

    if not already_armed:
        for axis in "xyz":
            wr(dev, "scan_elements/in_accel_%s_en" % axis, 1)
        if args.rate:
            wr(dev, "in_accel_sampling_frequency", args.rate)
        wr(dev, buf + "/length", 128)
        if not wr(dev, buf + "/enable", 1):
            return fail("DENIED: cannot enable %s/%s/enable. Install the udev rule "
                        "(hosts/<host>/accelerometer.nix) so your user may drive the "
                        "IIO buffer." % (dev, buf))

    print("streaming %s at %s Hz (scale %g)"
          % (dev, rd(dev, "in_accel_sampling_frequency"), scale), file=sys.stderr)
    sys.stderr.flush()

    try:
        f = open(node, "rb", buffering=0)
    except OSError as e:
        if not already_armed:
            wr(dev, buf + "/enable", 0)
        return fail("BUSY: %s is held by another process, almost certainly "
                    "iio-sensor-proxy serving screen autorotation (%s). Only one "
                    "process can own an IIO buffer." % (node, e))

    try:
        with f:
            while True:
                rec = f.read(REC.size)
                if not rec or len(rec) < REC.size:
                    break
                x, y, z, _ts = REC.unpack(rec)
                # Six decimals is finer than the sensor resolves and keeps the
                # line short; flush so the consumer sees samples as they happen.
                sys.stdout.write("%.6f %.6f %.6f\n" % (x * scale, y * scale, z * scale))
                sys.stdout.flush()
    except OSError as e:
        return fail("buffer read failed: %s" % e)
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    finally:
        if not already_armed:
            wr(dev, buf + "/enable", 0)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass
