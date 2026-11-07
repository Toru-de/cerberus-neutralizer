local VERSION = "0.2.0"
local QUEST_PATH = "ep1/quests/main_quest/q305_bunker"
local ROBOT_RECORD = "Character.q305_cerberus_robot"
local ATTACK_RECORD = "CerberusBoss.CerberusAttacks"
local ATTACK_FLAT = ATTACK_RECORD .. ".disableAction"
local SETTINGS_FILE = "settings.json"
local settings = { enabled = true, detection = true, attacks = false, hud = true, debug = false }

local SIGNAL_LOSS_DELAY = 0.6
local RETURN_NOTICE_DURATION = 2.5
local RETREAT_SPEED = 0.65
local RETREAT_DURATION = 0.4

local tracked = {}
local patrolPresets, chasePresets = {}, {}
local movementStims = {}
local robotRecord, activeQuestState
local overlay, ready, fault = false, false, nil
local attackAvailable, attackActive, ownsAttackFlat = false, false, false
local attackFault, stimulusFault, hudFault
local elapsed, pollSoon = 0, true
local status = "Waiting for CET"
local hud = {}

local function debugLog(message)
    if settings.debug then
        spdlog.info(message)
    end
end

local function setStatus(message)
    if status ~= message then
        status = message
        debugLog(message)
    end
end

local function loadSettings()
    local file = io.open(SETTINGS_FILE, "r")
    if not file then return end
    local data = file:read("*a")
    file:close()
    local ok, saved = pcall(json.decode, data)
    if not ok or type(saved) ~= "table" then
        spdlog.warn("Invalid settings.json. Using defaults.")
        return
    end
    for key in pairs(settings) do
        if type(saved[key]) == "boolean" then settings[key] = saved[key] end
    end
end

local function saveSettings()
    local data = json.encode(settings)
    local file, openError = io.open(SETTINGS_FILE, "w")
    if not file then
        spdlog.error("Could not save settings: " .. tostring(openError))
        return
    end
    local written, writeError = file:write(data, "\n")
    local closed, closeError = file:close()
    if not written or not closed then
        spdlog.error("Could not save settings: " .. tostring(writeError or closeError))
    end
end

local function isRobot(npc)
    return IsDefined(npc) and npc:IsA("NPCPuppet")
        and npc:GetRecordID() == robotRecord and npc:IsCerberus()
end

local function remember(npc)
    if not isRobot(npc) then return end
    local id = npc:GetEntityID()
    local key = tostring(id.hash) -- Keep all 64 bits of the entity ID as a string.
    if not tracked[key] then
        tracked[key] = { id = id, status = "Attached" }
        pollSoon = true
        debugLog("Attached " .. ROBOT_RECORD .. " [" .. key .. "]")
    end
end

local function setRobotStatus(slot, message)
    if slot.status ~= message then
        slot.status = message
        debugLog(tostring(slot.id.hash) .. " " .. message)
    end
end

local function restoreSensors(slot, senses)
    if IsDefined(senses) then
        if slot.ownsVision and not senses:IsEnabled() then senses:Toggle(true) end
        if slot.ownsHearing and not senses:IsHearingEnabled() then senses:SetHearingEnabled(true) end
    end
    slot.ownsVision = nil
    slot.ownsHearing = nil
    slot.resetFor = nil
end

local function suppressSensors(slot, senses, playerID)
    if senses:IsEnabled() then
        slot.ownsVision = true
        senses:Toggle(false)
    end
    if senses:IsHearingEnabled() then
        slot.ownsHearing = true
        senses:SetHearingEnabled(false)
    end
    local playerKey = tostring(playerID.hash)
    if slot.resetFor ~= playerKey then
        senses:ResetDetection(playerID)
        slot.resetFor = playerKey
    end
    local suppressed = not senses:IsEnabled() and not senses:IsHearingEnabled()
    setRobotStatus(slot, suppressed and "Sensors suppressed" or "Waiting for sensors to disable")
    return suppressed
end

local function writeAttackFlag(disabled)
    assert(TweakDB:SetFlats(ATTACK_RECORD, { disableAction = disabled }), "Could not update Cerberus attack action")
    assert(TweakDB:GetFlat(ATTACK_FLAT) == disabled, "Cerberus attack flag readback failed")
end

local function syncAttacks(wanted)
    if wanted and not attackActive then
        local original = TweakDB:GetFlat(ATTACK_FLAT)
        assert(type(original) == "boolean", "Attack flag is unavailable")
        if not original then
            ownsAttackFlat = true
            writeAttackFlag(true)
        end
        attackActive = true
        debugLog("Cerberus combat action disabled")
    elseif not wanted and (attackActive or ownsAttackFlat) then
        if ownsAttackFlat and TweakDB:GetFlat(ATTACK_FLAT) == true then
            writeAttackFlag(false)
        end
        attackActive, ownsAttackFlat = false, false
        debugLog("Cerberus combat action released")
    end
