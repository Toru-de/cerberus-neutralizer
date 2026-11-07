local mod = "bin/x64/plugins/cyber_engine_tweaks/mods/CerberusNeutralizer/init.lua"
local robotRecord = "Character.q305_cerberus_robot"
local relaxedPreset = "Senses.CerberusRelaxed"
local defaultPreset = "Senses.Default"
local introPreset = "Senses.Q303_Cerberus_Introduction_Chase"
local bridgePreset = "Senses.Q303_Cerberus_Bridge_Chase"
local attackRecord = "CerberusBoss.CerberusAttacks"

local function makeNPC(key, record, visual, hearing)
    local id = { hash = key }
    local senses = { visual = visual, hearing = hearing, preset = relaxedPreset, detection = 50, resets = 0 }
    local npc = {
        attached = true, inScene = false, inWorkspot = false, dead = false, senses = senses,
        position = { x = 0, y = 0, z = 0 },
    }

    function npc:IsA(class) return class == "NPCPuppet" end
    function npc:IsPlayer() return record == "Player" end
    function npc:IsCerberus() return true end
    function npc:GetRecordID() return record end
    function npc:GetEntityID() return id end
    function npc:IsAttached() return self.attached end
    function npc:IsDead() return self.dead end
    function npc:GetSensesComponent() return senses end
    function npc:GetWorldPosition()
        assert(not self.positionError, "simulated position API error")
        return self.position
    end

    function senses:GetOwnerPuppet() return npc end
    function senses:GetCurrentPreset() return self.preset end
    function senses:IsEnabled() return self.visual end
    function senses:Toggle(value) self.visual = value end
    function senses:IsHearingEnabled() return self.hearing end
    function senses:SetHearingEnabled(value) self.hearing = value end
    function senses:GetDetection(playerID) return self.detection end
    function senses:ResetDetection(playerID)
        assert(playerID.hash == "player")
        self.detection = 0
        self.resets = self.resets + 1
    end
    return npc
end

