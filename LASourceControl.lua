---------------------------------------------------------------
-- Q-SYS Plugin for L'Acoustics LA7.16 Source Router
-- Riley Watson
-- rwatson@onediversified.com
--
-- Current Version:
-- v260306.1 (RWatson)
--  - Combo source input mapping: each source can map to multiple
--    physical inputs (e.g. "1,3,5") via Settings page.
--  - Performance optimizations: pre-cached patch key strings,
--    reused tables, color cache, direct component indexing,
--    change-detection in poll loop (~50% CPU load reduction).
--
-- Change Log:
-- v260301.1 (RWatson)
--  - Configurable source/output label modes (Numbers, Labels, None).
--  - Source label mode ComboBox on Settings page.
--  - All amps displayed on a single router page (up to 12).
--  - Editable source labels propagate to output buttons.
--  - Opacity system: 100% source buttons, 75% output buttons,
--    100% when output matches selected source.
--  - Configurable per-source colors on Settings page.
--  - "Assign All" button reflects majority source color.
--  - No action when no source is selected.
-- v260224.1 (RWatson)
--  - Initial release.
--
-- Description:
--  Select a source (1-16) and paint that assignment to any
--  output crosspoint across multiple LA7.16 amplifiers.
--  Interfaces with the L'Acoustics amplifier plugin's
--  OutputPatch boolean matrix (16 outputs x 16 inputs).
--
--  OutputPatch index = (output - 1) * 16 + input
--    OutputPatch 1  = Output 1, Input 1
--    OutputPatch 2  = Output 1, Input 2
--    ...
--    OutputPatch 17 = Output 2, Input 1
--    ...
--    OutputPatch 256 = Output 16, Input 16
--
---------------------------------------------------------------

---------------------------------------------------------------
-- Plugin Info
---------------------------------------------------------------
PluginInfo = {
  Name = "L-Acoustics~Source Router",
  Version = "260306.1",
  Id = "b8a3e7c1-4f52-4d8a-a1e9-3c7b5d9f2e01",
  Author = "Riley Watson",
  Description = "Source router for L'Acoustics LA7.16 amplifier input/output matrix. Select a source (1-16) and paint to outputs across multiple amps.",
  ShowDebug = true
}

---------------------------------------------------------------
-- Pages (Dynamic)
---------------------------------------------------------------
local function getPageList(props)
  local pages = {}
  local ampCount = (props["Amp Count"] and props["Amp Count"].Value) or 1
  if ampCount == 1 then
    table.insert(pages, "Amp 1")
  else
    table.insert(pages, "Amps 1-" .. ampCount)
  end
  table.insert(pages, "Settings")
  return pages
end

function GetPages(props)
  local out = {}
  for _, name in ipairs(getPageList(props)) do
    table.insert(out, { name = name })
  end
  return out
end

---------------------------------------------------------------
-- Properties
---------------------------------------------------------------
function GetProperties()
  return {
    { Name = "Amp Count", Type = "integer", Min = 1, Max = 12, Value = 1 }
  }
end

---------------------------------------------------------------
-- Controls
---------------------------------------------------------------
function GetControls(props)
  local ctrls = {}
  local ampCount = props["Amp Count"].Value

  -- Source selection buttons (radio group, 1-16)
  for s = 1, 16 do
    table.insert(ctrls, { Name = "SourceSelect_" .. s, ControlType = "Button", ButtonType = "Toggle" })
  end
  table.insert(ctrls, {
    Name = "SelectedSource",
    ControlType = "Knob",
    ControlUnit = "Integer",
    Min = 0, Max = 16,
    UserPin = true,
    PinStyle = "Both"
  })

  -- Configurable source colors (text fields, one per source)
  for s = 1, 16 do
    table.insert(ctrls, { Name = "SourceColor_" .. s, ControlType = "Text" })
  end
  table.insert(ctrls, { Name = "ColorNone", ControlType = "Text" })

  -- Source labels (editable, propagate to output buttons)
  for s = 1, 16 do
    table.insert(ctrls, { Name = "SourceLabel_" .. s, ControlType = "Text", UserPin = true, PinStyle = "Both" })
  end

  -- Source input mapping (comma-separated physical inputs, e.g. "1,3")
  for s = 1, 16 do
    table.insert(ctrls, { Name = "SourceInputs_" .. s, ControlType = "Text", UserPin = true, PinStyle = "Both" })
  end
  table.insert(ctrls, {
    Name = "ShowOutputLabels",
    ControlType = "Text",
    Count = 1,
    Choices = {"Numbers", "Labels", "None"}
  })
  table.insert(ctrls, {
    Name = "ShowSourceLabels",
    ControlType = "Text",
    Count = 1,
    Choices = {"Numbers", "Labels", "None"}
  })

  -- Per amplifier controls
  for a = 1, ampCount do
    table.insert(ctrls, { Name = "AmpName_" .. a,   ControlType = "Text", UserPin = true, PinStyle = "Input" })
    table.insert(ctrls, { Name = "AmpStatus_" .. a,  ControlType = "Indicator", IndicatorType = "Status" })
    table.insert(ctrls, { Name = "AssignAll_" .. a,   ControlType = "Button", ButtonType = "Momentary" })

    for o = 1, 16 do
      table.insert(ctrls, {
        Name = "OutputBtn_" .. a .. "_" .. o,
        ControlType = "Button",
        ButtonType = "Momentary"
      })
      table.insert(ctrls, {
        Name = "OutputSrc_" .. a .. "_" .. o,
        ControlType = "Knob",
        ControlUnit = "Integer",
        Min = 0, Max = 16,
        UserPin = true,
        PinStyle = "Both"
      })
    end
  end

  table.insert(ctrls, { Name = "PollRate", ControlType = "Knob", ControlUnit = "Integer", Min = 1, Max = 20, Value = 2 })

  return ctrls
