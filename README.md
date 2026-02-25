# L'Acoustics LA7.16 Source Router — Q-SYS Plugin

A Q-SYS plugin for managing the input/output matrix of L'Acoustics LA7.16 amplifiers. Select a source (1–16) and paint that assignment to any output crosspoint across multiple amplifiers.

## Features

- **Source Selection (1–16)** — Two rows of color-coded buttons to select an active source input.
- **Paint-to-Output** — Click any output button to assign the selected source. Works seamlessly across multiple amplifiers.
- **Multi-Amp Support** — Configure up to 8 LA7.16 amplifiers by their Q-SYS Named Component names.
- **Assign All** — One-click button per amplifier to assign the selected source to all 16 outputs.
- **Live Feedback** — Polls the L'Acoustics amplifier components at a configurable rate so changes made on the amp side are reflected in real time.
- **Configurable Source Colors** — Customize the color for each source (and the "no source" state) on the Settings page. Defaults are provided.
- **Pin Control** — `SelectedSource` and per-output `OutputSrc` pins allow external control and feedback via Q-SYS scripting or UCI.

## How It Works

The plugin interfaces with the L'Acoustics amplifier Named Components in Q-SYS Designer. Each amplifier exposes a 16×16 boolean matrix of `OutputPatch` controls:

```
OutputPatch index = (output - 1) × 16 + input
```

When you select a source and click an output button, the plugin sets the corresponding input's `OutputPatch` to `true` and clears the rest for that output.

## Setup

1. Add the plugin to your Q-SYS design.
2. Set the **Amp Count** property to match the number of LA7.16 amplifiers.
3. On the **Settings** page, enter the Named Component name for each amplifier (must match the name in Q-SYS Designer).
4. Optionally customize source colors (hex format, e.g. `#CC0000`).
5. Adjust the **Poll Rate** to control how frequently the plugin reads back the matrix state from the amplifiers.

## Pages

| Page | Description |
|------|-------------|
| **Amps 1–N** | Source selector buttons and a 16-output row per amplifier. Click to paint the selected source. |
| **Settings** | Amplifier component names, poll rate, source color configuration, and plugin version. |

## Controls

| Control | Type | Description |
|---------|------|-------------|
| `SourceSelect 1–16` | Button (Toggle) | Select the active source input. |
| `SelectedSource` | Knob / Pin (0–16) | Current source selection. 0 = none. |
| `AmpName 1–N` | Text / Pin | Named Component name of each amplifier. |
| `OutputBtn A_O` | Button | Paint the selected source to amplifier A, output O. |
| `OutputSrc A_O` | Knob / Pin (0–16) | Read/write the source assigned to amplifier A, output O. |
| `AssignAll A` | Button (Momentary) | Assign the selected source to all 16 outputs of amplifier A. |
| `AmpStatus A` | Status LED | Connection status for each amplifier. |
| `SourceColor 1–16` | Text | Custom hex color for each source. |
| `ColorNone` | Text | Custom hex color for unassigned outputs. |
| `PollRate` | Knob (1–20s) | How often the plugin reads back the amplifier matrix. |

## Requirements

- Q-SYS Designer / Core with L'Acoustics amplifier plugin components.
- LA7.16 amplifiers configured as Named Components in the design.

## License

MIT — see [LICENSE](LICENSE) for details.