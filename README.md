# Vehicle Motion Cues for DMS

Apple's iOS 18 motion-sickness aid, as a DankMaterialShell plugin. A field of
dots along the screen edges shifts *against* the vehicle's acceleration, the
way a loose object on the dashboard would: brake and they slide up, accelerate
and they slide down, turn left and they slide right. Peripheral vision picks
it up without you reading it, so your eyes stop insisting the world is still
while your inner ear says otherwise.

The overlay never takes input — you can work straight through it.

## Control

No control-centre entry; it is driven over IPC.

```
dms ipc call vehicleMotionCues on|off|toggle
dms ipc call vehicleMotionCues preview            # show the dots for 10s
dms ipc call vehicleMotionCues status
dms ipc call vehicleMotionCues orientation
dms ipc call vehicleMotionCues lockRotation|unlockRotation|toggleRotationLock
dms ipc call vehicleMotionCues rotationLockState
```

Appearance and behaviour (sensitivity, travel, dot size/spacing, edge band,
auto-hide, fore/aft flip) live in the plugin's settings page in DMS.

## Why it also does screen rotation

Not scope creep — arithmetic. The cues need a continuous stream of
acceleration. The only interface that provides one is the accelerometer's IIO
trigger buffer, and **an IIO buffer has exactly one owner**. `iio-sensor-proxy`
(which `iio-hyprland` listens to) wants that same buffer for orientation, so
whichever of the two starts second is simply told the device is busy.

Rather than arbitrate, the plugin serves both. It already maintains a gravity
estimate for the cues, and orientation is just which way that vector points, so
it derives the transform and emits the **identical** batch `iio-hyprland` would:

```
hyprctl --batch "keyword monitor <out>,transform,<N>"
```

aimed at the same PATH-shadowed shim in `features/hyprland/rotation.nix`. All of
that pipeline still does the work — the `keyword` → `hl.*` translation for the
Lua parser, touch and tablet transforms, the `scrolling:direction` remap, the
`reload` needed to get back to transform 0, and `my.hyprland.rotationHooks`.
None of it is reimplemented here; only its data source changed.

Which source is live is one switch, `my.desktop.autorotate` (`iio` |
`motion-cues` | `none`), because the two genuinely cannot coexist.

Rotation lock and the cues are independent: the lock stays in the control
centre (the `rotationLock` plugin), and under `motion-cues` it flips this
plugin's own lock over IPC rather than killing a listener — so the dots keep
drawing while rotation is held still, which is what you want in a moving car.

## Why sysfs polling is not an option

The obvious implementation — poll `in_accel_{x,y,z}_raw` from QML with a
`FileView` — is dead on HID sensor hubs. The hub returns one frozen cached
report however fast you read it. Measured on a Samsung Galaxy Book 4 Pro 360,
as root, while the machine was being deliberately tilted:

| interface | result |
|---|---|
| sysfs polling | 393 polls, **1 fresh sample** in 12.0 s → 0.1 Hz, axis spread `[0, 0, 0]` |
| IIO buffer | 1186 records in 12.0 s → **98.8 Hz**, axis spread `[364519, 930312, 1249127]` |

Those files only go live when reads are spaced a second or more apart, which
caps the honest rate near 1 Hz — an order of magnitude too slow to draw a
motion cue. The buffer also accepted a sampling-frequency bump from 10 Hz to
100 Hz. Hence `tools/accel-stream.py`, and hence the udev rule.

`tools/sensor-probe.py` reruns that comparison on any machine:

```
sudo python3 tools/sensor-probe.py     # then tilt it for ~40s
```

## Installation

Pin it as a flake input — it is plugin sources, not a flake, so `flake = false`:

```nix
inputs.vehicle-motion-cues = {
  url = "github:R0K0R/vehicle_motion_cues_dms";
  flake = false;
};
```

and point DMS at the checkout:

```nix
programs.dank-material-shell.plugins.vehicleMotionCues = {
  enable = true;
  src = inputs.vehicle-motion-cues;
  settings = {
    compositor = "hyprland";
    monitor = "eDP-1";
    manageRotation = true;              # see "Why it also does screen rotation"
    rotateCommand = "<path to the hyprctl transform shim>";
  };
};
```

Buffer access is root-only on a stock system; a udev rule hands it to the
`input` group, and nothing runs as root at runtime:

```nix
services.udev.extraRules = ''
  SUBSYSTEM=="iio", KERNEL=="iio:device*", ATTR{name}=="accel_3d", \
    MODE="0640", GROUP="input", RUN+="${openBuffer} %p"
'';
```

where `openBuffer` also hands over the `buffer/`, `scan_elements/` and
`in_accel_sampling_frequency` attributes — `GROUP=`/`MODE=` only cover the
device node. A complete version ships as `hosts/<host>/accelerometer.nix` in
the config this was written for.

### Iterating on it

`src` is a store path, so an edit needs a push and a re-pin. To skip that while
working on it, either point the plugin directory straight at a checkout:

```
ln -sfn /path/to/checkout ~/.config/DankMaterialShell/plugins/vehicleMotionCues
systemctl --user restart dms.service     # QML caches components per path
```

(add a home-manager activation guard to remove that symlink, or the next
`switch` will refuse to clobber it), or override the input for one build:

```
nixos-rebuild switch --flake . --override-input vehicle-motion-cues /path/to/checkout
```

A DMS restart is required after **every** QML edit — `dms ipc call plugins
reload` does not pick changes up, because QML caches compiled components by
URL.

## Two design notes

**Orientation is not a setting.** Screen-right and direction-of-travel are
derived from the measured gravity vector, so upright-in-a-lap and
flat-on-a-tray-table both map correctly with no per-posture special case. The
one thing that *cannot* be derived is the compositor's rotation sign
convention, so that is the `transformMap` setting (default `0,3,2,1`); if the
screen rotates the wrong way, swap the `3` and the `1`.

**The gravity estimate is renormalised to 9.81 every sample.** Without it, a
long steady acceleration inflates the estimate's magnitude until it swallows
the very signal being drawn. Pinning the magnitude lets the filter rotate but
not grow, so sustained acceleration survives for as long as it takes the
estimate to rotate onto it.
