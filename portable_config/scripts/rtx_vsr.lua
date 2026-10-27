--[[
  @name NVIDIA RTX Video Super Resolution (VSR)
  @description Dynamically manages native D3D11 NVIDIA RTX Video Super Resolution (@rtx_vsr:d3d11vpp)
               at Quality Level 4 (Ultra) via NVAPI for sub-native streams while preserving aspect
               ratios and coordinating with Shift+R direct vf toggle, Anime4K shaders, SVP, and CPU filters.
  @version 1.2
  @author Stremio-Kai
--]]
-- luacheck: read globals mp

local mp = require("mp")

local FILTER_LABEL = "rtx_vsr"
local VSR_TARGET_QUALITY = 4 -- Quality 4 (Ultra / Max Quality)

local state = {
    user_enabled = true,
    manual_override = false,
    force_over_anime4k = false,
    active = false,
    current_scale_str = nil,
    current_quality = VSR_TARGET_QUALITY,
    nvapi_quality_enforced = false,
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

-- Enforce NVIDIA RTX VSR Quality Level 4 (Ultra) directly in the NVIDIA driver via NVAPI (LuaJIT FFI)
local nvapi_ctx = nil

local function init_nvapi()
    if nvapi_ctx ~= nil then
        return nvapi_ctx
    end

    local ok, ctx = pcall(function()
        local ffi = require("ffi")
        ffi.cdef[[
            void* nvapi_QueryInterface(uint32_t id);
            typedef int (*NvAPI_Initialize_t)(void);
            typedef int (*NvAPI_EnumNvidiaDisplayHandle_t)(uint32_t thisEnum, void** pNvDispHandle);
            typedef int (*NvAPI_GetVideoState_t)(void* hNvDisplay, void* pGetComp);
            typedef int (*NvAPI_SetVideoState_t)(void* hNvDisplay, void* pSetComp);
            int __stdcall GetSystemMetrics(int nIndex);
        ]]

        local nvapi = ffi.load("nvapi64.dll")
        local init_fn = ffi.cast("NvAPI_Initialize_t", nvapi.nvapi_QueryInterface(0x0150E828))
        local enum_disp_fn = ffi.cast("NvAPI_EnumNvidiaDisplayHandle_t", nvapi.nvapi_QueryInterface(0x9ABDD40D))
        local get_video_fn = ffi.cast("NvAPI_GetVideoState_t", nvapi.nvapi_QueryInterface(0x0B6EF8B9))
        local set_video_fn = ffi.cast("NvAPI_SetVideoState_t", nvapi.nvapi_QueryInterface(0x9321CA5B))

        if init_fn == nil or enum_disp_fn == nil or get_video_fn == nil or set_video_fn == nil then
            return false
        end

        if init_fn() ~= 0 then
            return false
        end

        return {
            ffi = ffi,
            enum_disp = enum_disp_fn,
            get_video = get_video_fn,
            set_video = set_video_fn,
        }
    end)

    if ok and ctx then
        nvapi_ctx = ctx
    else
        nvapi_ctx = false
        log_verbose("NVAPI interface unavailable: " .. tostring(ctx))
    end

    return nvapi_ctx
end

local function enforce_vsr_quality_level(quality_level)
    if is_headless() then return false end
    local ctx = init_nvapi()
    if not ctx then
        return false
    end

    local ok, applied_quality = pcall(function()
        local ffi = ctx.ffi
        local h_disp = ffi.new("void*[1]")
        local verified_level = nil

        for disp_idx = 0, 7 do
            if ctx.enum_disp(disp_idx, h_disp) ~= 0 or h_disp[0] == nil then
                break
            end

            -- 1. Disable SuperResolution Auto mode (componentId = 36) so quality stays locked at Level 4
            local set_auto = ffi.new("uint32_t[16]")
            set_auto[0] = 0x00010040 -- _NVAPI_SET_VIDEO_STATE_COMPONENT_EX v1 (64 bytes)
            set_auto[1] = 36         -- componentId = 36 (_User_Global_VAL_SuperResolution_Auto)
            set_auto[2] = 0          -- deviceIndex = 0 (global)
            set_auto[3] = 1          -- bIsTopPriority = 1
            set_auto[4] = 0          -- enable = 0 (Auto OFF)
            set_auto[5] = 0          -- setToAlgo = 0
            ctx.set_video(h_disp[0], set_auto)

            -- 2. Enable SuperResolution and set Quality Level 4 (componentId = 29)
            local set_vsr = ffi.new("uint32_t[16]")
            set_vsr[0] = 0x00010040  -- _NVAPI_SET_VIDEO_STATE_COMPONENT_EX v1 (64 bytes)
            set_vsr[1] = 29          -- componentId = 29 (_User_Global_VAL_SuperResolution)
            set_vsr[2] = 0           -- deviceIndex = 0 (global)
            set_vsr[3] = 1           -- bIsTopPriority = 1
            set_vsr[4] = 1           -- enable = 1 (VSR ON)
            set_vsr[5] = quality_level -- setToAlgo = 4 (Quality Level 4 Ultra)
            ctx.set_video(h_disp[0], set_vsr)

            -- 3. Read back active driver state to verify Quality Level 4
            local get_vsr = ffi.new("uint32_t[32]")
            get_vsr[0] = 0x00010080  -- _NVAPI_GET_VIDEO_STATE_COMPONENT_EX v1 (128 bytes)
            get_vsr[1] = 29
            get_vsr[2] = 0
            if ctx.get_video(h_disp[0], get_vsr) == 0 then
                verified_level = tonumber(get_vsr[22]) -- offset 0x58 = lastAlgoSet
            end
        end

        return verified_level
    end)

    if ok and applied_quality then
        state.current_quality = applied_quality
        if not state.nvapi_quality_enforced then
            state.nvapi_quality_enforced = true
            log(string.format("NVAPI: Locked NVIDIA RTX VSR to Quality Level %d (Ultra)", applied_quality))
        end
        return true
    end

    return false
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
end

-- Core evaluation loop
local function evaluate_vsr(refresh_osd)
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

    -- 6. Ensure NVIDIA driver VSR Quality Level 4 (Ultra) is enforced via NVAPI before activating filter
    enforce_vsr_quality_level(VSR_TARGET_QUALITY)

    local scale_str = format_scale_ratio(ratio)
    local filter_spec = string.format("@%s:d3d11vpp=scaling-mode=nvidia:scale=%s", FILTER_LABEL, scale_str)

    -- 7. Check if @rtx_vsr is already present with the exact scale and positioned after any CPU filters
    local current_scale = vsr_entry and vsr_entry.params and vsr_entry.params.scale
    local needs_reorder = vsr_index and has_cpu_filter and (vsr_index < last_cpu_index)

    if vsr_index and current_scale == scale_str and not needs_reorder and vsr_entry.enabled ~= false then
        state.active = true
        state.current_scale_str = scale_str
        state.last_reason = desc
        if refresh_osd then
            mp.command('show-text "RTX VSR: ${vf}" 3000')
        end
        return
    end

    -- 8. Apply or update @rtx_vsr at the tail of the VF chain
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
    log(string.format("Applied %s [Quality %d Ultra] (%s)", filter_spec, state.current_quality, desc))

    if refresh_osd then
        mp.command('show-text "RTX VSR: ${vf}" 3000')
    end
end

-- Toggle handler for script-binding / script-message
local function toggle_vsr()
    mp.command('vf toggle @rtx_vsr:d3d11vpp=scaling-mode=nvidia ; show-text "RTX VSR: ${vf}" 3000')
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

    -- Detect direct user toggle via Shift+R (`vf toggle @rtx_vsr:d3d11vpp=scaling-mode=nvidia`)
    if state.active and not vsr_present then
        state.user_enabled = false
        state.manual_override = false
        state.force_over_anime4k = false
        state.active = false
        state.current_scale_str = nil
        state.last_reason = "Disabled by user"
        log("Disabled @rtx_vsr via user hotkey toggle")
        return
    elseif vsr_present and (not state.user_enabled or not state.active or not (vsr_entry.params and vsr_entry.params.scale)) then
        state.user_enabled = true
        state.manual_override = true
        state.nvapi_quality_enforced = false
        if has_anime4k_upscaler() then
            state.force_over_anime4k = true
            clear_anime4k_shaders()
        end
        evaluate_vsr(true)
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
    state.nvapi_quality_enforced = false
    state.profile_resetting = false
    state.last_reason = "Loading"
end)

-- Coordinate with profile-manager.lua clean-slate resets
mp.register_script_message("profile-begin", function()
    state.profile_resetting = true
    state.active = false
    state.current_scale_str = nil
end)

mp.register_script_message("profile-end", function()
    state.profile_resetting = false
    evaluate_vsr(false)
end)

-- Register keybind and script messages
mp.add_key_binding(nil, "toggle-vsr", toggle_vsr)
mp.register_script_message("toggle-rtx-vsr", toggle_vsr)
mp.register_script_message("rtx-vsr-toggle", toggle_vsr)

log("Loaded NVIDIA RTX Video Super Resolution controller (Target: Quality Level 4 Ultra)")
