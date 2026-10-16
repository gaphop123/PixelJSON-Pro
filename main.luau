--[[
    PixelJSON Pro — Luau Decoder, Validator & Renderer
    Version 2.0

    Stable API:
        PixelJSON.Decode(jsonString, options) → data, err
        PixelJSON.Validate(data, options) → ok, err
        PixelJSON.Render(data, options) → handle, err
        PixelJSON.LoadJSONFromURL(url, options, callback)
        PixelJSON.Destroy(handle)

    Designed for Roblox Studio, published experiences, and compatible executors.
    Does not invent unsupported APIs. Respects HTTP permissions and instance budgets.
]]

local PixelJSON = {}
PixelJSON._VERSION = "2.0.0"
PixelJSON._FORMAT = "PixelJSON"

-- Optional services (graceful when unavailable)
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

--------------------------------------------------------------------------------
-- Defaults & Limits
--------------------------------------------------------------------------------
local DEFAULTS = {
    MaxPixels = 50000,
    MaxPaletteSize = 256,
    MaxDownloadBytes = 16 * 1024 * 1024,
    Timeout = 30,
    MaxInstances = 15000,            -- lower default to reduce lag
    Scale = 1,
    Parent = nil,
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 1,
    UseRunRectangles = true,
    AllowDownsample = true,
    DownsampleThreshold = 12000,     -- switch to downsample earlier
    YieldEvery = 400,                -- instances between task.wait() yields
}

--------------------------------------------------------------------------------
-- Utility
--------------------------------------------------------------------------------
local function isPositiveInteger(n)
    return type(n) == "number" and n == math.floor(n) and n > 0
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do
        r[k] = deepCopy(v)
    end
    return r
end

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------
function PixelJSON.Validate(data, options)
    options = options or {}
    local maxPixels = options.MaxPixels or DEFAULTS.MaxPixels
    local maxPalette = options.MaxPaletteSize or DEFAULTS.MaxPaletteSize

    if type(data) ~= "table" then
        return false, "Data must be a table"
    end

    if data.format ~= PixelJSON._FORMAT then
        return false, "Invalid format identifier (expected 'PixelJSON')"
    end

    local version = data.version
    if version ~= 1 and version ~= 2 then
        return false, "Unsupported version: " .. tostring(version)
    end

    if not isPositiveInteger(data.width) or not isPositiveInteger(data.height) then
        return false, "width and height must be positive integers"
    end

    local totalPixels = data.width * data.height
    if totalPixels > maxPixels then
        return false, string.format("Image exceeds MaxPixels limit (%d > %d)", totalPixels, maxPixels)
    end

    if type(data.palette) ~= "table" then
        return false, "palette must be an array"
    end

    local paletteSize = #data.palette
    if paletteSize == 0 then
        return false, "palette cannot be empty"
    end
    if paletteSize > maxPalette then
        return false, string.format("palette size exceeds limit (%d > %d)", paletteSize, maxPalette)
    end

    for i, entry in ipairs(data.palette) do
        if type(entry) ~= "table" or #entry < 3 then
            return false, "Invalid palette entry at index " .. i
        end
        for c = 1, math.min(4, #entry) do
            local v = entry[c]
            if type(v) ~= "number" or v < 0 or v > 255 or v ~= math.floor(v) then
                return false, "Palette channel out of range at index " .. i
            end
        end
    end

    local encoding = data.encoding or "palette-rle"
    local supported = {
        ["palette-rle"] = true,
        ["row-rle"] = true,
        ["raw-rgba"] = true,
        ["delta"] = true,
        ["bitpack"] = true,
    }
    if not supported[encoding] then
        return false, "Unsupported encoding: " .. tostring(encoding)
    end

    if type(data.pixels) ~= "table" then
        return false, "pixels must be an array"
    end

    -- Light structural check; full decode-time count is performed in Decode
    if encoding == "raw-rgba" then
        local expected = totalPixels * 4
        if #data.pixels < expected then
            return false, "raw-rgba pixel array too short"
        end
    end

    return true, nil
end

--------------------------------------------------------------------------------
-- Decode
--------------------------------------------------------------------------------
function PixelJSON.Decode(jsonString, options)
    options = options or {}

    if type(jsonString) ~= "string" then
        return nil, "Input must be a JSON string"
    end

    if #jsonString > (options.MaxDownloadBytes or DEFAULTS.MaxDownloadBytes) * 2 then
        -- rough guard; real size limit applied on network path
        return nil, "JSON string exceeds size limit"
    end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(jsonString)
    end)

    if not ok then
        return nil, "JSON decode failed: " .. tostring(data)
    end

    local valid, err = PixelJSON.Validate(data, options)
    if not valid then
        return nil, err
    end

    -- Expand RLE / other encodings into a flat RGBA buffer for convenience
    -- (Render can also work directly from runs for efficiency)
    local width = data.width
    local height = data.height
    local total = width * height
    local encoding = data.encoding or "palette-rle"
    local palette = data.palette
    local pixels = data.pixels

    local rgba = table.create(total * 4)
    local idx = 1

    if encoding == "raw-rgba" then
        for i = 1, total * 4 do
            rgba[i] = pixels[i] or 0
        end
    elseif encoding == "palette-rle" or encoding == "row-rle" then
        local px = 1
        local i = 1
        while i <= #pixels and px <= total do
            local runLen = pixels[i]
            local palIdx = pixels[i + 1]
            i = i + 2

            if type(runLen) ~= "number" or runLen < 1 or runLen ~= math.floor(runLen) then
                return nil, "Invalid run length"
            end
            if type(palIdx) ~= "number" or palIdx < 0 or palIdx >= #palette or palIdx ~= math.floor(palIdx) then
                return nil, "Invalid palette index in RLE stream"
            end

            -- Enforce row boundaries for safety (row-rle is stricter)
            local remainingInRow = width - ((px - 1) % width)
            if runLen > remainingInRow and encoding == "row-rle" then
                return nil, "RLE run crosses row boundary (row-rle)"
            end

            local color = palette[palIdx + 1] -- Luau 1-based
            local r = color[1] or 0
            local g = color[2] or 0
            local b = color[3] or 0
            local a = color[4] or 255

            for _ = 1, runLen do
                if px > total then break end
                rgba[idx] = r
                rgba[idx + 1] = g
                rgba[idx + 2] = b
                rgba[idx + 3] = a
                idx = idx + 4
                px = px + 1
            end
        end

        if px - 1 ~= total then
            return nil, string.format("Decoded pixel count mismatch (%d != %d)", px - 1, total)
        end
    else
        -- Fallback: treat as palette indices (no runs)
        if #pixels < total then
            return nil, "Not enough palette indices"
        end
        for p = 1, total do
            local palIdx = pixels[p]
            if type(palIdx) ~= "number" or palIdx < 0 or palIdx >= #palette then
                return nil, "Invalid palette index"
            end
            local color = palette[palIdx + 1]
            rgba[idx] = color[1] or 0
            rgba[idx + 1] = color[2] or 0
            rgba[idx + 2] = color[3] or 0
            rgba[idx + 3] = color[4] or 255
            idx = idx + 4
        end
    end

    data._rgba = rgba -- internal expanded buffer
    data._decoded = true
    return data, nil