end

local function updateAttacks(wanted)
    local ok, reason = pcall(syncAttacks, wanted)
    if ok then return end
    attackAvailable = false
    if not attackFault then spdlog.error(tostring(reason)) end
    attackFault = tostring(reason)
    if wanted then pcall(syncAttacks, false) end
end

local function restoreRobot(slot, npc)
    if slot.ownsVision or slot.ownsHearing then
        if isRobot(npc) and npc:IsAttached() and not npc:IsDead() then
            restoreSensors(slot, npc:GetSensesComponent())
            return
        end
        -- A detached or dead actor has no live perception to restore.
        slot.ownsVision, slot.ownsHearing = nil, nil
    end
    slot.resetFor = nil
end

local function resetHud()
    if hud.id then hud = {} end
end

local function stopEffects()
    updateAttacks(false)
    resetHud()
    for _, slot in pairs(tracked) do
        if slot.ownsVision or slot.ownsHearing then
            local restored, reason = pcall(function()
                restoreRobot(slot, Game.FindEntityByID(slot.id))
            end)
            if not restored then spdlog.error(tostring(reason)) end
        else
            slot.resetFor = nil
        end
        slot.preset, slot.detection, slot.playerTier = nil, nil, nil
        setRobotStatus(slot, "Vanilla")
    end
end

local function fail(reason)
    if fault then return end
    fault = tostring(reason)
    spdlog.error(fault)
    setStatus("Suspended after an API error")
    stopEffects()
end

local function guarded(callback, ...)
    if fault then return end
    local ok, reason = pcall(callback, ...)
    if not ok then fail(reason) end
end

local function hasPreset(presets, preset)
    for _, id in ipairs(presets) do
        if id == preset then return true end
    end
    return false
end

local function isPatrolPreset(preset)
    return not hasPreset(chasePresets, preset) and hasPreset(patrolPresets, preset)
end

local function isGameplayTier(tier)
    -- gamePSMHighLevel tiers 1–3 allow gameplay. Tiers 4–5 are cinematic.
    return tier >= 1 and tier <= 3
end

local function checkRobot(slot, npc, playerID, playerTier)
    local senses = npc:GetSensesComponent()
    if npc:IsDead() then
        restoreRobot(slot, npc)
        setRobotStatus(slot, "Dead or deactivated")
        return false
    end
    if not IsDefined(senses) then
        setRobotStatus(slot, "Waiting for senses")
        return false
    end

    local preset = senses:GetCurrentPreset()
    -- Patrol animations also use workspots and may run in staged gameplay.
    local gameplay = isGameplayTier(playerTier)
    local eligible = gameplay and isPatrolPreset(preset)
    local suppressed = false
    if eligible and settings.detection then
        suppressed = suppressSensors(slot, senses, playerID)
    else
        restoreSensors(slot, senses)
        if not gameplay then
            setRobotStatus(slot, "Vanilla (player outside gameplay tiers)")
        else
            setRobotStatus(slot, eligible and "Vanilla detection" or "Vanilla (non-patrol preset)")
        end
    end
    if settings.debug then
        slot.preset = tostring(preset)
        slot.detection = senses:GetDetection(playerID)
        slot.playerTier = playerTier
    end
    return eligible, suppressed, gameplay and not hasPreset(chasePresets, preset)
end

local function distanceBetween(a, b)
    local x, y, z = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(x * x + y * y + z * z)
end

