--[[
  @name NVIDIA RTX Video Super Resolution (VSR)
  @description Dynamically manages native D3D11 NVIDIA RTX Video Super Resolution (@rtx_vsr:d3d11vpp=scaling-mode=nvidia)
               for sub-native streams with quality controlled natively by the NVIDIA driver (Control Panel / NVIDIA App)
               while preserving aspect ratios and coordinating with Shift+R clean OSD toggle, Anime4K shaders, SVP, and CPU filters.
  @version 1.3
  @author Stremio-Kai
--]]
-- luacheck: read globals mp

local mp = require("mp")

local FILTER_LABEL = "rtx_vsr"

local state = {
    user_enabled = true,
    manual_override = false,
    force_over_anime4k = false,
    active = false,
    current_scale_str = nil,
    last_reason = "Initializing",
    internal_vf_op = false,
    internal_shader_op = false,
    profile_resetting = false,
    last_shader_had_anime4k = false,
}

local function log(msg)
    mp.msg.info("[rtx-vsr] " .. msg)
end

local function log_verbose(msg)
    mp.msg.verbose("[rtx-vsr] " .. msg)
end

-- Check if running in a headless / thumbnailer / encoding mpv instance
local function is_headless()
    local vo = mp.get_property("vo") or ""
    local ovc = mp.get_property("ovc") or ""
    local vid = mp.get_property("vid") or ""
    if vo == "null" or vo == "image" or ovc ~= "" or vid == "no" then
        return true
    end
    return false
end

-- Show clean OSD notification without dumping raw filter chains
local function show_osd_status(enabled)
    local msg = enabled and "RTX VSR Enabled" or "RTX VSR Disabled"
    mp.osd_message(msg, 2)
end

-- Format scale ratio cleanly (e.g., 2.0, 1.3333, 1.5)
local function format_scale_ratio(ratio)
    local rounded_int = math.floor(ratio + 0.5)
    if math.abs(ratio - rounded_int) < 0.0001 then
        return string.format("%.1f", rounded_int)
    end
    local s = string.format("%.4f", ratio)
    s = s:gsub("(%..-)0+$", "%1")
    s = s:gsub("%.$", ".0")
    return s
end

-- Inspect active GLSL shaders for Anime4K upscalers
local function has_anime4k_upscaler()
    local shaders = mp.get_property_native("glsl-shaders") or {}
    for _, shader in ipairs(shaders) do
        local s = tostring(shader):lower()
        if s:find("anime4k_upscale", 1, true) or s:find("anime4k_autodownscalepre", 1, true) or s:find("anime4k_restore", 1, true) then
            return true
        end
    end
    return false
end

-- Remove Anime4K shaders when user explicitly forces RTX VSR on over Anime4K
local function clear_anime4k_shaders()
    local shaders = mp.get_property_native("glsl-shaders") or {}
    if #shaders == 0 then return false end

    local filtered = {}
    local removed = false
    for _, shader in ipairs(shaders) do
        if tostring(shader):lower():find("anime4k", 1, true) then
            removed = true
        else
            table.insert(filtered, shader)
        end
    end

    if removed then
        state.internal_shader_op = true
        mp.set_property_native("glsl-shaders", filtered)
        state.internal_shader_op = false
        log("Cleared active Anime4K shaders due to manual RTX VSR override")
    end
    return removed
end

-- Query monitor display dimensions with fallback to OSD bounds and Win32 GetSystemMetrics
local function get_display_bounds()
    local dw = mp.get_property_number("display-width")
    local dh = mp.get_property_number("display-height")

    if not dw or not dh or dw <= 0 or dh <= 0 then
        local osd = mp.get_property_native("osd-dimensions")
        if osd and osd.w and osd.h and osd.w > 0 and osd.h > 0 then
            dw = osd.w
            dh = osd.h
        else
            dw = mp.get_property_number("osd-width")
            dh = mp.get_property_number("osd-height")
        end
    end

    if not dw or not dh or dw <= 0 or dh <= 0 then
        pcall(function()
            local ffi = require("ffi")
            ffi.cdef[[ int __stdcall GetSystemMetrics(int nIndex); ]]
            local user32 = ffi.load("user32")
            local sm_w = user32.GetSystemMetrics(0)
            local sm_h = user32.GetSystemMetrics(1)
            if sm_w > 0 and sm_h > 0 then
                dw = sm_w
                dh = sm_h
            end
        end)
    end

    if dw and dh and dw > 0 and dh > 0 then
        return dw, dh
    end
    return nil, nil
end

