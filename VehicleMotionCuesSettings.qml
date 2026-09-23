import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "vehicleMotionCues"

    StyledText {
        width: parent.width
        text: "Vehicle Motion Cues"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Dots along the screen edges shift against the vehicle's acceleration, giving your eyes the motion your inner ear already feels. Brake and they slide up, accelerate and they slide down, turn and they slide the other way. Toggle it from the control centre; the overlay never takes input, so you can work straight through it."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    ToggleSetting {
        settingKey: "autoHide"
        label: "Only while moving"
        description: "Fade the dots in when sustained motion is detected and out again once you have been stopped for a while. Turn this off to keep them on screen whenever the feature is enabled."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "flipForeAft"
        label: "Flip fore/aft"
        description: "Use if the dots slide the wrong way when you brake -- e.g. the screen is mounted facing the rear of the vehicle."
        defaultValue: false
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    SliderSetting {
        settingKey: "sensitivity"
        label: "Sensitivity"
        description: "How far the dots travel for a given acceleration."
        defaultValue: 100
        minimum: 20
        maximum: 250
        unit: "%"
    }

    SliderSetting {
        settingKey: "maxShift"
        label: "Maximum travel"
        description: "Furthest the dot field will move from centre."
        defaultValue: 64
        minimum: 16
        maximum: 160
        unit: "px"
    }

    SliderSetting {
        settingKey: "intensity"
        label: "Dot brightness"
        defaultValue: 65
        minimum: 10
        maximum: 100
        unit: "%"
    }

    SliderSetting {
        settingKey: "dotSize"
        label: "Dot size"
        defaultValue: 8
        minimum: 3
        maximum: 20
        unit: "px"
    }

    SliderSetting {
        settingKey: "dotSpacing"
        label: "Dot spacing"
        defaultValue: 56
        minimum: 24
        maximum: 140
        unit: "px"
    }

    SliderSetting {
        settingKey: "bandWidth"
        label: "Edge band"
        description: "Thickness of the dotted border. Set to 0 to cover the whole screen instead of just the edges."
        defaultValue: 150
        minimum: 0
        maximum: 600
        unit: "px"
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StringSetting {
        settingKey: "accelDevice"
        label: "Accelerometer device"
        description: "IIO device directory. Leave empty to autodetect the device named accel_3d."
        placeholder: "/sys/bus/iio/devices/iio:device0"
        defaultValue: ""
    }

    SliderSetting {
        settingKey: "sampleRate"
        label: "Sample rate"
        description: "Requested accelerometer frequency. The hardware defaults to 10 Hz and accepted 100 Hz here; lower it if the sensor cannot keep up."
        defaultValue: 100
        minimum: 10
        maximum: 200
        unit: " Hz"
    }

    StyledText {
        width: parent.width
        text: "Needs access to the accelerometer's IIO buffer, which is root-only on a stock system — import nix/udev.nix from the plugin directory to hand it to your user. The buffer is the only interface that streams: polling the sysfs files instead yields 0.1 Hz with no axis movement at all, against 98.8 Hz from the buffer. Only one process can hold the buffer, so if screen autorotation is claiming it through iio-sensor-proxy, lock rotation and the cues get the sensor."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }
}