local function updateHud(player, candidates, protected, delta)
    if next(candidates) == nil then
        if protected then
            resetHud()
        elseif hud.id then
            hud.position = nil
            hud.retreatFor, hud.returnFor = 0, 0
            hud.lostFor = hud.lostFor + delta
            if hud.lostFor >= SIGNAL_LOSS_DELAY then
                hud.message = string.format("CERBERUS SIGNAL LOST   %d s", math.floor(hud.lostFor))
                hud.color = "lost"
            end
        end
        return
    end

    local playerPosition = player:GetWorldPosition()
    local nearestID, nearestPosition, distance
    for id, npc in pairs(candidates) do
        local position = npc:GetWorldPosition()
        local range = distanceBetween(position, playerPosition)
        if not distance or range < distance then
            nearestID, nearestPosition, distance = id, position, range
        end
    end

    local retreating = false
    if hud.id == nearestID and hud.position and delta > 0 and delta <= 1 then
        -- Use V's current position for both samples so running away does not count as robot movement.
        local previousDistance = distanceBetween(hud.position, playerPosition)
        retreating = distance - previousDistance > RETREAT_SPEED * delta
    end
    hud.retreatFor = retreating and (hud.retreatFor or 0) + delta or 0
    hud.returnFor = (hud.lostFor or 0) >= SIGNAL_LOSS_DELAY and RETURN_NOTICE_DURATION
        or math.max(0, (hud.returnFor or 0) - delta)
    hud.id = nearestID
    hud.position = { x = nearestPosition.x, y = nearestPosition.y, z = nearestPosition.z }
    hud.lostFor = 0

    local label = "CERBERUS"
    hud.color = "near"
    if hud.returnFor > 0 then
        label, hud.color = "CERBERUS RETURNED", "returning"
    elseif hud.retreatFor >= RETREAT_DURATION then
        label, hud.color = "CERBERUS MOVING AWAY", "away"
    end
    hud.message = string.format("%s   %.0f m", label, distance)
end

local function update(delta)
    if not settings.enabled or not (settings.hud or settings.detection or (settings.attacks and attackAvailable)) then
        stopEffects()
        setStatus(settings.enabled and "All gameplay changes off" or "Disabled")
        return
    end

    local player = Game.GetPlayer()
    if not IsDefined(player) or not player:IsAttached() or player:IsDead() then
        stopEffects()
        setStatus("Waiting for a loaded save")
        return
    end

    local journal = Game.GetJournalManager()
    local quest = IsDefined(journal) and journal:GetEntryByString(QUEST_PATH, "gameJournalQuest")
    if not IsDefined(quest) or journal:GetEntryState(quest) ~= activeQuestState then
        stopEffects()
        setStatus("Waiting for Somewhat Damaged")
        return
    end

    if next(tracked) == nil then
        -- The attach callback handles a normal save load. This covers a CET reload in place.
        local targeting = Game.GetTargetingSystem()
        if IsDefined(targeting) then remember(targeting:GetLookAtObject(player, false, false)) end
    end
    local playerID = player:GetEntityID()
    local playerTier = PlayerPuppet.GetSceneTier(player)
    local hudCandidates = settings.hud and not hudFault and isGameplayTier(playerTier) and {} or nil
    local anyPatrol, anyProtected, anySuppressed = false, false, false
    for key, slot in pairs(tracked) do
        local npc = Game.FindEntityByID(slot.id)
        if not isRobot(npc) or not npc:IsAttached() then
            tracked[key] = nil
            debugLog("Detached " .. key)
        else
            local eligible, suppressed, canTrack = checkRobot(slot, npc, playerID, playerTier)
            if hudCandidates and canTrack then hudCandidates[key] = npc end
            anyPatrol = anyPatrol or eligible
            anyProtected = anyProtected or not eligible
            anySuppressed = anySuppressed or suppressed
        end
    end
    -- This TweakDB flag is record-wide. Yield if any live copy is in a protected state.
    updateAttacks(attackAvailable and settings.attacks and anyPatrol and not anyProtected)
    if anySuppressed then
        setStatus("Cerberus patrol sensors suppressed")
    elseif anyPatrol then
        setStatus(settings.detection and "Waiting for sensors to disable" or "Cerberus patrol detected")
    elseif anyProtected then
        setStatus("Cerberus under vanilla control")
    else
        setStatus("Somewhat Damaged active. Waiting for Cerberus")
    end

    if hudCandidates then
        local ok, reason = pcall(updateHud, player, hudCandidates, anyProtected, delta)
        if not ok then
            hudFault = tostring(reason)
            spdlog.error("Cerberus HUD unavailable. " .. hudFault)
            resetHud()
        end
    else
        resetHud()
    end
end

local function trackedSlot(npc)
    if next(tracked) ~= nil and IsDefined(npc) then
        return tracked[tostring(npc:GetEntityID().hash)]
    end
end

local function filterPatrolStimulus(component, data)
    local npc = component:GetOwnerPuppet()
    local slot = trackedSlot(npc)
    if not slot or not slot.resetFor or not IsDefined(data) or not IsDefined(data.cachedEvt) then return false end
    local stimulus = data.cachedEvt
    local source = stimulus.sourceObject
    if not IsDefined(source) or not source:IsPlayer() or tostring(source:GetEntityID().hash) ~= slot.resetFor then
        return false
    end
    if not isRobot(npc) or not isGameplayTier(PlayerPuppet.GetSceneTier(source)) then return false end
    local senses = npc:GetSensesComponent()
    if not IsDefined(senses) or not isPatrolPreset(senses:GetCurrentPreset()) then return false end

    local stimType = stimulus:GetStimType()
    for _, movementStim in ipairs(movementStims) do
        if stimType == movementStim then return true, slot end
    end
    if stimulus:IsPurelyDirect() or stimulus:IsTagInStimuli("Direct") then return false end
    return stimulus:IsAudio() or stimulus:IsVisual(), slot