-- Query pre-filter source video dimensions and display-aspect-corrected dimensions
local function get_video_bounds()
    local params = mp.get_property_native("video-dec-params")
    if not params or not params.w or not params.h or params.w <= 0 or params.h <= 0 then
        params = mp.get_property_native("video-params")
    end
    if not params or not params.w or not params.h or params.w <= 0 or params.h <= 0 then
        return nil
    end

    local w = params.w
    local h = params.h
    local dw = params.dw or w
    local dh = params.dh or h

    -- Handle rotated video metadata (90/270 deg)
    local rotate = params.rotate or 0
    if rotate % 180 == 90 then
        w, h = h, w
        dw, dh = dh, dw
    end

    return {
        w = w,
        h = h,
        dw = dw,
        dh = dh,
    }
end

-- Compute VSR scale ratio while handling letterboxed / wide aspect ratios without stretching
local function calculate_vsr_scale(video, disp_w, disp_h, allow_manual_fallback)
    -- Ensure mpv preserves aspect ratio so letterboxed streams are never stretched
    if mp.get_property_bool("keepaspect") == false then
        mp.set_property_bool("keepaspect", true)
    end

    local vw = video.w
    local vh = video.h
    local dar_w = video.dw
    local dar_h = video.dh

    -- Bypass if video height or display-aspect width matches or exceeds monitor bounds (unless manually forced via Shift+R)
    if vh >= disp_h or vw >= disp_w or dar_h >= disp_h or dar_w >= disp_w then
        if allow_manual_fallback and vh < 2160 then
            local manual_ratio = (vh <= 1080) and (1440 / vh) or 1.5
            local even_h = math.floor((vh * manual_ratio) / 2) * 2
            manual_ratio = even_h / vh
            return manual_ratio, string.format("%dx%d → %dx%d (Manual)", vw, vh, math.floor(vw * manual_ratio + 0.5), even_h)
        end
        return nil, string.format("Native/Above-Native (%dx%d on %dx%d)", vw, vh, disp_w, disp_h)
    end

    local disp_ar = disp_w / disp_h
    local video_ar = dar_w / dar_h

    -- Determine effective full-frame vertical height to prevent over-scaling letterboxed content
    local effective_h = vh
    if video_ar > (disp_ar + 0.01) then
        effective_h = dar_w / disp_ar
    end

    if effective_h >= disp_h then
        if allow_manual_fallback and vh < 2160 then
            local manual_ratio = 1.5
            local even_h = math.floor((vh * manual_ratio) / 2) * 2
            manual_ratio = even_h / vh
            return manual_ratio, string.format("%dx%d → %dx%d (Manual)", vw, vh, math.floor(vw * manual_ratio + 0.5), even_h)
        end
        return nil, string.format("Native Widescreen (%dx%d on %dx%d)", vw, vh, disp_w, disp_h)
    end

    local raw_ratio = disp_h / effective_h
    if raw_ratio <= 1.01 then
        return nil, string.format("Scale ~1.0x (%dx%d on %dx%d)", vw, vh, disp_w, disp_h)
    end

    -- Align target output height to even pixels (NV12 4:2:0 requirement in d3d11vpp)
    local scaled_h_round = math.floor(vh * raw_ratio + 0.5)
    local scaled_w_round = math.floor(vw * raw_ratio + 0.5)
    local final_ratio = raw_ratio

    if (scaled_h_round % 2 ~= 0) or (scaled_w_round % 2 ~= 0) then
        local even_h = math.floor((vh * raw_ratio) / 2) * 2
        if even_h > vh then
            final_ratio = even_h / vh
        end
    end

    return final_ratio, string.format("%dx%d → %dx%d", vw, vh, math.floor(vw * final_ratio + 0.5), math.floor(vh * final_ratio + 0.5))
end

-- Inspect current VF chain for @rtx_vsr and active CPU software filters (SVP/VapourSynth, enabled lavfi)
local function inspect_vf_chain()
    local vf_list = mp.get_property_native("vf") or {}
    local vsr_index = nil
    local vsr_entry = nil
    local has_cpu_filter = false
    local last_cpu_index = 0

    for i, filter in ipairs(vf_list) do
        local label = filter.label or ""
        local name = filter.name or ""
        if label == FILTER_LABEL then
            vsr_index = i
            vsr_entry = filter
        elseif filter.enabled ~= false then
            local lname = name:lower()
            local llabel = label:lower()
            if lname == "vapoursynth" or lname == "lavfi" or llabel:find("svp", 1, true) or llabel:find("hqdn3d", 1, true) or llabel:find("bwdif", 1, true) then
                has_cpu_filter = true
                last_cpu_index = i
            end
        end
    end

    return vf_list, vsr_index, vsr_entry, has_cpu_filter, last_cpu_index
end