end

--------------------------------------------------------------------------------
-- Renderer
--------------------------------------------------------------------------------
--[[
    options = {
        Parent = Instance,          -- required for visible output
        MaxPixels = number,         -- default 50000
        MaxInstances = number,      -- default 15000 (lower = less lag)
        Scale = number,
        Offset = UDim2,
        UseRunRectangles = bool,
        AllowDownsample = bool,
        BackgroundColor3 = Color3,
        BackgroundTransparency = number,
        YieldEvery = number,        -- yield every N instances (default 400)
    }
    Returns: handle table or nil, error string

    handle methods:
        handle:Stop()     -- cancel in-progress or finished render, free instances
        handle:Destroy()  -- same as Stop (alias)
]]
function PixelJSON.Render(data, options)
    options = options or {}
    local parent = options.Parent
    if not parent then
        return nil, "Render options.Parent is required"
    end

    local valid, err = PixelJSON.Validate(data, options)
    if not valid then
        return nil, err
    end

    local width = data.width
    local height = data.height
    local total = width * height
    local maxInst = options.MaxInstances or DEFAULTS.MaxInstances
    local scale = math.max(1, math.floor(options.Scale or DEFAULTS.Scale))
    local useRuns = options.UseRunRectangles ~= false
    local allowDown = options.AllowDownsample ~= false
    local yieldEvery = options.YieldEvery or DEFAULTS.YieldEvery

    -- Prefer cheap strategies first to reduce lag
    local strategy = "pixels"
    local effectiveW, effectiveH = width, height
    local blockSize = 1

    if useRuns and (data.encoding == "palette-rle" or data.encoding == "row-rle") then
        strategy = "runs"
    end
    if (total > (options.DownsampleThreshold or DEFAULTS.DownsampleThreshold) or total > maxInst) and allowDown then
        blockSize = math.max(1, math.ceil(math.sqrt(total / math.max(1, maxInst))))
        effectiveW = math.ceil(width / blockSize)
        effectiveH = math.ceil(height / blockSize)
        strategy = "downsample"
    end

    local container = Instance.new("Frame")
    container.Name = "PixelJSONImage"
    container.BackgroundColor3 = options.BackgroundColor3 or DEFAULTS.BackgroundColor3
    container.BackgroundTransparency = options.BackgroundTransparency or DEFAULTS.BackgroundTransparency
    container.BorderSizePixel = 0
    container.Size = UDim2.fromOffset(width * scale, height * scale)
    container.ClipsDescendants = true
    if options.Offset then
        container.Position = options.Offset
    end
    container.Parent = parent

    local stopped = false
    local instanceCount = 0
    local sinceYield = 0

    local handle = {
        Container = container,
        Width = width,
        Height = height,
        Scale = scale,
        Strategy = strategy,
        Done = false,
        Stopped = false,
    }

    local function stopInternal()
        if stopped then return end
        stopped = true
        handle.Stopped = true
        handle.Done = true
        -- Fast path: destroying the container removes all children in one shot
        if container then
            pcall(function()
                container:Destroy()
            end)
        end
        handle.Container = nil
    end

    handle.Stop = function()
        stopInternal()
    end
    handle.Destroy = function()
        stopInternal()
    end

    local function addFrame(frame)
        if stopped then
            frame:Destroy()
            return false
        end
        instanceCount += 1
        if instanceCount > maxInst then
            frame:Destroy()
            return false
        end
        frame.Parent = container
        sinceYield += 1
        if sinceYield >= yieldEvery then
            sinceYield = 0
            task.wait() -- yield so the game stays responsive
            if stopped then
                return false
            end
        end
        return true
    end

    -- Expand or use existing RGBA (only needed for non-run strategies)
    local rgba = data._rgba
    if strategy ~= "runs" then
        if not rgba then
            local decoded, dErr = PixelJSON.Decode(HttpService:JSONEncode(data), options)
            if not decoded then
                stopInternal()
                return nil, dErr
            end
            rgba = decoded._rgba
        end
    end

    local function colorFromRGBA(offset)
        local r = rgba[offset] or 0
        local g = rgba[offset + 1] or 0
        local b = rgba[offset + 2] or 0
        local a = rgba[offset + 3] or 255
        return Color3.fromRGB(r, g, b), 1 - (a / 255)
    end

    if strategy == "runs" and data.pixels then
        local px = 0
        local i = 1
        local pixels = data.pixels
        local palette = data.palette

        while i <= #pixels and px < total do
            if stopped then break end
            local runLen = pixels[i]
            local palIdx = pixels[i + 1]
            i = i + 2
            if type(runLen) ~= "number" or runLen < 1 then break end

            local color = palette[palIdx + 1]
            local r = color[1] or 0
            local g = color[2] or 0
            local b = color[3] or 0
            local a = color[4] or 255
            local transparency = 1 - (a / 255)

            local remaining = runLen
            while remaining > 0 and px < total do
                if stopped then break end
                local row = math.floor(px / width)
                local col = px % width
                local room = width - col
                local thisRun = math.min(remaining, room)

                local frame = Instance.new("Frame")
                frame.BorderSizePixel = 0
                frame.BackgroundColor3 = Color3.fromRGB(r, g, b)
                frame.BackgroundTransparency = transparency
                frame.Size = UDim2.fromOffset(thisRun * scale, scale)
                frame.Position = UDim2.fromOffset(col * scale, row * scale)

                if not addFrame(frame) then
                    if not stopped then
                        warn("[PixelJSON] Instance budget reached during run rendering")
                    end
                    break
                end

                px += thisRun
                remaining -= thisRun
            end
        end
    elseif strategy == "downsample" then
        for by = 0, effectiveH - 1 do
            if stopped then break end
            for bx = 0, effectiveW - 1 do
                if stopped then break end
                local sumR, sumG, sumB, sumA, count = 0, 0, 0, 0, 0
                for dy = 0, blockSize - 1 do
                    for dx = 0, blockSize - 1 do
                        local sx = bx * blockSize + dx
                        local sy = by * blockSize + dy
                        if sx < width and sy < height then
                            local off = ((sy * width + sx) * 4) + 1
                            sumR += rgba[off] or 0
                            sumG += rgba[off + 1] or 0
                            sumB += rgba[off + 2] or 0
                            sumA += rgba[off + 3] or 255
                            count += 1
                        end
                    end
                end
                if count > 0 then
                    local frame = Instance.new("Frame")
                    frame.BorderSizePixel = 0
                    frame.BackgroundColor3 = Color3.fromRGB(
                        math.floor(sumR / count + 0.5),
                        math.floor(sumG / count + 0.5),
                        math.floor(sumB / count + 0.5)
                    )
                    frame.BackgroundTransparency = 1 - ((sumA / count) / 255)
                    frame.Size = UDim2.fromOffset(blockSize * scale, blockSize * scale)
                    frame.Position = UDim2.fromOffset(bx * blockSize * scale, by * blockSize * scale)
                    if not addFrame(frame) then break end
                end
            end
        end
    else
        for y = 0, height - 1 do
            if stopped then break end
            for x = 0, width - 1 do
                if stopped then break end
                local off = ((y * width + x) * 4) + 1
                local col3, trans = colorFromRGBA(off)
                if trans < 0.99 then
                    local frame = Instance.new("Frame")
                    frame.BorderSizePixel = 0
                    frame.BackgroundColor3 = col3
                    frame.BackgroundTransparency = trans
                    frame.Size = UDim2.fromOffset(scale, scale)
                    frame.Position = UDim2.fromOffset(x * scale, y * scale)
                    if not addFrame(frame) then
                        if not stopped then
                            warn("[PixelJSON] Instance budget reached")
                        end
                        break
                    end
                end
            end
        end
    end

    handle.Done = true
    handle.InstanceCount = instanceCount

    if stopped then
        return nil, "Render stopped"
    end

    return handle, nil