end

local function registerObservers()
    ObserveAfter("NPCPuppet", "OnGameAttached", function(npc)
        guarded(remember, npc)
    end)
    ObserveBefore("NPCPuppet", "OnDetach", function(npc)
        guarded(function()
            local slot = trackedSlot(npc)
            if not slot then return end
            updateAttacks(false)
            restoreRobot(slot, npc)
            tracked[tostring(slot.id.hash)] = nil
            pollSoon = true
        end)
    end)
    ObserveBefore("PlayerPuppet", "OnDetach", function()
        stopEffects()
        tracked = {}
        pollSoon = true
    end)
    ObserveAfter("CerberusComponent", "OnAIEvent", function(component)
        if next(tracked) == nil then
            guarded(function() remember(component:GetOwner()) end)
        end
    end)

    ObserveBefore("senseComponent", "OnSensePresetChangeEvent", function(senses, event)
        if next(tracked) == nil then return end
        guarded(function()
            local slot = trackedSlot(senses:GetOwnerPuppet())
            if slot and (event.reset or not isPatrolPreset(event.presetID)) then
                updateAttacks(false)
                restoreSensors(slot, senses)
                if hasPreset(chasePresets, event.presetID) then resetHud() end
                pollSoon = true
            end
        end)
    end)
    -- A later explicit vanilla toggle supersedes our ownership of that switch.
    ObserveBefore("senseComponent", "ToggleComponent", function(senses)
        if next(tracked) == nil then return end
        guarded(function()
            local slot = trackedSlot(senses:GetOwnerPuppet())
            if slot then slot.ownsVision, slot.ownsHearing = nil, nil end
        end)
    end)
    ObserveBefore("ScriptedPuppet", "EnableSensesComponent", function(npc)
        guarded(function()
            local slot = trackedSlot(npc)
            if slot then slot.ownsVision = nil end
        end)
    end)

    Override("ReactionManagerComponent", "HandleStimEvent;StimEventTaskData", function(component, data, wrapped)
        if ready and not fault and not stimulusFault and settings.enabled and settings.detection and next(tracked) then
            local ok, filtered, slot = pcall(filterPatrolStimulus, component, data)
            if not ok then
                stimulusFault = tostring(filtered)
                spdlog.error(stimulusFault)
            elseif filtered then
                slot.filteredStims = (slot.filteredStims or 0) + 1
                return
            end
        end
        return wrapped(data)
    end)
end