-- Ensure hwdec mode matches filter graph needs:
-- - Zero-copy "d3d11va" when no enabled CPU software filters are in VF
-- - Copy-back "d3d11va-copy" when SVP/lavfi CPU filters are enabled
local function sync_hwdec_for_vf(has_cpu_filter)
    local current_hwdec = mp.get_property("hwdec") or ""
    if has_cpu_filter then
        if current_hwdec == "d3d11va" or current_hwdec == "auto" or current_hwdec == "auto-safe" then
            mp.set_property("hwdec", "d3d11va-copy")
            log("Enabled CPU filter (SVP/lavfi) detected in VF chain; switched hwdec to d3d11va-copy")
        end
    else
        if current_hwdec == "d3d11va-copy" or current_hwdec == "auto" or current_hwdec == "auto-safe" then
            mp.set_property("hwdec", "d3d11va")
            log("No enabled CPU filters in VF chain; enforced zero-copy hwdec=d3d11va")
        end
    end
end

-- Remove @rtx_vsr from the VF chain if present
local function remove_vsr_filter(reason)
    local _, vsr_index = inspect_vf_chain()
    if vsr_index then
        state.internal_vf_op = true
        mp.commandv("vf", "remove", "@" .. FILTER_LABEL)
        state.internal_vf_op = false
        log("Removed @rtx_vsr filter (" .. (reason or "bypassed") .. ")")
    end
    state.active = false
    state.current_scale_str = nil
    state.last_reason = reason or "Bypassed"
    mp.set_property_bool("user-data/rtx-vsr-active", false)
end

-- Core evaluation loop
local function evaluate_vsr(user_interactive)
    if state.internal_vf_op or state.profile_resetting or is_headless() then return end

    local _, vsr_index, vsr_entry, has_cpu_filter, last_cpu_index = inspect_vf_chain()
    sync_hwdec_for_vf(has_cpu_filter)

    -- 1. Check user toggle state
    if not state.user_enabled then
        remove_vsr_filter("Disabled by user")
        return
    end

    -- 2. Ensure GPU API is d3d11 (d3d11vpp requires gpu-api=d3d11)
    local gpu_api = mp.get_property("gpu-api") or "auto"
    if gpu_api ~= "d3d11" and gpu_api ~= "auto" then
        mp.set_property("gpu-api", "d3d11")
    end

    -- 3. Check Anime4K shader compatibility
    if has_anime4k_upscaler() and not state.force_over_anime4k then
        remove_vsr_filter("Yielding to active Anime4K shaders")
        return
    end

    -- 4. Check video parameters and display bounds
    local video = get_video_bounds()
    local disp_w, disp_h = get_display_bounds()
    if not video or not disp_w or not disp_h then
        log_verbose("Waiting for video parameters and display bounds...")
        return
    end

    -- 5. Calculate vertical scale ratio (with letterbox protection)
    local ratio, desc = calculate_vsr_scale(video, disp_w, disp_h, state.manual_override)
    if not ratio then
        remove_vsr_filter(desc)
        return
    end

    local scale_str = format_scale_ratio(ratio)
    local filter_spec = string.format("@%s:d3d11vpp=scaling-mode=nvidia:scale=%s", FILTER_LABEL, scale_str)

    -- 6. Check if @rtx_vsr is already present with the exact scale and positioned after any CPU filters
    local current_scale = vsr_entry and vsr_entry.params and vsr_entry.params.scale
    local needs_reorder = vsr_index and has_cpu_filter and (vsr_index < last_cpu_index)

    if vsr_index and current_scale == scale_str and not needs_reorder and vsr_entry.enabled ~= false then
        state.active = true
        state.current_scale_str = scale_str
        state.last_reason = desc
        mp.set_property_bool("user-data/rtx-vsr-active", true)
        return
    end

    -- 7. Apply or update @rtx_vsr at the tail of the VF chain
    state.internal_vf_op = true
    if needs_reorder then
        local vf_list = mp.get_property_native("vf") or {}
        local reordered = {}
        for i, f in ipairs(vf_list) do
            if f.label ~= FILTER_LABEL then
                if vsr_index and i > vsr_index and f.enabled == false and f.label ~= "blackdetect" then
                    f.enabled = true
                end
                table.insert(reordered, f)
            end
        end
        mp.set_property_native("vf", reordered)
        mp.commandv("vf", "append", filter_spec)
    else
        if vsr_index then
            mp.commandv("vf", "remove", "@" .. FILTER_LABEL)
        end
        mp.commandv("vf", "append", filter_spec)
    end
    state.internal_vf_op = false

    state.active = true
    state.current_scale_str = scale_str
    state.last_reason = desc
    mp.set_property_bool("user-data/rtx-vsr-active", true)
    log(string.format("Applied %s (%s) [Quality: Driver-Managed]", filter_spec, desc))
