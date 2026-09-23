import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Common
import qs.Services
import qs.Modules.Plugins

/*
  Apple's Vehicle Motion Cues (iOS 18), for DMS.

  THE IDEA. Car sickness is a sensory conflict: your inner ear reports the
  vehicle's acceleration while your eyes, locked on a screen, report a world
  that is perfectly still. The fix is not to hide the motion but to SHOW it --
  a field of dots at the screen edges that shifts AGAINST the vehicle's
  acceleration, the way a loose object on the dashboard would. Peripheral
  vision picks it up without you reading it, the conflict drops, and the
  nausea with it. Brake and the dots slide up; accelerate and they slide down;
  turn left and they slide right.

  WHERE THE MOTION COMES FROM, AND WHY IT IS A SUBPROCESS. The obvious
  implementation -- a FileView polling /sys/.../in_accel_{x,y,z}_raw -- is dead
  on this class of hardware. Measured on this machine, as root, while it was
  being deliberately tilted:

      sysfs polling   393 polls, 1 fresh in 12.0s ->  0.1 Hz  (axis spread 0,0,0)
      IIO buffer     1186 records in 12.0s        -> 98.8 Hz

  The HID sensor hub hands back one frozen cached report however fast you read
  it. The trigger buffer streams properly -- and accepted a sampling-frequency
  bump from 10 Hz to 100 Hz -- but it needs a binary record reader and access
  that a stock system grants only to root. Hence tools/accel-stream.py behind
  the udev rule in nix/udev.nix. When the helper cannot get the buffer it says
  why and exits; there is no quiet fallback, because 0.1 Hz cannot draw a
  motion cue and pretending otherwise would just look broken.

  ORIENTATION IS DERIVED FROM GRAVITY, NOT ASSUMED. The screen can be upright
  in a lap or flat on a tray table, and the two need opposite axis mappings:
  upright, fore-aft acceleration lies along the device's z (screen normal);
  flat, it lies along y. Both fall out of one formula if the in-plane axes are
  re-expressed relative to the measured gravity vector, so that is what
  screenAxes() does -- no orientation setting, no per-posture special case.
*/
PluginComponent {
    id: root

    // Gravity in m/s^2. Only the DIRECTION of the estimate is tracked (see
    // sample()); the magnitude is pinned here.
    readonly property real gravityMag: 9.80665

    // How fast the gravity estimate follows the accelerometer. Long enough
    // that a few seconds of hard braking is read as acceleration rather than
    // quietly absorbed into "which way is down", short enough that turning the
    // device does not leave the dots stuck off-centre.
    readonly property real gravityTau: 2.5

    // Smoothing on the in-plane acceleration. At ~100 Hz the raw signal is far
    // noisier than the cue wants, and the dots should read as a swell rather
    // than a twitch.
    readonly property real cueTau: 0.22

    // ---------------------------------------------------------------- settings

    function opt(key, fallback) {
        const v = pluginData ? pluginData[key] : undefined;
        return (v === undefined || v === null) ? fallback : v;
    }

    readonly property bool cuesEnabled: opt("enabled", false) === true
    readonly property bool autoHide: opt("autoHide", true) === true
    readonly property int dotSize: opt("dotSize", 8)
    readonly property int dotSpacing: opt("dotSpacing", 56)
    // 0 = cover the whole screen instead of just a band along each edge.
    readonly property int bandWidth: opt("bandWidth", 150)
    readonly property int intensity: opt("intensity", 65)
    readonly property int sensitivity: opt("sensitivity", 100)
    readonly property int maxShift: opt("maxShift", 64)
    readonly property bool flipForeAft: opt("flipForeAft", false) === true
    readonly property string accelDevice: opt("accelDevice", "")
    readonly property int sampleRate: opt("sampleRate", 100)

    // Autorotation. Off unless the nix module turns it on, because taking it
    // over means iio-hyprland must NOT also be running (see rotate()).
    readonly property bool manageRotation: opt("manageRotation", false) === true
    readonly property string compositor: opt("compositor", "")
    readonly property string monitorName: opt("monitor", "eDP-1")
    // Absolute path to features/hyprland's PATH-shadowed hyprctl shim. Empty
    // falls back to whatever `hyprctl` is on PATH, which under configType =
    // "lua" cannot parse `keyword` and will simply do nothing.
    readonly property string rotateCommand: opt("rotateCommand", "")
    /*
      Quadrant -> compositor transform, as "normal,ccw90,180,cw90".

      A device physically rotated 90 deg counter-clockwise needs its content
      rotated 90 deg CLOCKWISE to stay upright, i.e. transform 3 -- hence the
      default 0,3,2,1 rather than 0,1,2,3. Exposed as a setting because the
      sign convention is the one thing here that cannot be derived, only
      observed: if rotating the screen sends it the wrong way, swap the 3 and
      the 1. `dms ipc call vehicleMotionCues orientation` reports what the
      sensor currently believes, which is how to check.
    */
    readonly property string transformMap: opt("transformMap", "0,3,2,1")

    // px of dot travel per m/s^2, before clamping to maxShift.
    readonly property real gain: 18 * (sensitivity / 100)

    // ------------------------------------------------------------ live state

    property bool sensorOk: false
    // "", "busy", "denied", "missing", "stalled" -- what to tell the user.
    property string sensorFault: ""

    // Gravity estimate in the device frame, m/s^2.
    property real gx: 0
    property real gy: 0
    property real gz: 0
    property bool gravityInit: false
    property real lastSampleT: 0

    // Smoothed in-plane acceleration driving the cue, m/s^2.
    property real latS: 0
    property real foreS: 0

    // Smoothed magnitude of linear acceleration, for the auto-hide heuristic.
    property real motionLevel: 0
    property bool inMotion: false

    // Where the dot field sits, in px.
    property real shiftX: 0
    property real shiftY: 0

    // Forces the field visible for a few seconds regardless of auto-hide, so
    // the look can be tuned at a standstill instead of on a motorway.
    property bool previewing: false

    readonly property bool showing: cuesEnabled && sensorOk
                                    && (previewing || !autoHide || inMotion)

    // Current and proposed compositor transform (0..3). Named screenTransform
    // because QtQuick's Item.transform is FINAL and cannot be shadowed.
    property int screenTransform: 0
    property int proposedTransform: 0
    // Persisted (seeded once in Component.onCompleted rather than bound, so
    // the explicit assignment in setRotationLocked is not clobbered the next
    // time pluginData changes): a lock the user set deliberately should
    // outlive a shell restart, unlike the orientation itself which is always
    // re-derived from gravity.
    property bool rotationLocked: false

    // The signal is already smoothed in sample(); this is only frame-to-frame
    // interpolation insurance for if the sample rate ever drops.
    Behavior on shiftX {
        NumberAnimation {
            duration: 100
            easing.type: Easing.OutQuad
        }
    }
    Behavior on shiftY {
        NumberAnimation {
            duration: 100
            easing.type: Easing.OutQuad
        }
    }

    // ------------------------------------------------------------ the sensor

    readonly property string pluginPath: pluginService ? pluginService.getPluginPath(pluginId) : ""

    Process {
        id: accel
        running: (root.cuesEnabled || root.manageRotation) && root.pluginPath !== ""
        command: {
            const args = ["python3", root.pluginPath + "/tools/accel-stream.py",
                          "--rate", String(root.sampleRate)];
            if (root.accelDevice)
                args.push("--device", root.accelDevice);
            return args;
        }

        stdout: SplitParser {
            onRead: line => root.sample(line)
        }

        stderr: SplitParser {
            // The helper prefixes its hard failures so they can be turned into
            // something the control-center entry can actually say.
            onRead: line => {
                const s = String(line);
                if (s.indexOf("BUSY:") === 0)
                    root.setFault("busy");
                else if (s.indexOf("DENIED:") === 0)
                    root.setFault("denied");
                else if (s.indexOf("no IIO accelerometer") === 0)
                    root.setFault("missing");
            }
        }

        onExited: (exitCode, exitStatus) => {
            root.sensorOk = false;
            root.gravityInit = false;
            if (root.cuesEnabled || root.manageRotation)
                respawn.restart();
        }
    }

    // The helper is meant to run forever; if it dies, retry, but do not spin.
    Timer {
        id: respawn
        interval: 3000
        repeat: false
        onTriggered: {
            if (root.cuesEnabled || root.manageRotation)
                accel.running = true;
        }
    }

    // Samples should arrive every ~10 ms. A whole second of silence means the
    // stream has stalled -- drop the dots rather than leave them frozen
    // mid-shift, which would be a misleading cue.
    Timer {
        id: watchdog
        interval: 1000
        repeat: false
        onTriggered: {
            root.sensorOk = false;
            root.setFault("stalled");
            root.shiftX = 0;
            root.shiftY = 0;
        }
    }

    function setFault(kind) {
        sensorFault = kind;
        publishStatus();
    }

    /*
      Parked in plugin state so anything outside this object -- another
      plugin, or a later `dms ipc call ... status` -- can see WHY the cues are
      not running rather than just that they are not.
    */
    function publishStatus() {
        if (pluginService && pluginService.savePluginState)
            pluginService.savePluginState(pluginId, "fault", sensorFault);
    }

    /*
      One accelerometer sample: "x y z" in m/s^2, device frame.

      The gravity estimate is low-passed and then RENORMALISED to 9.81. Without
      the renormalisation a long, steady acceleration grows the estimate's
      magnitude until it swallows the very signal we want to draw; pinning the
      magnitude means the filter can only rotate, so sustained acceleration
      survives as long as it takes gravityTau to rotate the estimate onto it.
    */
    function sample(line) {
        const parts = String(line).trim().split(/\s+/);
        if (parts.length < 3)
            return;
        const ax = parseFloat(parts[0]);
        const ay = parseFloat(parts[1]);
        const az = parseFloat(parts[2]);
        if (!isFinite(ax) || !isFinite(ay) || !isFinite(az))
            return;

        if (!sensorOk || sensorFault) {
            sensorOk = true;
            sensorFault = "";
            publishStatus();
        }
        watchdog.restart();

        const now = Date.now();
        const dt = lastSampleT > 0 ? Math.min((now - lastSampleT) / 1000, 1.0) : 0;
        lastSampleT = now;

        if (!gravityInit) {
            gx = ax;
            gy = ay;
            gz = az;
            gravityInit = true;
            return;
        }

        const alpha = dt > 0 ? 1 - Math.exp(-dt / gravityTau) : 0;
        gx += (ax - gx) * alpha;
        gy += (ay - gy) * alpha;
        gz += (az - gz) * alpha;
        const gm = Math.sqrt(gx * gx + gy * gy + gz * gz);
        if (gm < 0.5)
            return; // freefall, or a sensor talking nonsense
        const k = gravityMag / gm;
        gx *= k;
        gy *= k;
        gz *= k;

        const lx = ax - gx;
        const ly = ay - gy;
        const lz = az - gz;

        const axes = screenAxes(gx / gravityMag, gy / gravityMag, gz / gravityMag);
        const lat = lx * axes.rx + ly * axes.ry + lz * axes.rz;
        let fore = lx * axes.fx + ly * axes.fy + lz * axes.fz;
        if (flipForeAft)
            fore = -fore;

        const cAlpha = dt > 0 ? 1 - Math.exp(-dt / cueTau) : 0;
        latS += (lat - latS) * cAlpha;
        foreS += (fore - foreS) * cAlpha;

        if (manageRotation)
            updateOrientation(gx / gravityMag, gy / gravityMag);

        const mag = Math.sqrt(lx * lx + ly * ly + lz * lz);
        const mAlpha = dt > 0 ? 1 - Math.exp(-dt / 3.0) : 0;
        motionLevel += (mag - motionLevel) * mAlpha;
        updateMotionState();

        // Dead zone: sensor noise should not make the field twitch at a
        // standstill.
        const dead = 0.08;
        const latE = Math.abs(latS) < dead ? 0 : latS - Math.sign(latS) * dead;
        const foreE = Math.abs(foreS) < dead ? 0 : foreS - Math.sign(foreS) * dead;

        // Dots move OPPOSITE the lateral acceleration and WITH the fore-aft
        // one, because QML's y axis grows downward: accelerate (fore > 0) and
        // the field slides down the screen, which is what a loose object does.
        shiftX = clampShift(-gain * latE);
        shiftY = clampShift(gain * foreE);
    }

    function clampShift(v) {
        return Math.max(-maxShift, Math.min(maxShift, v));
    }

    /*
      Screen-right and direction-of-travel as unit vectors in the DEVICE frame,
      given the unit gravity vector.

      Screen-right is the device's +x with any component along gravity removed,
      so it stays horizontal however the screen is tilted. Forward is then the
      remaining horizontal direction, r x g -- which resolves to -z (into the
      screen, away from a viewer facing forward) when the device is upright,
      and to +y when it is lying flat with the screen up. Both are the
      direction of travel, which is the point of deriving them this way.

      The degenerate case is the device balanced on its side edge, where +x
      points at the floor and the projection collapses; fall back to the
      device's +y as the in-plane reference.
    */
    function screenAxes(ux, uy, uz) {
        let rx = 1 - ux * ux;
        let ry = -ux * uy;
        let rz = -ux * uz;
        let rn = Math.sqrt(rx * rx + ry * ry + rz * rz);
        if (rn < 0.15) {
            rx = -uy * ux;
            ry = 1 - uy * uy;
            rz = -uy * uz;
            rn = Math.sqrt(rx * rx + ry * ry + rz * rz);
            if (rn < 1e-6)
                return { rx: 1, ry: 0, rz: 0, fx: 0, fy: 0, fz: -1 };
        }
        rx /= rn;
        ry /= rn;
        rz /= rn;

        // f = r x g, already unit length since both are unit and perpendicular.
        return {
            rx: rx, ry: ry, rz: rz,
            fx: ry * uz - rz * uy,
            fy: rz * ux - rx * uz,
            fz: rx * uy - ry * ux
        };
    }

    // Hysteresis plus a linger, so a red light does not blink the dots away
    // and a single pothole does not summon them.
    function updateMotionState() {
        if (motionLevel > 0.35) {
            inMotion = true;
            linger.restart();
        } else if (motionLevel < 0.15 && inMotion && !linger.running) {
            inMotion = false;
        }
    }

    Timer {
        id: preview
        interval: 10000
        repeat: false
        onTriggered: root.previewing = false
    }

    Timer {
        id: linger
        interval: 20000
        repeat: false
        onTriggered: {
            if (root.motionLevel < 0.15)
                root.inMotion = false;
        }
    }

    onCuesEnabledChanged: {
        if (!cuesEnabled) {
            sensorOk = false;
            sensorFault = "";
            gravityInit = false;
            inMotion = false;
            previewing = false;
            motionLevel = 0;
            latS = 0;
            foreS = 0;
            shiftX = 0;
            shiftY = 0;
            watchdog.stop();
            linger.stop();
            publishStatus();
        }
    }


    // ------------------------------------------------------------ rotation

    Component.onCompleted: rotationLocked = opt("rotationLocked", false) === true

    /*
      AUTOROTATION, FOLDED INTO THE SAME SENSOR READER.

      Only one process can hold an IIO buffer, so the cues and iio-hyprland
      cannot both have the accelerometer -- whoever gets there second is told
      the device is busy. Rather than arbitrate, this plugin serves both: it
      already maintains a gravity estimate for the cues, and screen
      orientation is nothing more than which way that vector points.

      It deliberately does NOT reimplement the rotation itself. What it emits
      is byte-for-byte the batch iio-hyprland emits --

          hyprctl --batch "keyword monitor <out>,transform,<N>"

      -- aimed at features/hyprland's PATH-shadowed hyprctl shim, so the whole
      existing pipeline still does the work: the translation of `keyword` into
      hl.* calls for the Lua parser, the touch and tablet transforms, the
      scrolling:direction remap, the `reload` workaround for returning to
      transform 0, and my.hyprland.rotationHooks. None of that is duplicated
      here; only its data source changed.

      Consequence: iio-hyprland must not also be running when this is on, or
      the two will fight for both the sensor and the compositor.
    */

    readonly property var transforms: {
        const parts = String(transformMap).split(",").map(v => parseInt(v.trim(), 10));
        if (parts.length !== 4 || parts.some(v => !(v >= 0 && v <= 3)))
            return [0, 3, 2, 1];
        return parts;
    }

    /*
      Which quadrant the device is held in, from the in-plane gravity
      direction. Returns -1 when the answer is not trustworthy.

      With the screen upright, gravity in the device frame is
      (-sin th, -cos th) for a device turned th counter-clockwise, so
      atan2(-x, -y) recovers th directly. Lying flat the in-plane component
      collapses to noise, which is what the inPlane guard rejects -- a tablet
      face-up on a car seat should keep whatever rotation it had, not spin
      with every bump. The +-35 deg window around each quadrant is a further
      deadband: between the windows nothing is proposed at all, so a device
      held at 45 deg sits still instead of flapping between two answers.
    */
    function quadrantFor(ux, uy) {
        const inPlane = Math.sqrt(ux * ux + uy * uy);
        if (inPlane < 0.55)
            return -1;
        let deg = Math.atan2(-ux, -uy) * 180 / Math.PI;
        if (deg < 0)
            deg += 360;
        const q = Math.round(deg / 90) % 4;
        let err = deg - q * 90;
        while (err > 180)
            err -= 360;
        while (err < -180)
            err += 360;
        if (Math.abs(err) > 35)
            return -1;
        return q;
    }

    function updateOrientation(ux, uy) {
        const q = quadrantFor(ux, uy);
        if (q < 0)
            return;
        const want = transforms[q];
        if (want === screenTransform) {
            dwell.stop();
            proposedTransform = screenTransform;
            return;
        }
        if (want !== proposedTransform) {
            proposedTransform = want;
            dwell.restart();
        }
    }

    // A rotation is committed only after the new orientation has held. Without
    // the dwell, handing the machine to someone across a car would rotate the
    // screen twice on the way.
    Timer {
        id: dwell
        interval: 700
        repeat: false
        onTriggered: root.rotate(root.proposedTransform)
    }

    Process {
        id: rotProc
    }

    function rotate(t) {
        if (!manageRotation || rotationLocked || t === screenTransform)
            return;
        screenTransform = t;
        if (compositor === "niri") {
            rotProc.command = ["niri", "msg", "output", monitorName,
                               "transform", String((t * 90) % 360)];
        } else {
            rotProc.command = [rotateCommand || "hyprctl", "--batch",
                               "keyword monitor " + monitorName + ",transform," + t];
        }
        rotProc.startDetached();
    }

    function setRotationLocked(on) {
        rotationLocked = on === true;
        if (pluginService)
            pluginService.savePluginData(pluginId, "rotationLocked", rotationLocked);
        if (!rotationLocked)
            dwell.restart();
    }

    // ------------------------------------------------------------- control

    function toggle() {
        setEnabled(!cuesEnabled);
    }

    function setEnabled(on) {
        if (pluginService)
            pluginService.savePluginData(pluginId, "enabled", on === true);
    }

    IpcHandler {
        target: "vehicleMotionCues"

        function toggle(): string {
            root.toggle();
            return root.cuesEnabled ? "on" : "off";
        }
        function on(): string {
            root.setEnabled(true);
            return "on";
        }
        function off(): string {
            root.setEnabled(false);
            return "off";
        }
        function lockRotation(): string {
            root.setRotationLocked(true);
            return "locked";
        }
        function unlockRotation(): string {
            root.setRotationLocked(false);
            return "unlocked";
        }
        function toggleRotationLock(): string {
            root.setRotationLocked(!root.rotationLocked);
            return root.rotationLocked ? "locked" : "unlocked";
        }
        function rotationLockState(): string {
            return root.rotationLocked ? "locked" : "unlocked";
        }
        function orientation(): string {
            return "transform=" + root.screenTransform
                + " proposed=" + root.proposedTransform
                + " map=" + root.transformMap
                + (root.rotationLocked ? " locked" : "")
                + (root.manageRotation ? "" : " (rotation not managed)");
        }

        function preview(): string {
            if (!root.cuesEnabled)
                root.setEnabled(true);
            root.previewing = true;
            preview.restart();
            return "showing the dot field for 10s";
        }

        function status(): string {
            return (root.cuesEnabled ? "enabled" : "disabled")
                + (root.sensorOk ? ", streaming" : ", no data" + (root.sensorFault ? " (" + root.sensorFault + ")" : ""))
                + (root.showing ? ", showing" : ", hidden");
        }
    }

    GlobalShortcut {
        appid: "dms-vehiclemotioncues"
        name: "toggle"
        description: "Toggle vehicle motion cues"
        onPressed: root.toggle()
    }

    // ------------------------------------------------------------- overlay

    Variants {
        // Kept mapped for the whole time the feature is enabled, so auto-hide
        // can cross-fade the dots instead of popping a layer surface in and
        // out on every traffic light.
        model: root.cuesEnabled ? Quickshell.screens : []

        PanelWindow {
            id: overlay

            required property var modelData
            screen: modelData

            // Deliberately not "dms-*": features/dms/compositor.nix turns on
            // Hyprland blur for layers matching ^(dms.*)$, which would blur the
            // whole screen behind this full-output surface.
            WlrLayershell.namespace: "vehiclemotioncues"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            // Cover the entire output, the bar's exclusive zone included --
            // the cue belongs at the true screen edge.
            WlrLayershell.exclusionMode: ExclusionMode.Ignore

            anchors {
                left: true
                right: true
                top: true
                bottom: true
            }
            color: "transparent"

            // An empty input region: every click, tap and pen stroke passes
            // straight through to whatever is underneath. Without this the
            // overlay would swallow the entire screen's input.
            mask: Region {}

            property var dots: []

            /*
              Dot positions are fixed to the SCREEN and the whole field is
              translated, so the grid is rebuilt only when geometry or settings
              change, never per frame.

              The grid is generated over a rect grown by maxShift on every side
              while opacity is measured from the real screen edges, so sliding
              the field never drags an empty margin into view on the leading
              edge.
            */
            function rebuild() {
                const w = width, h = height;
                if (w <= 0 || h <= 0) {
                    dots = [];
                    return;
                }
                const sp = Math.max(8, root.dotSpacing);
                const band = root.bandWidth;
                const pad = root.maxShift + sp;
                const out = [];
                for (let y = -pad; y < h + pad; y += sp) {
                    for (let x = -pad; x < w + pad; x += sp) {
                        const cx = x + sp / 2;
                        const cy = y + sp / 2;
                        let op = 1;
                        if (band > 0) {
                            const d = Math.min(cx, w - cx, cy, h - cy);
                            if (d >= band)
                                continue;
                            if (d > 0) {
                                const t = 1 - d / band;
                                op = t * t * (3 - 2 * t); // smoothstep
                            }
                        }
                        out.push({ dx: cx, dy: cy, op: op });
                    }
                }
                dots = out;
            }

            onWidthChanged: rebuild()
            onHeightChanged: rebuild()
            Component.onCompleted: rebuild()

            Connections {
                target: root
                function onDotSpacingChanged() { overlay.rebuild(); }
                function onBandWidthChanged() { overlay.rebuild(); }
                function onMaxShiftChanged() { overlay.rebuild(); }
            }

            Item {
                anchors.fill: parent
                opacity: root.showing ? 1 : 0
                visible: opacity > 0

                Behavior on opacity {
                    NumberAnimation {
                        duration: 500
                        easing.type: Easing.InOutQuad
                    }
                }

                Item {
                    id: field
                    width: parent.width
                    height: parent.height
                    x: root.shiftX
                    y: root.shiftY

                    Repeater {
                        model: overlay.dots

                        Item {
                            id: dot
                            required property var modelData

                            width: root.dotSize
                            height: root.dotSize
                            x: modelData.dx - width / 2
                            y: modelData.dy - height / 2
                            opacity: modelData.op

                            // A dark halo under a light core, so the dot reads
                            // against both a white document and a dark video
                            // without ever sampling what is behind it.
                            Rectangle {
                                anchors.centerIn: parent
                                width: parent.width + 3
                                height: parent.height + 3
                                radius: width / 2
                                color: "#000000"
                                opacity: 0.38
                            }

                            Rectangle {
                                anchors.fill: parent
                                radius: width / 2
                                color: "#ffffff"
                                opacity: root.intensity / 100
                            }
                        }
                    }
                }
            }
        }
    }
}