end

---------------------------------------------------------------
-- Layout
---------------------------------------------------------------
function GetControlLayout(props)
  local pages = getPageList(props)
  local page_index = props["page_index"].Value
  local current_page = pages[page_index] or pages[#pages]

  local layout, graphics = {}, {}
  local ampCount = math.max(1, math.min(12, props["Amp Count"].Value or 1))

  -- Sizing constants
  local srcBtnW, srcBtnH = 55, 28
  local srcSpacing = 58
  local outBtnW, outBtnH = 36, 24
  local outSpacing = 38
  local outputStartX = 95

  -- Helper: parse amp range from page name
  local function parseRangeFromPage(name, maxA)
    if name == "Settings" then return nil, nil end
    local single = name:match("^Amp%s+(%d+)$")
    if single then
      local n = tonumber(single)
      return math.max(1, math.min(n, maxA)), math.max(1, math.min(n, maxA))
    end
    local a, b = name:match("^Amps%s+(%d+)%s*%-%s*(%d+)$")
    if a and b then
      local lo, hi = tonumber(a), tonumber(b)
      if lo > hi then lo, hi = hi, lo end
      return math.max(1, lo), math.min(hi, maxA)
    end
    return 1, math.min(12, maxA)
  end

  -- Draw a router page for amp range [a_lo, a_hi]
  local function draw_router_page(a_lo, a_hi)
    local y = 5

    -- "SOURCE:" label row 1
    table.insert(graphics, {
      Type = "Label", Position = {8, y + 4}, Size = {65, 20},
      Text = "SOURCE:", HTextAlign = "Right", FontSize = 11
    })

    -- Source selection buttons row 1 (1-8) with label fields
    for s = 1, 8 do
      local x = 78 + (s - 1) * srcSpacing
      layout["SourceSelect_" .. s] = {
        Legend = tostring(s),
        Style = "Button",
        Position = {x, y},
        Size = {srcBtnW, srcBtnH}
      }
      layout["SourceLabel_" .. s] = {
        PrettyName = "Source " .. s .. " Label",
        Style = "Text",
        Position = {x, y + srcBtnH},
        Size = {srcBtnW, 14},
        Padding = 0,
        FontSize = 8
      }
    end

    y = y + srcBtnH + 14 + 4

    -- Source selection buttons row 2 (9-16) with label fields
    for s = 9, 16 do
      local x = 78 + (s - 9) * srcSpacing
      layout["SourceSelect_" .. s] = {
        Legend = tostring(s),
        Style = "Button",
        Position = {x, y},
        Size = {srcBtnW, srcBtnH}
      }
      layout["SourceLabel_" .. s] = {
        PrettyName = "Source " .. s .. " Label",
        Style = "Text",
        Position = {x, y + srcBtnH},
        Size = {srcBtnW, 14},
        Padding = 0,
        FontSize = 8
      }
    end

    -- Hidden pin-only controls
    layout["SelectedSource"] = {
      PrettyName = "Selected Source",
      Style = "Text",
      Position = {0, 0}, Size = {0, 0}
    }
    layout["PollRate"] = {
      PrettyName = "Poll Rate (s)",
      Style = "Text",
      Position = {0, 0}, Size = {0, 0}
    }

    -- Hide color config and settings-only controls on router pages
    for s = 1, 16 do
      layout["SourceColor_" .. s] = { PrettyName = "Source " .. s .. " Color", Style = "Text", Position = {0,0}, Size = {0,0} }
      layout["SourceInputs_" .. s] = { PrettyName = "Source " .. s .. " Inputs", Style = "Text", Position = {0,0}, Size = {0,0} }
    end
    layout["ColorNone"] = { PrettyName = "No Source Color", Style = "Text", Position = {0,0}, Size = {0,0} }
    layout["ShowOutputLabels"] = { PrettyName = "Output Label Mode", Style = "Text", Position = {0,0}, Size = {0,0} }
    layout["ShowSourceLabels"] = { PrettyName = "Source Label Mode", Style = "Text", Position = {0,0}, Size = {0,0} }

    y = y + srcBtnH + 14 + 8

    -- Column headers for outputs 1-16
    for o = 1, 16 do
      local x = outputStartX + (o - 1) * outSpacing
      table.insert(graphics, {
        Type = "Label", Position = {x, y}, Size = {outBtnW, 14},
        Text = tostring(o), HTextAlign = "Center", FontSize = 9
      })
    end

    y = y + 16

    -- Amp rows
    for a = a_lo, math.min(a_hi, ampCount) do
      -- Amp label
      table.insert(graphics, {
        Type = "Label", Position = {3, y + 2}, Size = {85, 20},
        Text = "Amp " .. a, HTextAlign = "Right", FontSize = 10
      })

      -- 16 output buttons
      for o = 1, 16 do
        local x = outputStartX + (o - 1) * outSpacing
        layout["OutputBtn_" .. a .. "_" .. o] = {
          Legend = "--",
          Style = "Button",
          Position = {x, y},
          Size = {outBtnW, outBtnH},
          Color = "#404040"
        }
        -- Hidden source pin
        layout["OutputSrc_" .. a .. "_" .. o] = {
          PrettyName = "Amp " .. a .. "~Output " .. o .. " Source",
          Style = "Text",
          Position = {0, 0}, Size = {0, 0}
        }
      end

      -- "All" button
      local allX = outputStartX + 16 * outSpacing + 4
      layout["AssignAll_" .. a] = {
        Legend = "All",
        Style = "Button",
        Position = {allX, y},
        Size = {36, outBtnH}
      }

      -- Status LED
      local statusX = allX + 42
      layout["AmpStatus_" .. a] = {
        PrettyName = "Amp " .. a .. " Status",
        Style = "LED",
        Position = {statusX, y + 4},
        Size = {16, 16}
      }

      -- Hidden amp name (visible on Settings page)
      layout["AmpName_" .. a] = {
        PrettyName = "Amp " .. a .. " Name",
        Style = "Text",
        Position = {0, 0}, Size = {0, 0}
      }

      y = y + outBtnH + 4
    end

    -- Hide controls for amps NOT on this page
    for a = 1, ampCount do
      if a < a_lo or a > a_hi then
        layout["AmpName_" .. a]   = { PrettyName = "Amp " .. a .. " Name",   Style = "Text", Position = {0,0}, Size = {0,0} }
        layout["AmpStatus_" .. a] = { PrettyName = "Amp " .. a .. " Status", Style = "LED",  Position = {0,0}, Size = {0,0} }
        layout["AssignAll_" .. a] = { Style = "Button", Position = {0,0}, Size = {0,0} }
        for o = 1, 16 do
          layout["OutputBtn_" .. a .. "_" .. o] = { Style = "Button", Position = {0,0}, Size = {0,0} }
          layout["OutputSrc_" .. a .. "_" .. o] = { PrettyName = "Amp " .. a .. "~Output " .. o .. " Source", Style = "Text", Position = {0,0}, Size = {0,0} }
        end
      end
    end
  end

  -- =====================================================
  -- Settings Page
  -- =====================================================
  if current_page == "Settings" then
    -- ---- Amplifier Names ----
    table.insert(graphics, {
      Type = "Label", Position = {10, 8}, Size = {250, 20},
      Text = "Amplifier Component Names", HTextAlign = "Left", FontSize = 12
    })

    for a = 1, ampCount do
      local y = 32 + (a - 1) * 28
      table.insert(graphics, {
        Type = "Label", Position = {10, y + 2}, Size = {60, 20},
        Text = "Amp " .. a .. ":", HTextAlign = "Right", FontSize = 10
      })
      layout["AmpName_" .. a] = {
        PrettyName = "Amp " .. a .. " Name",
        Style = "Text",
        Position = {75, y},
        Size = {200, 22},
        Padding = 2
      }
      layout["AmpStatus_" .. a] = {
        PrettyName = "Amp " .. a .. " Status",
        Style = "LED",
        Position = {280, y + 3},
        Size = {16, 16}
      }
    end

    local settingsY = 32 + ampCount * 28 + 16
    table.insert(graphics, {
      Type = "Label", Position = {10, settingsY + 2}, Size = {100, 20},
      Text = "Poll Rate (s):", HTextAlign = "Right", FontSize = 10
    })
    layout["PollRate"] = {
      PrettyName = "Poll Rate (s)",
      Style = "Knob",
      Position = {115, settingsY - 5},
      Size = {36, 36}
    }

    settingsY = settingsY + 44

    -- ---- Source Colors ----
    table.insert(graphics, {
      Type = "Label", Position = {10, settingsY}, Size = {250, 20},
      Text = "Source Colors (hex, e.g. #E05A3A)", HTextAlign = "Left", FontSize = 12
    })
    settingsY = settingsY + 22

    -- No-source color
    table.insert(graphics, {
      Type = "Label", Position = {10, settingsY + 2}, Size = {70, 18},
      Text = "None:", HTextAlign = "Right", FontSize = 10
    })
    layout["ColorNone"] = {
      PrettyName = "No Source Color",
      Style = "Text",
      Position = {85, settingsY},
      Size = {110, 20},
      Padding = 2
    }
    settingsY = settingsY + 24

    -- Sources 1-8 (left column) and 9-16 (right column)
    for row = 0, 7 do
      local s1 = row + 1
      local s2 = row + 9
      local y = settingsY + row * 24

      -- Left column: source 1-8
      table.insert(graphics, {
        Type = "Label", Position = {10, y + 2}, Size = {70, 18},
        Text = "Source " .. s1 .. ":", HTextAlign = "Right", FontSize = 10
      })
      layout["SourceColor_" .. s1] = {
        PrettyName = "Source " .. s1 .. " Color",
        Style = "Text",
        Position = {85, y},
        Size = {110, 20},
        Padding = 2
      }

      -- Right column: source 9-16
      table.insert(graphics, {
        Type = "Label", Position = {210, y + 2}, Size = {70, 18},
        Text = "Source " .. s2 .. ":", HTextAlign = "Right", FontSize = 10
      })
      layout["SourceColor_" .. s2] = {
        PrettyName = "Source " .. s2 .. " Color",
        Style = "Text",
        Position = {285, y},
        Size = {110, 20},
        Padding = 2
      }
    end

    settingsY = settingsY + 8 * 24 + 8

    -- ---- Source Input Mapping ----
    table.insert(graphics, {
      Type = "Label", Position = {10, settingsY}, Size = {350, 20},
      Text = "Source Input Mapping (comma-separated, e.g. 1,3)", HTextAlign = "Left", FontSize = 12
    })
    settingsY = settingsY + 22

    for row = 0, 7 do
      local s1 = row + 1
      local s2 = row + 9
      local y = settingsY + row * 24

      -- Left column: source 1-8
      table.insert(graphics, {
        Type = "Label", Position = {10, y + 2}, Size = {70, 18},
        Text = "Source " .. s1 .. ":", HTextAlign = "Right", FontSize = 10
      })
      layout["SourceInputs_" .. s1] = {
        PrettyName = "Source " .. s1 .. " Inputs",
        Style = "Text",
        Position = {85, y},
        Size = {110, 20},
        Padding = 2
      }

      -- Right column: source 9-16
      table.insert(graphics, {
        Type = "Label", Position = {210, y + 2}, Size = {70, 18},
        Text = "Source " .. s2 .. ":", HTextAlign = "Right", FontSize = 10
      })
      layout["SourceInputs_" .. s2] = {
        PrettyName = "Source " .. s2 .. " Inputs",
        Style = "Text",
        Position = {285, y},
        Size = {110, 20},
        Padding = 2
      }
    end

    settingsY = settingsY + 8 * 24 + 8

    -- ---- Output Label Mode ----
    table.insert(graphics, {
      Type = "Label", Position = {10, settingsY + 2}, Size = {140, 18},
      Text = "Output Label Mode:", HTextAlign = "Right", FontSize = 10
    })
    layout["ShowOutputLabels"] = {
      PrettyName = "Output Label Mode",
      Style = "ComboBox",
      Position = {155, settingsY},
      Size = {100, 20}
    }

    settingsY = settingsY + 24

    -- ---- Source Label Mode ----
    table.insert(graphics, {
      Type = "Label", Position = {10, settingsY + 2}, Size = {140, 18},
      Text = "Source Label Mode:", HTextAlign = "Right", FontSize = 10
    })
    layout["ShowSourceLabels"] = {
      PrettyName = "Source Label Mode",
      Style = "ComboBox",
      Position = {155, settingsY},
      Size = {100, 20}
    }

    settingsY = settingsY + 24
    table.insert(graphics, {
      Type = "Label", Position = {10, settingsY}, Size = {250, 16},
      Text = "Plugin Version: " .. (PluginInfo.Version or "Unknown"),
      HTextAlign = "Left", FontSize = 9
    })

    -- Hide source buttons and labels on Settings page
    for s = 1, 16 do
      layout["SourceSelect_" .. s] = { Style = "Button", Position = {0,0}, Size = {0,0} }
      layout["SourceLabel_" .. s] = { PrettyName = "Source " .. s .. " Label", Style = "Text", Position = {0,0}, Size = {0,0} }
      -- SourceInputs already laid out above on Settings page
    end
    layout["SelectedSource"] = { PrettyName = "Selected Source", Style = "Text", Position = {0,0}, Size = {0,0} }

    -- Hide all output controls on Settings page
    for a = 1, ampCount do
      layout["AssignAll_" .. a] = { Style = "Button", Position = {0,0}, Size = {0,0} }
      for o = 1, 16 do
        layout["OutputBtn_" .. a .. "_" .. o] = { Style = "Button", Position = {0,0}, Size = {0,0} }
        layout["OutputSrc_" .. a .. "_" .. o] = { PrettyName = "Amp " .. a .. "~Output " .. o .. " Source", Style = "Text", Position = {0,0}, Size = {0,0} }
      end
    end

  -- =====================================================
  -- Router Pages
  -- =====================================================
  else
    local lo, hi = parseRangeFromPage(current_page, ampCount)
    if lo and hi then draw_router_page(lo, hi) end
  end

  return layout, graphics
end

---------------------------------------------------------------
-- Runtime
---------------------------------------------------------------
if Controls then

local DEBUG = true
local function dbg(msg) if DEBUG then print(msg) end end

local ampCount = Properties["Amp Count"].Value

-- Default source color palette (base RGB only, no opacity)
local DefaultSourceColors = {
  [0]  = "#404040",  -- None (dark gray)
  [1]  = "#0077FF",  -- Vivid Blue
  [2]  = "#FF6600",  -- Vivid Orange
  [3]  = "#AA00DD",  -- Vivid Purple
  [4]  = "#00BBCC",  -- Vivid Cyan
  [5]  = "#DD0088",  -- Vivid Magenta
  [6]  = "#0099FF",  -- Sky Blue
  [7]  = "#FF3399",  -- Hot Pink
  [8]  = "#8800FF",  -- Electric Violet
  [9]  = "#886600",  -- Brown
  [10] = "#00CC66",  -- Mint
  [11] = "#3366CC",  -- Steel Blue
  [12] = "#CC3366",  -- Rose
  [13] = "#66CC00",  -- Lime
  [14] = "#6600CC",  -- Indigo
  [15] = "#009999",  -- Teal
  [16] = "#CC6699",  -- Mauve
}

-- Strip any existing opacity prefix and return pure #RRGGBB
local function NormalizeColor(hex)
  if not hex or hex == "" then return nil end
  hex = hex:match("^%s*(.-)%s*$") -- trim
  if hex:sub(1,1) == "#" then
    local body = hex:sub(2)
    if #body == 8 then
      -- #AARRGGBB -> #RRGGBB (strip the 2-char opacity prefix)
      return "#" .. body:sub(3)
    elseif #body == 6 then
      return hex
    end
  end
  return hex
end

-- Apply an opacity prefix (0-255) to a #RRGGBB color -> #AARRGGBB
local function ApplyOpacity(color, alpha)
  color = NormalizeColor(color) or "#404040"
  if color:sub(1,1) == "#" and #color == 7 then
    return string.format("#%02X%s", alpha, color:sub(2))
  end
  return color
end

-- Get the base color for a source (user-configured or default), no opacity
local function GetSourceColor(src)
  if src == 0 then
    local ctrl = Controls.ColorNone
    if ctrl and ctrl.String and ctrl.String:match("%S") then
      return NormalizeColor(ctrl.String) or DefaultSourceColors[0]
    end
    return DefaultSourceColors[0]
  end
  local ctrl = Controls["SourceColor_" .. src]
  if ctrl and ctrl.String and ctrl.String:match("%S") then
    return NormalizeColor(ctrl.String) or DefaultSourceColors[src] or "#404040"
  end
  return DefaultSourceColors[src] or "#404040"
end

-- Get brightened version of a source color for the selected source button
local function GetSourceColorSelected(src)
  local base = GetSourceColor(src)
  if base:sub(1,1) == "#" and #base == 7 then
    local r = tonumber(base:sub(2,3), 16) or 128
    local g = tonumber(base:sub(4,5), 16) or 128
    local b = tonumber(base:sub(6,7), 16) or 128
    r = math.min(255, r + 60)
    g = math.min(255, g + 60)
    b = math.min(255, b + 60)
    return string.format("#%02X%02X%02X", r, g, b)
  end
  return base
end

-- Color cache: avoids repeated string.format calls for the same source/opacity combos
-- Invalidated when source colors change.
local _colorCache = {}  -- _colorCache[src .. "_" .. alpha] = color string

local function GetCachedColor(src, alpha)
  local key = src * 256 + alpha  -- numeric key, no string alloc
  local cached = _colorCache[key]
  if cached then return cached end
  cached = ApplyOpacity(GetSourceColor(src), alpha)
  _colorCache[key] = cached
  return cached
end

local function InvalidateColorCache()
  for k in pairs(_colorCache) do _colorCache[k] = nil end
end

local selectedSource = 0
local amps = {}           -- { [a] = { name = string, comp = component_reference } }
local outputState = {}    -- { [a] = { [o] = source_number (0-16) } }
local pollTimer = Timer.New()

-- Source-to-input mapping: sourceInputMap[src] = { sorted list of physical input numbers }
-- Default: each source maps to its own input number.
local sourceInputMap = {}

-- Parse a comma-separated string of input numbers into a sorted table.
local function ParseInputList(str)
  local inputs = {}
  if not str or not str:match("%d") then return inputs end
  for num in str:gmatch("%d+") do
    local n = tonumber(num)
    if n and n >= 1 and n <= 16 then
      inputs[#inputs + 1] = n
    end
  end
  -- Deduplicate and sort
  table.sort(inputs)
  local deduped = {}
  for i, v in ipairs(inputs) do
    if i == 1 or v ~= inputs[i - 1] then
      deduped[#deduped + 1] = v
    end
  end
  return deduped
end

-- Rebuild the input map for a single source from its control
local function RefreshSourceInputMap(src)
  local ctrl = Controls["SourceInputs_" .. src]
  local str = ctrl and ctrl.String or ""
  if not str:match("%S") then
    -- Default: source maps to its own input
    sourceInputMap[src] = { src }
  else
    local parsed = ParseInputList(str)
    sourceInputMap[src] = (#parsed > 0) and parsed or { src }
  end
end

-- Rebuild all source input maps
local function RefreshAllSourceInputMaps()
  for s = 1, 16 do
    RefreshSourceInputMap(s)
  end
end

-- Get the set of physical inputs for a source as a lookup table { [input]=true }
local function GetSourceInputSet(src)
  local set = {}
  local inputs = sourceInputMap[src]
  if inputs then
    for _, inp in ipairs(inputs) do set[inp] = true end
  else
    if src >= 1 and src <= 16 then set[src] = true end
  end
  return set
end

---------------------------------------------------------------
-- Helpers
---------------------------------------------------------------

-- Calculate OutputPatch index from output number (1-16) and input number (1-16)
local function PatchIndex(output, input)
  return (output - 1) * 16 + input
end

-- Pre-cached OutputPatch key strings to avoid per-poll allocations
local patchKey = {}  -- patchKey[idx] = "OutputPatch N"
for idx = 1, 256 do
  patchKey[idx] = "OutputPatch " .. idx
end

-- Opacity constants
local OPACITY_FULL = 0xFF    -- 100% for source buttons & highlighted outputs
local OPACITY_DIM  = 0xBF    -- 75% for non-highlighted output buttons

-- Get the label for a source, or fall back to its number
local function GetSourceLabel(src)
  if src <= 0 then return "--" end
  local ctrl = Controls["SourceLabel_" .. src]
  if ctrl and ctrl.String and ctrl.String:match("%S") then return ctrl.String end
  return tostring(src)
end

-- Read a label mode ComboBox. Returns "Numbers", "Labels", or "None".
local function ReadLabelMode(ctrl)
  if not ctrl then return "Numbers" end
  local raw = ctrl.String or ""
  -- Match case-insensitively
  local lower = raw:lower():gsub("^%s*(.-)%s*$", "%1")
  if lower == "none"   then return "None"    end
  if lower == "labels" then return "Labels"  end
  if lower == "numbers" then return "Numbers" end
  -- If String didn't match, try Value as 0-based index
  local idx = math.floor((ctrl.Value or 0) + 0.5)
  if idx == 2 then return "None"    end
  if idx == 1 then return "Labels"  end
  return "Numbers"
end

local function GetOutputLabelMode()
  return ReadLabelMode(Controls.ShowOutputLabels)
end

local function GetSourceLabelMode()
  return ReadLabelMode(Controls.ShowSourceLabels)
end

-- Get the legend for a source button
local function GetSourceButtonLegend(src)
  local mode = GetSourceLabelMode()
  if mode == "None" then return " " end
  if src <= 0 then return " " end
  if mode == "Labels" then return GetSourceLabel(src) end
  return tostring(src)
end

-- Update the source selection button UI (always full opacity)
local function UpdateSourceUI()
  Controls.SelectedSource.Value = selectedSource
  for s = 1, 16 do
    local isSelected = (s == selectedSource)
    local baseColor = isSelected and GetSourceColorSelected(s) or GetSourceColor(s)
    Controls["SourceSelect_" .. s].Boolean = isSelected
    Controls["SourceSelect_" .. s].Color = ApplyOpacity(baseColor, OPACITY_FULL)
    Controls["SourceSelect_" .. s].Legend = GetSourceButtonLegend(s)
  end
end

-- Get the legend text for an output button
local function GetOutputLegend(src)
  local mode = GetOutputLabelMode()
  if mode == "None" then return " " end
  if src <= 0 then return " " end
  if mode == "Labels" then return GetSourceLabel(src) end
  return tostring(src)
end

-- Compute the majority source color for an amp's "All" button
-- Reuse a single counts table to avoid per-call allocation
local _allCounts = {}
local function UpdateAssignAllColor(a)
  local btn = Controls["AssignAll_" .. a]
  if not btn then return end
  if not outputState[a] then
    btn.Color = ApplyOpacity(GetSourceColor(0), OPACITY_DIM)
    return
  end
  -- Clear and reuse counts table
  for k in pairs(_allCounts) do _allCounts[k] = nil end
  for o = 1, 16 do
    local src = outputState[a][o] or 0
    _allCounts[src] = (_allCounts[src] or 0) + 1
  end
  -- Find majority
  local maxSrc, maxCount = 0, 0
  for src, cnt in pairs(_allCounts) do
    if cnt > maxCount then
      maxSrc = src
      maxCount = cnt
    end
  end
  local opacity = (maxSrc > 0 and maxSrc == selectedSource) and OPACITY_FULL or OPACITY_DIM
  btn.Color = ApplyOpacity(GetSourceColor(maxSrc), opacity)
end

-- Refresh all output button colors, legends, and All button colors
local function RefreshAllOutputColors()
  for a = 1, ampCount do
    if outputState[a] then
      for o = 1, 16 do
        local src = outputState[a][o] or 0
        local btn = Controls["OutputBtn_" .. a .. "_" .. o]
        if btn then
          btn.Legend = GetOutputLegend(src)
          local alpha = (src > 0 and src == selectedSource) and OPACITY_FULL or OPACITY_DIM
          btn.Color = GetCachedColor(src, alpha)
        end
      end
    end
    UpdateAssignAllColor(a)
  end
end

-- Set the globally selected source
local function SetSelectedSource(src)
  src = math.max(0, math.min(16, src or 0))
  selectedSource = src
  UpdateSourceUI()
  RefreshAllOutputColors()
  dbg("[SOURCE] Selected: " .. (src > 0 and tostring(src) or "None"))
end

-- Update one output button's display (legend + color with opacity)
local function UpdateOutputDisplay(a, o, skipAll)
  local src = (outputState[a] and outputState[a][o]) or 0
  local btn = Controls["OutputBtn_" .. a .. "_" .. o]
  local srcCtrl = Controls["OutputSrc_" .. a .. "_" .. o]

  if btn then
    btn.Legend = GetOutputLegend(src)
    local alpha = (src > 0 and src == selectedSource) and OPACITY_FULL or OPACITY_DIM
    btn.Color = GetCachedColor(src, alpha)
  end
  if srcCtrl then
    srcCtrl.Value = src
  end
  if not skipAll then
    UpdateAssignAllColor(a)
  end
end

-- Update amp status indicator
local function UpdateAmpStatus(a, statusCode, msg)
  local ctrl = Controls["AmpStatus_" .. a]
  if ctrl then
    ctrl.Value = statusCode   -- 0=OK, 1=Compromised, 2=Fault, 4=Missing, 5=Initializing
    ctrl.String = msg or ""
  end
end

---------------------------------------------------------------
-- Component Interface
---------------------------------------------------------------

-- Read the active inputs on an output and match against source input maps.
-- Returns the matching source (1-16), 0 if no inputs active, or -1 on error.
-- Reuses a single table for active inputs to avoid per-call allocation.
local _activeInputs = {}
local function ReadOutputSource(a, o)
  if not amps[a] or not amps[a].comp then return -1 end
  local comp = amps[a].comp

  -- Read which physical inputs are active for this output
  -- Use direct indexing instead of pcall+closure to avoid allocations
  local count = 0
  local base = (o - 1) * 16
  for i = 1, 16 do
    local ctrl = comp[patchKey[base + i]]
    if ctrl == nil then return -1 end  -- component disconnected
    if ctrl.Boolean then
      count = count + 1
      _activeInputs[count] = i
    end
  end

  if count == 0 then return 0 end

  -- _activeInputs[1..count] is already sorted (we iterate 1-16 in order)
  for src = 1, 16 do
    local mapped = sourceInputMap[src]
    if mapped and #mapped == count then
      local match = true
      for idx = 1, count do
        if mapped[idx] ~= _activeInputs[idx] then match = false; break end
      end
      if match then return src end
    end
  end

  -- No exact source match found; return the first active input as a fallback
  return _activeInputs[1] or 0
end

-- Write a source assignment to an output using the source's input map.
-- src=0 clears all 16 inputs.
local function WriteOutputSource(a, o, src)
  if not amps[a] or not amps[a].comp then return false end
  local comp = amps[a].comp
  local inputSet = (src > 0) and GetSourceInputSet(src) or {}
  local base = (o - 1) * 16
  for i = 1, 16 do
    local ctrl = comp[patchKey[base + i]]
    if ctrl == nil then return false end
    ctrl.Boolean = (inputSet[i] == true)
  end
  return true
end

-- Connect (or reconnect) to an amp's named component
local function ConnectAmp(a)
  local name = Controls["AmpName_" .. a].String
  if name == nil or name:match("^%s*$") then
    amps[a] = nil
    UpdateAmpStatus(a, 4, "No name configured")
    return
  end

  UpdateAmpStatus(a, 5, "Connecting...")
  local ok, comp = pcall(Component.New, name)
  if ok and comp then
    amps[a] = { name = name, comp = comp }
    UpdateAmpStatus(a, 0, name)
    dbg("[AMP " .. a .. "] Connected: " .. name)

    -- Read initial state
    if not outputState[a] then outputState[a] = {} end
    for o = 1, 16 do
      local src = ReadOutputSource(a, o)
      outputState[a][o] = (src >= 0) and src or 0
      UpdateOutputDisplay(a, o)
    end
  else
    amps[a] = nil
    UpdateAmpStatus(a, 2, "Not found: " .. name)
    dbg("[AMP " .. a .. "] Component not found: " .. name)
  end
end

---------------------------------------------------------------
-- Polling
---------------------------------------------------------------

local function PollAllAmps()
  for a = 1, ampCount do
    local name = Controls["AmpName_" .. a].String

    -- Skip amps with no name
    if not name or name:match("^%s*$") then
      if amps[a] then
        amps[a] = nil
        UpdateAmpStatus(a, 4, "No name configured")
        for o = 1, 16 do
          if outputState[a] then outputState[a][o] = 0 end
          UpdateOutputDisplay(a, o)
        end
      end
    else
      -- Auto-reconnect if not connected
      if not amps[a] or not amps[a].comp or amps[a].name ~= name then
        ConnectAmp(a)
      end

      -- Read current state
      if amps[a] and amps[a].comp then
        if not outputState[a] then outputState[a] = {} end
        local anyError = false
        local anyChanged = false

        for o = 1, 16 do
          local src = ReadOutputSource(a, o)
          if src >= 0 then
            if outputState[a][o] ~= src then
              outputState[a][o] = src
              UpdateOutputDisplay(a, o, true)  -- skip per-output All button update
              anyChanged = true
            end
          else
            anyError = true
          end
        end
        -- Only update All button if something changed
        if anyChanged then
          UpdateAssignAllColor(a)
        end

        if anyError then
          UpdateAmpStatus(a, 1, amps[a].name .. " (errors)")
          -- Try reconnecting next cycle
          amps[a] = nil
        else
          UpdateAmpStatus(a, 0, amps[a].name)
        end
      end
    end
  end
end

---------------------------------------------------------------
-- Event Handlers
---------------------------------------------------------------

-- Source selection buttons (radio behavior)
for s = 1, 16 do
  Controls["SourceSelect_" .. s].EventHandler = function(ctrl)
    if ctrl.Boolean then
      SetSelectedSource(s)
    else
      -- Toggled off the current source -> deselect
      SetSelectedSource(0)
    end
  end
end

-- Source color change handlers: refresh UI when user edits a color
for s = 1, 16 do
  Controls["SourceColor_" .. s].EventHandler = function()
    InvalidateColorCache()
    UpdateSourceUI()
    RefreshAllOutputColors()
  end
end
if Controls.ColorNone then
  Controls.ColorNone.EventHandler = function()
    InvalidateColorCache()
    RefreshAllOutputColors()
  end
end

-- Source label change handlers: update source button legend + output legends
for s = 1, 16 do
  Controls["SourceLabel_" .. s].EventHandler = function()
    UpdateSourceUI()
    RefreshAllOutputColors()
  end
end

-- Source input mapping change handlers
for s = 1, 16 do
  Controls["SourceInputs_" .. s].EventHandler = function()
    RefreshSourceInputMap(s)
    dbg("[INPUTS] Source " .. s .. " mapped to: " .. table.concat(sourceInputMap[s] or {s}, ","))
  end
end

-- Initialize all source input maps (from saved control values or defaults)
RefreshAllSourceInputMaps()

-- Show/hide output labels mode change
if Controls.ShowOutputLabels then
  Controls.ShowOutputLabels.Choices = {"Numbers", "Labels", "None"}
  Controls.ShowOutputLabels.EventHandler = function(ctrl)
    RefreshAllOutputColors()
  end
  -- Initialize to "Numbers" if empty
  if not Controls.ShowOutputLabels.String or not Controls.ShowOutputLabels.String:match("%S") then
    Controls.ShowOutputLabels.String = "Numbers"
  end
end

-- Show/hide source labels mode change
if Controls.ShowSourceLabels then
  Controls.ShowSourceLabels.Choices = {"Numbers", "Labels", "None"}
  Controls.ShowSourceLabels.EventHandler = function(ctrl)
    UpdateSourceUI()
  end
  -- Initialize to "Numbers" if empty
  if not Controls.ShowSourceLabels.String or not Controls.ShowSourceLabels.String:match("%S") then
    Controls.ShowSourceLabels.String = "Numbers"
  end
end

-- SelectedSource pin input
Controls.SelectedSource.EventHandler = function(ctrl)
  SetSelectedSource(math.floor(ctrl.Value + 0.5))
end

-- Per-amp event handlers
for a = 1, ampCount do
  if not outputState[a] then outputState[a] = {} end

  -- Amp name change -> reconnect
  Controls["AmpName_" .. a].EventHandler = function()
    ConnectAmp(a)
  end

  -- "Assign All" button -> assign selected source to all 16 outputs
  Controls["AssignAll_" .. a].EventHandler = function()
    if selectedSource == 0 then
      dbg("[AMP " .. a .. "] No source selected, ignoring Assign All")
      return
    end
    if not amps[a] or not amps[a].comp then
      dbg("[AMP " .. a .. "] Not connected, cannot assign all")
      return
    end
    for o = 1, 16 do
      if WriteOutputSource(a, o, selectedSource) then
        outputState[a][o] = selectedSource
        UpdateOutputDisplay(a, o)
      end
    end
    dbg("[AMP " .. a .. "] All outputs -> Source " .. selectedSource)
  end

  -- Per-output buttons and pins
  for o = 1, 16 do
    outputState[a][o] = 0

    -- Output button: paint selected source
    Controls["OutputBtn_" .. a .. "_" .. o].EventHandler = function()
      if selectedSource == 0 then
        dbg("[AMP " .. a .. "] No source selected, ignoring output " .. o)
        return
      end
      if not amps[a] or not amps[a].comp then
        dbg("[AMP " .. a .. "] Not connected, cannot set output " .. o)
        return
      end

      if WriteOutputSource(a, o, selectedSource) then
        outputState[a][o] = selectedSource
        UpdateOutputDisplay(a, o)
        dbg("[AMP " .. a .. "] Output " .. o .. " -> Source " .. selectedSource)
      end
    end

    -- OutputSrc pin: external source assignment
    Controls["OutputSrc_" .. a .. "_" .. o].EventHandler = function(ctrl)
      local src = math.floor(ctrl.Value + 0.5)
      src = math.max(0, math.min(16, src))
      if not amps[a] or not amps[a].comp then return end
      if WriteOutputSource(a, o, src) then
        outputState[a][o] = src
        UpdateOutputDisplay(a, o)
        dbg("[AMP " .. a .. "] Output " .. o .. " -> Source " .. src .. " (pin)")
      end
    end
  end
end

-- Poll timer
pollTimer.EventHandler = function()
  PollAllAmps()
end

-- Poll rate change
if Controls.PollRate then
  Controls.PollRate.EventHandler = function(ctrl)
    pollTimer:Stop()
    local rate = math.max(1, ctrl.Value)
    pollTimer:Start(rate)
    dbg("[POLL] Rate: " .. rate .. "s")
  end
end

---------------------------------------------------------------
-- Initialize
---------------------------------------------------------------
Timer.CallAfter(function()
  dbg("[INIT] L'Acoustics LA7.16 Source Router v" .. (PluginInfo.Version or "?"))

  SetSelectedSource(0)

  -- Connect all configured amps
  for a = 1, ampCount do
    ConnectAmp(a)
  end

  -- Start polling
  local rate = (Controls.PollRate and Controls.PollRate.Value) or 2
  rate = math.max(1, rate)
  pollTimer:Start(rate)
  dbg("[INIT] Polling at " .. rate .. "s")
end, 0.5)

end -- if Controls

--[[Copyright 2026 Riley Watson
Permission is hereby granted, free of charge, to any person obtaining a copy of this software
and associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all copies or substantial
portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.]]