end

-- Toggle handler for script-binding / script-message
local function toggle_vsr()
    if is_headless() then return end

    if state.user_enabled and state.active then
        state.user_enabled = false
        state.manual_override = false
        state.force_over_anime4k = false
        remove_vsr_filter("Toggled off by user")
        mp.set_property_bool("user-data/rtx-vsr-active", false)
        mp.set_property_bool("user-data/rtx-vsr-disabled", true)
        show_osd_status(false)
        log("RTX VSR toggled OFF by user")
    else
        state.user_enabled = true
        state.manual_override = true
        mp.set_property_bool("user-data/rtx-vsr-disabled", false)
        if has_anime4k_upscaler() then
            state.force_over_anime4k = true
            clear_anime4k_shaders()
        end
        evaluate_vsr(true)
        if not state.active then
            -- Fallback direct append if evaluate_vsr didn't activate
            local _, vsr_index = inspect_vf_chain()
            if not vsr_index then
                state.internal_vf_op = true
                mp.commandv("vf", "append", "@" .. FILTER_LABEL .. ":d3d11vpp=scaling-mode=nvidia")
                state.internal_vf_op = false
            end
            state.active = true
            mp.set_property_bool("user-data/rtx-vsr-active", true)
        end
        show_osd_status(true)
        log("RTX VSR toggled ON by user")
    end
end

-- Observers for video parameters, display bounds, VF chain, and GLSL shaders
mp.observe_property("video-params", "native", function()
    evaluate_vsr(false)
end)

mp.observe_property("video-dec-params", "native", function()
    evaluate_vsr(false)
end)

mp.observe_property("display-height", "number", function()
    evaluate_vsr(false)
end)

mp.observe_property("display-width", "number", function()
    evaluate_vsr(false)
end)

mp.observe_property("vf", "native", function()
    if state.internal_vf_op or state.profile_resetting or is_headless() then return end

    local _, vsr_index, vsr_entry = inspect_vf_chain()
    local vsr_present = (vsr_index ~= nil) and (vsr_entry.enabled ~= false)

    -- Detect direct external toggle (e.g. from external commands)
    if state.active and not vsr_present then
        state.user_enabled = false
        state.manual_override = false
        state.force_over_anime4k = false
        state.active = false
        state.current_scale_str = nil
        state.last_reason = "Disabled externally"
        mp.set_property_bool("user-data/rtx-vsr-active", false)
        mp.set_property_bool("user-data/rtx-vsr-disabled", true)
        show_osd_status(false)
        log("Disabled @rtx_vsr via external toggle")
        return
    elseif vsr_present and (not state.user_enabled or not state.active) then
        state.user_enabled = true
        state.manual_override = true
        mp.set_property_bool("user-data/rtx-vsr-disabled", false)
        if has_anime4k_upscaler() then
            state.force_over_anime4k = true
            clear_anime4k_shaders()
        end
        evaluate_vsr(false)
        show_osd_status(true)
        return
    end

    evaluate_vsr(false)
end)

mp.observe_property("glsl-shaders", "native", function()
    if state.internal_shader_op or state.profile_resetting or is_headless() then return end
    local has_a4k = has_anime4k_upscaler()
    -- If Anime4K shaders were just toggled ON by the user or profile-manager, yield to Anime4K
    if has_a4k and not state.last_shader_had_anime4k then
        state.force_over_anime4k = false
        state.manual_override = false
    end
    state.last_shader_had_anime4k = has_a4k
    evaluate_vsr(false)
end)

mp.register_event("start-file", function()
    state.active = false
    state.current_scale_str = nil
    state.manual_override = false
    state.force_over_anime4k = false
    state.profile_resetting = false
    state.last_reason = "Loading"
    mp.set_property_bool("user-data/rtx-vsr-active", false)
end)

-- Coordinate with profile-manager.lua clean-slate resets
mp.register_script_message("profile-begin", function()
    state.profile_resetting = true
    state.active = false
    state.current_scale_str = nil
    mp.set_property_bool("user-data/rtx-vsr-active", false)
end)

mp.register_script_message("profile-end", function()
    state.profile_resetting = false
    evaluate_vsr(false)
end)

-- Register keybind and script messages
mp.add_key_binding(nil, "toggle-vsr", toggle_vsr)
mp.register_script_message("toggle-vsr", toggle_vsr)
mp.register_script_message("toggle-rtx-vsr", toggle_vsr)
mp.register_script_message("rtx-vsr-toggle", toggle_vsr)

log("Loaded NVIDIA RTX Video Super Resolution controller (Driver-Managed Quality)")
