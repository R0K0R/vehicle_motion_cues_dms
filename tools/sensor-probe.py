#!/usr/bin/env python3
"""
Work out how (and whether) this machine can stream its accelerometer fast
enough to drive motion cues. Run as root and TILT THE MACHINE throughout.

    sudo python3 tools/sensor-probe.py [seconds_per_test]

Background: as an unprivileged user the sysfs `in_accel_{x,y,z}_raw` files are
useless for this. Measured here: 1484 polls at 25 Hz across 60 s of deliberate
tilting returned ONE distinct value. Poll them a second or more apart and they
do go live, which caps the honest rate near 1 Hz -- an order of magnitude too
slow. The device sits at power/runtime_status=suspended with
power/autosuspend_delay_ms=3000, so this probe tests the two ways out:

  A. autosuspend  -- set power/autosuspend_delay_ms=0 so the sensor power-cycles
                     around each read and is forced to fetch a fresh report.
                     Cheap to deploy (a udev ATTR rule, nothing at runtime) but
                     it hammers the HID bus with one GET_REPORT per sample.
  B. IIO buffer   -- the interface actually designed for streaming: a trigger
                     fills /dev/iio:device0 with timestamped records at the
                     device's sampling frequency. Needs group access to the
                     buffer sysfs attrs and the chardev.

Whichever wins, the deployable form is a udev rule, not runtime root.
"""
import os
import struct
import sys
import time

IIO = "/sys/bus/iio/devices"
REC = struct.Struct("<iii4xq")  # x,y,z le:s32 + 8-byte-aligned le:s64 timestamp
DUR = float(sys.argv[1]) if len(sys.argv) > 1 else 12.0


def find_device(name="accel_3d"):
    for entry in sorted(os.listdir(IIO)):
        if entry.startswith("iio:device"):
            path = os.path.join(IIO, entry)
            try:
                if open(os.path.join(path, "name")).read().strip() == name:
                    return path
            except OSError:
                pass
    return None


def rd(dev, attr, default=None):
    try:
        return open(os.path.join(dev, attr)).read().strip()
    except OSError:
        return default


def wr(dev, attr, val):
    try:
        with open(os.path.join(dev, attr), "w") as f:
            f.write(str(val))
        return True
    except OSError as e:
        print("    ! write %s=%s: %s" % (attr, val, e))
        return False


def spread(vals):
    """Peak-to-peak of each axis, in raw counts -- did the numbers actually move?"""
    return [max(v[i] for v in vals) - min(v[i] for v in vals) for i in range(3)]


def test_sysfs(dev, label, dur):
    paths = [os.path.join(dev, "in_accel_%s_raw" % a) for a in "xyz"]
    seen, last, polls = [], None, 0
    t0 = time.time()
    while time.time() - t0 < dur:
        try:
            v = tuple(int(open(p).read()) for p in paths)
        except (OSError, ValueError) as e:
            print("    read failed: %s" % e)
            return 0.0
        polls += 1
        if v != last:
            seen.append(v)
            last = v
    el = time.time() - t0
    hz = len(seen) / el
    print("    %-22s %4d polls, %3d fresh in %.1fs -> %5.1f Hz   axis spread %s"
          % (label, polls, len(seen), el, hz, spread(seen) if seen else "-"))
    return hz


def test_buffer(dev, dur):
    if rd(dev, "buffer/enable") == "1":
        print("    buffer already enabled -- another process (iio-sensor-proxy)")
        print("    holds it; stop that first:  systemctl stop iio-sensor-proxy")
        return 0.0
    for a in "xyz":
        wr(dev, "scan_elements/in_accel_%s_en" % a, 1)
    before = rd(dev, "in_accel_sampling_frequency")
    for hz in (100, 50, 20):
        if wr(dev, "in_accel_sampling_frequency", hz):
            break
    print("    sampling_frequency %s -> %s" % (before, rd(dev, "in_accel_sampling_frequency")))
    wr(dev, "buffer/length", 128)
    if not wr(dev, "buffer/enable", 1):
        return 0.0

    node = "/dev/" + os.path.basename(dev)
    vals = []
    t0 = time.time()
    try:
        with open(node, "rb", buffering=0) as f:
            while time.time() - t0 < dur:
                rec = f.read(REC.size)
                if not rec or len(rec) < REC.size:
                    break
                x, y, z, _ts = REC.unpack(rec)
                vals.append((x, y, z))
    except OSError as e:
        print("    read %s failed: %s" % (node, e))
        return 0.0
    finally:
        wr(dev, "buffer/enable", 0)
    el = time.time() - t0
    hz = len(vals) / el if el else 0
    print("    %-22s %d records in %.1fs -> %5.1f Hz   axis spread %s"
          % ("buffer", len(vals), el, hz, spread(vals) if vals else "-"))
    return hz


def main():
    if os.geteuid() != 0:
        sys.exit("run as root:  sudo python3 tools/sensor-probe.py")
    dev = find_device()
    if not dev:
        sys.exit("no IIO device named accel_3d")

    print("device : %s" % dev)
    print("scale  : %s   sampling_frequency: %s" % (rd(dev, "in_accel_scale"),
                                                    rd(dev, "in_accel_sampling_frequency")))
    print("power  : runtime_status=%s autosuspend_delay_ms=%s"
          % (rd(dev, "power/runtime_status"), rd(dev, "power/autosuspend_delay_ms")))
    print("\n>>> TILT THE MACHINE CONTINUOUSLY FOR THE NEXT ~%d SECONDS <<<\n"
          % int(DUR * 3))

    results = {}

    print("[1] sysfs polling, autosuspend as-is")
    results["sysfs (default)"] = test_sysfs(dev, "as-is", DUR)

    print("\n[2] sysfs polling, autosuspend_delay_ms=0")
    orig = rd(dev, "power/autosuspend_delay_ms")
    if wr(dev, "power/autosuspend_delay_ms", 0):
        results["sysfs (autosuspend=0)"] = test_sysfs(dev, "autosuspend=0", DUR)
        wr(dev, "power/autosuspend_delay_ms", orig)
    else:
        print("    could not change autosuspend_delay_ms")

    print("\n[3] IIO trigger buffer")
    results["IIO buffer"] = test_buffer(dev, DUR)

    print("\n" + "=" * 62)
    best, best_hz = None, 0.0
    for name, hz in results.items():
        verdict = "USABLE" if hz >= 8 else ("marginal" if hz >= 4 else "too slow")
        print("  %-24s %6.1f Hz   %s" % (name, hz, verdict))
        if hz > best_hz:
            best, best_hz = name, hz
    print("=" * 62)
    print("\nBEST: %s at %.1f Hz" % (best, best_hz) if best_hz else "\nNothing streamed.")
    if best_hz < 8:
        print("Motion cues want >= ~10 Hz. If nothing reached that even while")
        print("tilting, the sensor genuinely cannot stream on this machine.")


if __name__ == "__main__":
    main()