local function start(options)
    options = options or {}
    local state = { active = false, errors = {}, entities = {}, attackFlag = options.attackFlag or false }
    local events, before, after, overrides = {}, {}, {}, {}
    local quest = {}
    local settingToChange, settingValue

    registerForEvent = function(event, fn) events[event] = fn end
    ObserveBefore = function(class, method, fn) before[class .. "." .. method] = fn end
    ObserveAfter = function(class, method, fn) after[class .. "." .. method] = fn end
    Override = function(class, method, fn) overrides[class .. "." .. method] = fn end
    IsDefined = function(ref) return type(ref) == "table" end
    GetVersion = function() return options.cetVersion or "v1.38.1" end
    TweakDBID = { new = function(id) return id end }
    Enum = { new = function(class, value) return value end }
    PlayerPuppet = {
        GetSceneTier = function(player)
            assert(not state.tierError, "simulated scene tier API error")
            return player.tier or 1
        end,
    }

    spdlog = {
        info = function() end,
        warn = function() end,
        error = function(message) state.errors[#state.errors + 1] = message end,
    }
    TweakDB = {
        GetRecord = function(_, id)
            assert(id == robotRecord or id == relaxedPreset or id == attackRecord)
            return {}
        end,
        GetFlat = function(_, flat)
            if flat == robotRecord .. ".sensePreset" then return relaxedPreset end
            assert(flat == attackRecord .. ".disableAction")
            return state.attackFlag
        end,
        SetFlats = function(_, record, values)
            assert(record == attackRecord)
            if state.attackWriteError then return false end
            state.attackFlag = values.disableAction
            return true
        end,
    }
    Game = {
        GetPlayer = function() return state.player end,
        GetJournalManager = function()
            return {
                GetEntryByString = function(_, path, class)
                    assert(path == "ep1/quests/main_quest/q305_bunker" and class == "gameJournalQuest")
                    return quest
                end,
                GetEntryState = function(_, entry)
                    assert(entry == quest)
                    return state.active and "Active" or "Succeeded"
                end,
            }
        end,
        FindEntityByID = function(id) return state.entities[id.hash] end,
        GetTargetingSystem = function()
            return { GetLookAtObject = function() return state.lookAt end }
        end,
    }

    local noop = function() end
    GetDisplayResolution = function() return 1920, 1080 end
    ImGuiCond = { Always = 1 }
    ImGuiWindowFlags = {
        NoDecoration = 1, NoInputs = 2, AlwaysAutoResize = 4, NoSavedSettings = 8,
        NoFocusOnAppearing = 16, NoDocking = 32,
    }
    ImGui = {
        Begin = function(name, flags)
            if name == "##CerberusNeutralizerHUD" then assert(flags == 63) end
            state.drawnWindow = name
            return true
        end,
        End = noop, BeginDisabled = noop, EndDisabled = noop, Separator = noop,
        Text = noop, TextWrapped = noop, SetNextWindowPos = noop, SetNextWindowBgAlpha = noop,
        TextColored = function(_, _, _, _, value) state.drawnText = value end,
        Checkbox = function(label, value)
            if label == settingToChange then return settingValue, true end
            return value, false
        end,
    }
    local open = io.open
    io.open = function(path, mode)
        assert(path == "settings.json")
        if mode == "r" then return nil end
        return { write = function() return true end, close = function() return true end }
    end
    json = { encode = function(values) state.saved = values return "{}" end }

    dofile(mod)
    events.onInit()
    state.tick = function(delta) events.onUpdate(delta or 1) end
    state.stop = function() events.onShutdown() io.open = open end
    state.load = function()
        state.player = makeNPC("player", "Player", true, true)
        state.active = true
    end
    state.attach = function(npc)
        state.entities[npc:GetEntityID().hash] = npc
        after["NPCPuppet.OnGameAttached"](npc)
    end
    state.detach = function(npc)
        before["NPCPuppet.OnDetach"](npc)
        state.entities[npc:GetEntityID().hash] = nil
        npc.attached = false
    end
    state.preset = function(npc, preset)
        before["senseComponent.OnSensePresetChangeEvent"](npc.senses, { reset = false, presetID = preset })
        npc.senses.preset = preset
    end
    state.exitSave = function()
        before["PlayerPuppet.OnDetach"](state.player)
        state.player = nil
        state.entities = {}
    end
    state.set = function(label, value)
        settingToChange, settingValue = label, value
        events.onOverlayOpen()
        events.onDraw()
        events.onOverlayClose()
        settingToChange = nil
    end
    state.hud = function()
        state.drawnWindow, state.drawnText = nil, nil
        events.onDraw()
        assert(not state.drawnWindow or state.drawnWindow == "##CerberusNeutralizerHUD")
        return state.drawnText
    end
    state.vanillaToggle = function(npc, enabled)
        before["senseComponent.ToggleComponent"](npc.senses, enabled)
        npc.senses.visual, npc.senses.hearing = enabled, enabled
    end
    state.processStimulus = function(npc, source, stimType, audio, direct)
        local component = { GetOwnerPuppet = function() return npc end }
        local data = { cachedEvt = {
            sourceObject = source,
            GetStimType = function() return stimType end,
            IsAudio = function() return audio end,
            IsVisual = function() return false end,
            IsPurelyDirect = function() return false end,
            IsTagInStimuli = function(_, tag)
                assert(tag == "Direct")
                return direct
            end,
        } }
        local vanillaCalls = 0
        overrides["ReactionManagerComponent.HandleStimEvent;StimEventTaskData"](component, data, function(arg)
            assert(arg == data)
            vanillaCalls = vanillaCalls + 1
        end)
        assert(vanillaCalls <= 1)
        return vanillaCalls == 1
    end
    return state
end

local function sensors(npc, visual, hearing)
    assert(npc.senses.visual == visual and npc.senses.hearing == hearing)
end

local state = start()
local robot = makeNPC("9007199254740993ULL", robotRecord, true, true)
local fake = makeNPC("9007199254740992ULL", "Character.q305_cerberus_robot_fake", true, true)
state.attach(robot)
state.attach(fake)
state.tick()
sensors(robot, true, true)
state.load()
robot.senses.preset = defaultPreset
robot.inScene, robot.inWorkspot = true, true
state.player.tier = 2
state.tick()
sensors(robot, false, false)
sensors(fake, true, true)
assert(robot.senses.resets == 1 and robot.senses.detection == 0 and not state.attackFlag)
assert(not state.processStimulus(robot, state.player, "FootStepSprint", false, true))
assert(not state.processStimulus(robot, state.player, "FootStepRegular", true, false))
assert(not state.processStimulus(robot, state.player, "Gunshot", true, false))
assert(state.processStimulus(fake, state.player, "FootStepSprint", true, false))
assert(state.processStimulus(robot, fake, "FootStepSprint", true, false))
assert(state.processStimulus(robot, state.player, "Gunshot", true, true))
state.tick(0.01)
assert(robot.senses.resets == 1)

state.set("Disable Cerberus Attacks", true)
state.tick()
assert(state.attackFlag and state.saved.attacks)
for _, preset in ipairs({ introPreset, bridgePreset }) do
    state.preset(robot, preset)
    sensors(robot, true, true) -- Restore before the vanilla preset handler runs.
    assert(not state.attackFlag)
    assert(state.processStimulus(robot, state.player, "FootStepSprint", true, false))
    state.tick()
    sensors(robot, true, true)
    state.preset(robot, relaxedPreset)
    state.tick()
    sensors(robot, false, false)
    assert(state.attackFlag)
end

state.player.tier = 4
assert(state.processStimulus(robot, state.player, "FootStepSprint", true, false))
state.tick()
sensors(robot, true, true)
assert(not state.attackFlag)
state.player.tier = 5
state.tick()
sensors(robot, true, true)
state.player.tier = 3
state.tick()
sensors(robot, false, false)
assert(not state.processStimulus(robot, state.player, "FootStepSprint", true, false))

state.set("Disable Cerberus Detection", false)
state.tick()
sensors(robot, true, true)
assert(state.attackFlag)
assert(state.processStimulus(robot, state.player, "FootStepSprint", true, false))
state.set("Enable Cerberus Neutralizer", false)
state.tick()
assert(not state.attackFlag)
state.set("Disable Cerberus Detection", true)
state.set("Enable Cerberus Neutralizer", true)
state.tick()
sensors(robot, false, false)

state.active = false
state.tick()
sensors(robot, true, true)
assert(not state.attackFlag)
state.active = true
state.tick()
state.detach(robot)
sensors(robot, true, true)
assert(not state.attackFlag)

local replacement = makeNPC(robot:GetEntityID().hash, robotRecord, false, true)
state.attach(replacement)
state.tick()
sensors(replacement, false, false)
state.exitSave()
sensors(replacement, false, true)
assert(not state.attackFlag)

state.load()
local existing = makeNPC("existing", robotRecord, true, true)
state.entities.existing, state.lookAt = existing, existing
state.tick()
sensors(existing, false, false)
state.vanillaToggle(existing, false)
state.set("Disable Cerberus Detection", false)
state.tick()
sensors(existing, false, false)
state.stop()
assert(not state.attackFlag and #state.errors == 0)

state = start({ attackFlag = true })
state.load()
state.attach(existing)
state.set("Disable Cerberus Attacks", true)
state.tick()
state.stop()
assert(state.attackFlag and #state.errors == 0) -- Respect another mod's original flag.

state = start()
state.load()
robot = makeNPC("error-case", robotRecord, true, true)
state.attach(robot)
state.attackWriteError = true
state.set("Disable Cerberus Attacks", true)
state.tick()
sensors(robot, false, false)
assert(not state.attackFlag and #state.errors == 1)
state.tierError = true
state.tick()
sensors(robot, true, true)
assert(#state.errors == 2)
state.stop()

state = start({ cetVersion = "v1.37.1" })
state.load()
state.tick()
assert(not state.attackFlag and #state.errors == 0)
state.stop()

state = start()
state.load()
state.tick()
assert(state.hud() == nil) -- The initial wait never looks like a departure.
robot = makeNPC("hud-robot", robotRecord, true, true)
robot.position.x = 12
state.attach(robot)
state.tick(0.2)
assert(state.hud() == "CERBERUS   12 m")

state.set("Disable Cerberus Detection", false)
state.player.position.x = -10
state.tick(0.2)
sensors(robot, true, true)
assert(state.hud() == "CERBERUS   22 m") -- Only V moved.
for x = 13, 14 do
    robot.position.x = x
    state.tick(0.21)
end
assert(state.hud() == "CERBERUS MOVING AWAY   24 m")

state.detach(robot)
state.tick(0.1)
assert(state.hud() == "CERBERUS MOVING AWAY   24 m")
state.tick(0.95)
assert(state.hud() == "CERBERUS SIGNAL LOST   1 s")
local returned = makeNPC("hud-replacement", robotRecord, true, true)
returned.position.x = 2
state.attach(returned)
state.tick(0.15)
assert(state.hud() == "CERBERUS RETURNED   12 m")
state.tick(3)
assert(state.hud() == "CERBERUS   12 m")

state.preset(returned, bridgePreset)
assert(state.hud() == nil)
state.tick()
assert(state.hud() == nil)
state.preset(returned, relaxedPreset)
state.tick()
state.set("Show Cerberus HUD", false)
assert(state.hud() == nil and state.saved.hud == false)
state.set("Show Cerberus HUD", true)
state.tick()
assert(state.hud() == "CERBERUS   12 m")
state.exitSave()
assert(state.hud() == nil)
state.stop()
assert(#state.errors == 0)

state = start()
state.load()
robot = makeNPC("hud-error", robotRecord, true, true)
robot.positionError = true
state.attach(robot)
state.tick()
sensors(robot, false, false)
assert(state.hud() == nil and #state.errors == 1)
state.stop()

print("PASS: patrol protection, sprint stimuli, cinematic guards, rollback, HUD motion, loss and return")