end

function PixelJSON.Destroy(handle)
    if type(handle) ~= "table" then return end
    if handle.Stop then
        handle:Stop()
        return
    end
    -- Fallback for older handles
    if handle.Container then
        pcall(function()
            handle.Container:Destroy()
        end)
    end
    handle.Container = nil
    handle.Instances = nil
    handle.Stopped = true
    handle.Done = true
end

-- Convenience alias
PixelJSON.Stop = PixelJSON.Destroy

--------------------------------------------------------------------------------
-- Remote JSON loading
--------------------------------------------------------------------------------
--[[
    PixelJSON.LoadJSONFromURL(url, options, callback)
    options = {
        MaxBytes = number,
        Timeout = number,          -- seconds (best-effort)
        Headers = table,
    }
    callback(err, data)  -- data is already decoded & validated
]]
function PixelJSON.LoadJSONFromURL(url, options, callback)
    options = options or {}
    if type(callback) ~= "function" then
        error("LoadJSONFromURL requires a callback function", 2)
    end

    if type(url) ~= "string" or #url < 8 then
        callback("Invalid URL", nil)
        return
    end

    -- Basic protocol check
    local lower = string.lower(url)
    if not (string.sub(lower, 1, 8) == "https://" or string.sub(lower, 1, 7) == "http://") then
        callback("Only http/https URLs are supported", nil)
        return
    end

    local maxBytes = options.MaxBytes or DEFAULTS.MaxDownloadBytes

    -- Prefer HttpService:RequestAsync when available (Studio / future)
    -- Fallback patterns for different environments are documented; we use the safest common path.
    local success, result = pcall(function()
        -- Roblox standard path
        local response = HttpService:RequestAsync({
            Url = url,
            Method = "GET",
            Headers = options.Headers or {},
        })
        return response
    end)

    if not success then
        -- Some executors expose different HTTP APIs. We do not guess or bypass.
        callback("HTTP request failed or is not permitted in this environment: " .. tostring(result), nil)
        return
    end

    if not result.Success then
        callback(string.format("HTTP %s: %s", tostring(result.StatusCode), tostring(result.StatusMessage)), nil)
        return
    end

    local body = result.Body
    if type(body) ~= "string" then
        callback("Empty or non-string response body", nil)
        return
    end

    if #body > maxBytes then
        callback(string.format("Response exceeds MaxBytes (%d > %d)", #body, maxBytes), nil)
        return
    end

    local data, err = PixelJSON.Decode(body, options)
    if not data then
        callback(err, nil)
        return
    end

    callback(nil, data)
end

--------------------------------------------------------------------------------
-- UI Library adapters (framework-agnostic examples)
--------------------------------------------------------------------------------
--[[
    These are reference patterns, not hard dependencies.
    Callers supply their own UI instances and wire the callbacks.
]]

function PixelJSON.CreateButtonAdapter(button, targetFrame, options)
    options = options or {}
    local currentHandle = nil

    local function onClick()
        -- Example: assume button has a StringValue or attribute holding JSON
        local json = button:GetAttribute("PixelJSON") or ""
        if json == "" then
            warn("[PixelJSON] No JSON data on button")
            return
        end

        if currentHandle then
            PixelJSON.Destroy(currentHandle)
            currentHandle = nil
        end

        local data, err = PixelJSON.Decode(json, options)
        if not data then
            warn(err)
            return
        end

        local handle, rErr = PixelJSON.Render(data, {
            Parent = targetFrame,
            MaxPixels = options.MaxPixels or DEFAULTS.MaxPixels,
            Scale = options.Scale or 1,
        })
        if handle then
            currentHandle = handle
        else
            warn(rErr)
        end
    end

    if button:IsA("TextButton") or button:IsA("ImageButton") then
        button.MouseButton1Click:Connect(onClick)
    end

    return {
        Destroy = function()
            if currentHandle then
                PixelJSON.Destroy(currentHandle)
            end
        end,
    }
end

--------------------------------------------------------------------------------
-- Module export
--------------------------------------------------------------------------------
return PixelJSON
