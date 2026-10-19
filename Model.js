// Option tables for the U4924DW's DDC/CI features. Values are the VCP
// codes the monitor reports in `ddcutil capabilities`; the E7/E8/E9 codes are
// Dell-specific and undocumented, so layouts not yet identified on this
// monitor are labelled by their raw value.

// The input this computer is plugged into; the `laptopInput` setting
// overrides it by label.
var LAPTOP_INPUT = 0x11

var inputs = [
  { value: 0x11, label: "HDMI 1" },
  { value: 0x12, label: "HDMI 2" },
  { value: 0x0f, label: "DP" },
  { value: 0x1b, label: "USB-C" }
]

var presets = [
  { value: 0x01, label: "sRGB" },
  { value: 0x04, label: "5000K" },
  { value: 0x05, label: "6500K" },
  { value: 0x06, label: "7500K" },
  { value: 0x08, label: "9300K" },
  { value: 0x09, label: "10000K" },
  { value: 0x0b, label: "User 1" },
  { value: 0x0c, label: "User 2" }
]

var modes = [
  { value: 0x00, label: "Standard" },
  { value: 0x03, label: "Movie" },
  { value: 0x05, label: "Game" }
]

var speaker = [
  { value: 0x02, label: "On" },
  { value: 0x01, label: "Muted" }
]

var layouts = [
  { value: 0x00, label: "Off" },
  { value: 0x24, label: "PBP" },
  { value: 0x21, label: "0x21" },
  { value: 0x22, label: "0x22" },
  { value: 0x01, label: "0x01" },
  { value: 0x02, label: "0x02" },
  { value: 0x2d, label: "0x2D" },
  { value: 0x2e, label: "0x2E" }
]

var kvm = [
  { value: 0xff00, label: "Swap keyboard & mouse", momentary: true }
]

function labelFor(options, value) {
  for (var i = 0; i < options.length; i++)
    if (options[i].value === value) return options[i].label
  return value < 0 ? "?" : "0x" + value.toString(16).toUpperCase()
}

// Input value for a label from `inputs`, or LAPTOP_INPUT if unknown.
function inputByLabel(label) {
  for (var i = 0; i < inputs.length; i++)
    if (inputs[i].label === label) return inputs[i].value
  return LAPTOP_INPUT
}

// `inputs` with the hint on the one this computer uses.
function inputsFor(laptopInput) {
  return inputs.map(function(o) {
    return o.value === laptopInput ? Object.assign({ hint: "this computer" }, o) : o
  })
}

function parseState(raw) {
  try {
    var s = JSON.parse(String(raw || ""))
    return s && s.ok ? s : null
  } catch (e) {
    return null
  }
}

// Would this laptop still be on screen after the change? Used to ask for a
// second click before a switch that blanks the only picture we can see.
function laptopVisible(state, code, value, laptopInput) {
  if (laptopInput === undefined) laptopInput = LAPTOP_INPUT
  var pbp = code === "E9" ? value : state.pbp
  var left = code === "60" ? value : state.input
  var right = code === "E8" ? value : state.pbpInput
  if (left === laptopInput) return true
  return pbp > 0 && right === laptopInput
}

function clampPercent(value) {
  var n = Number(value)
  if (!isFinite(n)) return 0
  return Math.max(0, Math.min(100, Math.round(n)))
}

if (typeof module !== "undefined") {
  module.exports = {
    LAPTOP_INPUT: LAPTOP_INPUT,
    inputs: inputs,
    presets: presets,
    modes: modes,
    speaker: speaker,
    layouts: layouts,
    kvm: kvm,
    labelFor: labelFor,
    inputByLabel: inputByLabel,
    inputsFor: inputsFor,
    parseState: parseState,
    laptopVisible: laptopVisible,
    clampPercent: clampPercent
  }
}
