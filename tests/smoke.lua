local mod = "bin/x64/plugins/cyber_engine_tweaks/mods/CerberusNeutralizer/init.lua"
local robotRecord = "Character.q305_cerberus_robot"
local relaxedPreset = "Senses.CerberusRelaxed"
local introPreset = "Senses.Q303_Cerberus_Introduction_Chase"
local bridgePreset = "Senses.Q303_Cerberus_Bridge_Chase"
local attackRecord = "CerberusBoss.CerberusAttacks"

local function makeNPC(key, record, visual, hearing)
    local id = { hash = key }
    local senses = { visual = visual, hearing = hearing, preset = relaxedPreset, detection = 50, resets = 0 }
    local npc = { attached = true, inScene = false, inWorkspot = false, dead = false, senses = senses }

    function npc:IsA(class) return class == "NPCPuppet" end
    function npc:IsCerberus() return true end
    function npc:GetRecordID() return record end
    function npc:GetEntityID() return id end
    function npc:IsAttached() return self.attached end
    function npc:IsDead() return self.dead end
    function npc:GetSensesComponent() return senses end

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
    local events, before, after = {}, {}, {}
    local quest = {}
    local settingToChange, settingValue

    registerForEvent = function(event, fn) events[event] = fn end
    ObserveBefore = function(class, method, fn) before[class .. "." .. method] = fn end
    ObserveAfter = function(class, method, fn) after[class .. "." .. method] = fn end
    IsDefined = function(ref) return type(ref) == "table" end
    GetVersion = function() return options.cetVersion or "v1.38.1" end
    TweakDBID = { new = function(id) return id end }
    Enum = { new = function(class, value) return value end }

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
        GetSceneSystem = function()
            assert(not state.sceneError, "simulated scene API error")
            return {
                GetScriptInterface = function()
                    return { IsEntityInScene = function(_, id) return state.entities[id.hash].inScene end }
                end,
            }
        end,
        GetWorkspotSystem = function()
            return { IsActorInWorkspot = function(_, npc) return npc.inWorkspot end }
        end,
        GetTargetingSystem = function()
            return { GetLookAtObject = function() return state.lookAt end }
        end,
    }

    local noop = function() end
    ImGui = {
        Begin = function() return true end,
        End = noop, BeginDisabled = noop, EndDisabled = noop, Separator = noop,
        Text = noop, TextWrapped = noop,
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
    state.vanillaToggle = function(npc, enabled)
        before["senseComponent.ToggleComponent"](npc.senses, enabled)
        npc.senses.visual, npc.senses.hearing = enabled, enabled
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
state.tick()
sensors(robot, false, false)
sensors(fake, true, true)
assert(robot.senses.resets == 1 and robot.senses.detection == 0 and not state.attackFlag)
state.tick(0.01)
assert(robot.senses.resets == 1)

state.set("Disable Cerberus Attacks", true)
state.tick()
assert(state.attackFlag and state.saved.attacks)
for _, preset in ipairs({ introPreset, bridgePreset }) do
    state.preset(robot, preset)
    sensors(robot, true, true) -- Restore before the vanilla preset handler runs.
    assert(not state.attackFlag)
    state.tick()
    sensors(robot, true, true)
    state.preset(robot, relaxedPreset)
    state.tick()
    sensors(robot, false, false)
    assert(state.attackFlag)
end

robot.inScene = true
state.tick()
sensors(robot, true, true)
assert(not state.attackFlag)
robot.inScene, robot.inWorkspot = false, true
state.tick()
sensors(robot, true, true)
robot.inWorkspot = false
state.tick()
sensors(robot, false, false)

state.set("Disable Cerberus Detection", false)
state.tick()
sensors(robot, true, true)
assert(state.attackFlag)
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
state.sceneError = true
state.tick()
sensors(robot, true, true)
assert(#state.errors == 2)
state.stop()

state = start({ cetVersion = "v1.37.1" })
state.load()
state.tick()
assert(not state.attackFlag and #state.errors == 0)
state.stop()

print("PASS: identity, save reload, patrol, scene and chase guards, toggles, rollback, and API errors")