registerForEvent("onInit", function()
    guarded(function()
        loadSettings()
        local cetVersion = GetVersion()
        if not cetVersion:match("^v?1%.38%.") then
            setStatus("Cyberpunk 2.5 requires CET 1.38.x for this mod")
            spdlog.warn(status .. " (found " .. cetVersion .. ")")
            return
        end

        robotRecord = TweakDBID.new(ROBOT_RECORD)
        if not IsDefined(TweakDB:GetRecord(robotRecord)) then
            setStatus("Phantom Liberty Cerberus record unavailable")
            spdlog.warn(status)
            return
        end
        activeQuestState = Enum.new("gameJournalEntryState", "Active")
        for _, name in ipairs({
            "Senses.CerberusRelaxed", "Senses.Q303_Cerberus_Alerted", "Senses.Q303_Cerberus_Combat",
            "Senses.Default", "Senses.Relaxed", "Senses.Alerted", "Senses.Combat", "Senses.AbsoluteInstant",
        }) do
            patrolPresets[#patrolPresets + 1] = TweakDBID.new(name)
        end
        for _, name in ipairs({ "Senses.Q303_Cerberus_Introduction_Chase", "Senses.Q303_Cerberus_Bridge_Chase" }) do
            chasePresets[#chasePresets + 1] = TweakDBID.new(name)
        end
        local initialPreset = TweakDB:GetFlat(ROBOT_RECORD .. ".sensePreset")
        if initialPreset and IsDefined(TweakDB:GetRecord(initialPreset)) then
            patrolPresets[#patrolPresets + 1] = initialPreset
        end
        for _, name in ipairs({ "FootStepRegular", "FootStepSprint", "LandingRegular", "LandingHard", "LandingVeryHard" }) do
            movementStims[#movementStims + 1] = Enum.new("gamedataStimType", name)
        end

        attackAvailable = IsDefined(TweakDB:GetRecord(ATTACK_RECORD))
            and type(TweakDB:GetFlat(ATTACK_FLAT)) == "boolean"
        registerObservers()
        ready = true
        spdlog.info("Cerberus Neutralizer " .. VERSION .. " loaded with CET " .. cetVersion)
        setStatus("Waiting for a loaded save")
    end)
end)

registerForEvent("onUpdate", function(delta)
    if not ready or fault then return end
    elapsed = elapsed + delta
    local interval = next(tracked) and 0.15 or 0.75
    if pollSoon or elapsed >= interval then
        local deltaSincePoll = elapsed
        pollSoon, elapsed = false, 0
        guarded(update, deltaSincePoll)
    end
end)

registerForEvent("onShutdown", stopEffects)
registerForEvent("onOverlayOpen", function() overlay = true end)
registerForEvent("onOverlayClose", function() overlay = false end)

local function checkbox(label, key)
    local value, changed = ImGui.Checkbox(label, settings[key])
    if changed then
        settings[key] = value
        pollSoon = true
    end
    return changed
end

local hudColors = {
    near = { 0.96, 0.96, 0.96 },
    away = { 0.55, 0.88, 1.00 },
    lost = { 0.78, 0.81, 0.85 },
    returning = { 1.00, 0.66, 0.31 },
}

local function drawHud()
    if not (settings.enabled and settings.hud and hud.message) then return end
    local width, height = GetDisplayResolution()
    if width <= 0 or height <= 0 then return end

    local flags = ImGuiWindowFlags.NoDecoration + ImGuiWindowFlags.NoInputs
        + ImGuiWindowFlags.AlwaysAutoResize + ImGuiWindowFlags.NoSavedSettings
        + ImGuiWindowFlags.NoFocusOnAppearing + ImGuiWindowFlags.NoDocking
    ImGui.SetNextWindowPos(width * 0.5, height * 0.07, ImGuiCond.Always, 0.5, 0)
    ImGui.SetNextWindowBgAlpha(0.82)
    if ImGui.Begin("##CerberusNeutralizerHUD", flags) then
        local color = hudColors[hud.color]
        ImGui.TextColored(color[1], color[2], color[3], 1, hud.message)
    end
    ImGui.End()
end

registerForEvent("onDraw", function()
    if not overlay then
        drawHud()
        return
    end
    if ImGui.Begin("Cerberus Neutralizer") then
        ImGui.Text("v" .. VERSION)
        local enableChanged = checkbox("Enable Cerberus Neutralizer", "enabled")
        local detectionChanged = checkbox("Disable Cerberus Detection", "detection")
        ImGui.BeginDisabled(not attackAvailable)
        local attacksChanged = checkbox("Disable Cerberus Attacks", "attacks")
        ImGui.EndDisabled()
        ImGui.TextWrapped(attackAvailable and "Blocks the patrol AI attack action. Scripted grabs and chases remain."
            or "Attack action is unavailable in this session.")
        local hudChanged = checkbox("Show Cerberus HUD", "hud")
        local debugChanged = checkbox("Debug Mode", "debug")
        if enableChanged or detectionChanged or attacksChanged or hudChanged or debugChanged then saveSettings() end

        ImGui.Separator()
        ImGui.TextWrapped(status)
        if attackActive then ImGui.Text("Patrol attack action disabled") end
        if attackFault then ImGui.TextWrapped(attackFault) end
        if stimulusFault then ImGui.TextWrapped("Stimulus filter unavailable. " .. stimulusFault) end
        if hudFault then ImGui.TextWrapped("Cerberus HUD unavailable. " .. hudFault) end
        if not attackAvailable and ownsAttackFlat then
            ImGui.TextWrapped("Could not restore the attack flag. Restart the game to restore it.")
        end
        if fault then ImGui.TextWrapped(fault) end
        if settings.debug then
            ImGui.Text("Record: " .. ROBOT_RECORD)
            for key, slot in pairs(tracked) do
                ImGui.TextWrapped(key .. " | " .. slot.status)
                if slot.preset then ImGui.TextWrapped("Preset: " .. slot.preset) end
                if slot.detection then ImGui.Text(string.format("Detection: %.2f", slot.detection)) end
                if slot.playerTier then ImGui.Text("Player scene tier " .. tostring(slot.playerTier)) end
                ImGui.Text("Player stimuli filtered " .. tostring(slot.filteredStims or 0))
            end
        end
    end
    ImGui.End()
end)
