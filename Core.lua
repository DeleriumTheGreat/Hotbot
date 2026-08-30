-- Hotbot Core.lua
-- Tracks Heal over Time (HoT) coverage across roster and nearby targets.
-- Target priority is configured in Config.lua.
-- Per-career ability IDs are defined in Config.lua.

Hotbot = {};
Hotbot.ScanCache = nil;
Hotbot.AbilityIconNums = {};
Hotbot.RenderSignature = nil;

local VERSION           = "1.2.0";

local MAX_GROUP_MEMBERS = 6;
local UPDATE_THROTTLE   = 0.25;   -- seconds between full scans
local CLEAR_TARGET_DELAY = 0.75;   -- seconds after a cast click before clearing targets
local APPLY_VERIFY_DELAY = 0.55;   -- seconds after a cast click before checking whether the HoT landed
local BUFF_DISTANCE     = 110;    -- yards beyond which we skip/tint the target
local MAX_MAP_POINTS    = 511;
local DISTANCE_FIX      = 1 / 1.06;

local MapPointTypeFilter =
{
    [SystemData.MapPips.PLAYER] = true,
    [SystemData.MapPips.GROUP_MEMBER] = true,
    [SystemData.MapPips.WARBAND_MEMBER] = true,
    [SystemData.MapPips.DESTRUCTION_ARMY] = true,
    [SystemData.MapPips.ORDER_ARMY] = true,
};

-- Internal state -----------------------------------------------------------
local throttleTimer     = 0;
local clearTargetsTimer = nil;
local verifiedCovered   = {};
local failedApplyAttempts = {};
local failedTargetSkips = {};
local pendingApplyCheckTimer = nil;
local pendingApplyCheckName = L"";
local pendingApplyCheckAbilityId = nil;
local postCastLockTimer = 0;
local pendingTargetCheckTimer = nil;
local pendingTargetCheckName = L"";
local loadRetryTimer = 0;
local loadRetryElapsed = 0;
local loadRetryAnnounced = false;
local playerMovingTimer = 0;
local lastPlayerWorldX = nil;
local lastPlayerWorldY = nil;
local myName            = L"";
local myCareerLine      = nil;
local hotAbilityId      = nil;    -- first configured ability, kept for legacy checks
local hotAbilityIds     = {};     -- configured cast priority for this career
local hotAbilityNames   = {};
local hotAbilityVerify  = {};
local hotAbilityTrackEffect = {};
local hotAbilityCooldownSeconds = {};
Hotbot.AbilityCooldownPaddingSeconds = {};
local hotAbilityApplyHoldSeconds = {};
local hotAbilityEffectIds = {};
local hotAbilityEffectNames = {};
local hotAbilityRequiresStationary = {};
local hotAbilityRequiresDamagedTarget = {};
local hotAbilityCastOnCooldown = {};
local hotAbilitySkipEnabledCheck = {};
local hotAbilityCleanseTypes = {};
local hotAbilityEmergencyHealthPercent = {};
local emergencyAbilityIds = {};
local abilityCooldownsRemaining = {};
Hotbot.CooldownPriorityRetryRemaining = {};
Hotbot.CastingTrackedAbilityId = nil;
Hotbot.ManualTargetLock = false;
local activeAbilityId   = nil;    -- ability currently armed for the next click
local hotEffectIds      = {};     -- effect/buff IDs that count as the tracked HoT
local hotEffectIdsByAbility = {};
local hotEffectNamesByAbility = {};
local hotTrackedAbilityIds = {};
local hotIconNum        = 0;
local currentScanAbilityId = nil;
local nearbyModeEnabled = false; -- intentionally OFF after login or /reloadui
local cycleSelectionActive = false;
local cycleKeyNoticeShown = false;

-- The best target found on the last scan
local bestTarget        = nil;

local flagBarUpdate     = true;
local isLoaded          = false;
local isUnsupportedCareer = false;
local registeredEvents  = {};
local clientWindowGameAction = WindowGameAction;

Hotbot.CurrentTarget    = L"";

-- Helpers ------------------------------------------------------------------

local function ChatPrint(text)
    EA_ChatWindow.Print(
        towstring(tostring(text)),
        ChatSettings.Channels[SystemData.ChatLogFilters.SAY].id
    );
end

local function StripRealm(name)
    if (not name) then return L"" end
    return name:match(L"([^^]+)^?([^^]*)");
end

local function CreateEvent(e, func)
    return { e = e, func = func };
end

local function RegisterEvents(events, enable)
    for _, ev in pairs(events) do
        if (enable) then
            RegisterEventHandler(ev.e, ev.func);
        else
            UnregisterEventHandler(ev.e, ev.func);
        end
    end
end

local function DebugSkip(name, reason)
    if (HotbotConfig.DebugSkips) then
        ChatPrint("Hotbot skip " .. tostring(name or "?") .. ": " .. tostring(reason));
    end
end

local function IsCheckEnabled(flagName)
    return (HotbotConfig[flagName] ~= false);
end

function Hotbot.IsNearbyFallbackEnabled()
    return (HotbotConfig and HotbotConfig.EnableNearbyFallback == true);
end

function Hotbot.IsNearbyModeEnabled()
    return nearbyModeEnabled;
end
function Hotbot.GetRefreshThreshold()
    local threshold = nil;
    if (HotbotConfig) then
        threshold = tonumber(HotbotConfig.RefreshThreshold);
    end
    if (not threshold or threshold < 0) then return 0 end
    return threshold;
end

local function IsCareerConfigured(careerLine)
    if (not HotbotConfig or not careerLine or careerLine == 0) then return false end
    if (HotbotConfig.HotAbilitiesByCareer and HotbotConfig.HotAbilitiesByCareer[careerLine]) then return true end
    if (HotbotConfig.HotAbilityByCareer and HotbotConfig.HotAbilityByCareer[careerLine]) then return true end
    return false;
end

local function GetCurrentPlayerName()
    if (not GameData or not GameData.Player or not GameData.Player.name or GameData.Player.name == L"") then
        return L"";
    end
    return StripRealm(GameData.Player.name);
end

local function IsPlayerDataReady()
    if (not GameData or not GameData.Player) then return false end
    if (not GameData.Player.career or not GameData.Player.career.line or GameData.Player.career.line == 0) then return false end
    if (not GameData.Player.name or GameData.Player.name == L"") then return false end
    if (not IsCareerConfigured(GameData.Player.career.line)) then return false end
    return true;
end

local function PlayerDataChangedSinceLoad()
    if (not isLoaded) then return false end

    local currentName = GetCurrentPlayerName();
    if (currentName ~= L"" and myName ~= L"" and currentName ~= myName) then return true end

    local currentCareerLine = nil;
    if (GameData and GameData.Player and GameData.Player.career) then
        currentCareerLine = GameData.Player.career.line;
    end
    if (currentCareerLine and currentCareerLine ~= 0 and myCareerLine and currentCareerLine ~= myCareerLine) then return true end

    return false;
end

local function AddHotAbility(entry)
    local abilityId = entry;
    local abilityName = nil;
    local verifyApply = nil;
    local trackEffect = true;
    local cooldownSeconds = nil;
    local cooldownPaddingSeconds = nil;
    local applyHoldSeconds = nil;
    local effectIds = nil;
    local effectNames = nil;
    local requiresStationary = nil;
    local requiresDamagedTarget = nil;
    local castOnCooldown = nil;
    local skipEnabledCheck = nil;
    local requiresCleanse = nil;
    local cleanseTypes = nil;

    if (type(entry) == "table") then
        abilityId = entry.id or entry.abilityId or entry[1];
        abilityName = entry.name or entry.label or entry[2];
        verifyApply = entry.verifyApply;
        if (verifyApply == nil) then
            verifyApply = entry.verify;
        end
        if (entry.trackEffect ~= nil) then
            trackEffect = (entry.trackEffect ~= false);
        end
        cooldownSeconds = entry.cooldownSeconds or entry.cooldown;
        cooldownPaddingSeconds = entry.cooldownPaddingSeconds or entry.cooldownPadding;
        applyHoldSeconds = entry.applyHoldSeconds or entry.postCastHoldSeconds or entry.buffDelaySeconds;
        requiresStationary = entry.requiresStationary or entry.stationaryOnly;
        requiresDamagedTarget = entry.requiresDamagedTarget or entry.requireDamagedTarget or entry.damagedOnly;
        castOnCooldown = entry.castOnCooldown or entry.cooldownPriority;
        skipEnabledCheck = entry.skipEnabledCheck or entry.ignoreEnabledCheck;
        effectIds = entry.effectIds;
        if ((not effectIds) and entry.effectId) then
            effectIds = { entry.effectId };
        end
        effectNames = entry.effectNames;
        if ((not effectNames) and entry.effectName) then
            effectNames = { entry.effectName };
        end
        requiresCleanse = entry.requiresCleanse;
        cleanseTypes = entry.cleanseTypes;
    end

    abilityId = tonumber(abilityId);
    if (not abilityId or abilityId == 0) then return end

    for _, existingAbilityId in ipairs(hotAbilityIds) do
        if (existingAbilityId == abilityId) then return end
    end

    table.insert(hotAbilityIds, abilityId);

    if (abilityName) then
        hotAbilityNames[abilityId] = abilityName;
    end

    if (verifyApply ~= nil) then
        hotAbilityVerify[abilityId] = (verifyApply ~= false);
    end

    hotAbilityTrackEffect[abilityId] = trackEffect;
    hotAbilityCooldownSeconds[abilityId] = tonumber(cooldownSeconds);
    Hotbot.AbilityCooldownPaddingSeconds[abilityId] = tonumber(cooldownPaddingSeconds);
    hotAbilityApplyHoldSeconds[abilityId] = tonumber(applyHoldSeconds);
    hotAbilityEffectIds[abilityId] = effectIds;
    hotAbilityEffectNames[abilityId] = effectNames;
    hotAbilityRequiresStationary[abilityId] = (requiresStationary == true);
    hotAbilityRequiresDamagedTarget[abilityId] = (requiresDamagedTarget == true);
    hotAbilityCastOnCooldown[abilityId] = (castOnCooldown == true);
    hotAbilitySkipEnabledCheck[abilityId] = (skipEnabledCheck == true);

    if (requiresCleanse) then
        hotAbilityCleanseTypes[abilityId] = cleanseTypes or { "isCurse", "isAilment" };
    end
end

local function GetEmergencyHealthPercent(entry)
    local percent = nil;
    if (type(entry) == "table") then
        percent = entry.maxHealthPercent or entry.healthPercent or entry.emergencyHealthPercent;
    end

    percent = tonumber(percent or HotbotConfig.EmergencyHealthPercent or 50);
    if (not percent or percent <= 0) then return 50 end
    return percent;
end

local function AddEmergencyAbility(entry)
    local abilityId = entry;
    local abilityName = nil;
    local verifyApply = false;
    local cooldownSeconds = nil;
    local requiresStationary = nil;
    local skipEnabledCheck = true;

    if (type(entry) == "table") then
        abilityId = entry.id or entry.abilityId or entry[1];
        abilityName = entry.name or entry.label or entry[2];
        verifyApply = (entry.verifyApply == true or entry.verify == true);
        cooldownSeconds = entry.cooldownSeconds or entry.cooldown;
        requiresStationary = entry.requiresStationary or entry.stationaryOnly;
        if (entry.skipEnabledCheck == false or entry.ignoreEnabledCheck == false) then
            skipEnabledCheck = false;
        elseif (entry.skipEnabledCheck == true or entry.ignoreEnabledCheck == true) then
            skipEnabledCheck = true;
        end
    end

    abilityId = tonumber(abilityId);
    if (not abilityId or abilityId == 0) then return end

    for _, existingAbilityId in ipairs(emergencyAbilityIds) do
        if (existingAbilityId == abilityId) then return end
    end

    table.insert(emergencyAbilityIds, abilityId);

    if (abilityName) then
        hotAbilityNames[abilityId] = abilityName;
    end

    hotAbilityVerify[abilityId] = (verifyApply == true);
    hotAbilityTrackEffect[abilityId] = false;
    hotAbilityCooldownSeconds[abilityId] = tonumber(cooldownSeconds);
    hotAbilityRequiresStationary[abilityId] = (requiresStationary == true);
    hotAbilitySkipEnabledCheck[abilityId] = (skipEnabledCheck == true);
    hotAbilityEmergencyHealthPercent[abilityId] = GetEmergencyHealthPercent(entry);
end

local function BuildHotAbilities()
    hotAbilityIds = {};
    hotAbilityNames = {};
    hotAbilityVerify = {};
    hotAbilityTrackEffect = {};
    hotAbilityCooldownSeconds = {};
    Hotbot.AbilityCooldownPaddingSeconds = {};
    hotAbilityApplyHoldSeconds = {};
    hotAbilityEffectIds = {};
    hotAbilityEffectNames = {};
    hotAbilityRequiresStationary = {};
    hotAbilityRequiresDamagedTarget = {};
    hotAbilityCastOnCooldown = {};
    hotAbilitySkipEnabledCheck = {};
    hotAbilityCleanseTypes = {};
    hotAbilityEmergencyHealthPercent = {};
    emergencyAbilityIds = {};

    if (HotbotConfig.HotAbilitiesByCareer and HotbotConfig.HotAbilitiesByCareer[myCareerLine]) then
        for _, entry in ipairs(HotbotConfig.HotAbilitiesByCareer[myCareerLine]) do
            AddHotAbility(entry);
        end
    end

    if (HotbotConfig.HotAbilityByCareer) then
        AddHotAbility(HotbotConfig.HotAbilityByCareer[myCareerLine]);
    end

    if (HotbotConfig.EmergencyAbilitiesByCareer and HotbotConfig.EmergencyAbilitiesByCareer[myCareerLine]) then
        for _, entry in ipairs(HotbotConfig.EmergencyAbilitiesByCareer[myCareerLine]) do
            AddEmergencyAbility(entry);
        end
    end

    hotAbilityId = hotAbilityIds[1];
    activeAbilityId = hotAbilityId;
end

local function AddHotEffectForAbility(abilityId, effectId)
    effectId = tonumber(effectId);
    if (not abilityId or not effectId or effectId == 0) then return end

    if (not hotEffectIdsByAbility[abilityId]) then
        hotEffectIdsByAbility[abilityId] = {};
    end

    hotEffectIdsByAbility[abilityId][effectId] = true;
    hotEffectIds[effectId] = true;
end

local function NormalizeEffectName(name)
    if (not name) then return nil end

    local normalized = nil;
    if (type(name) == "wstring" and WStringToString) then
        local ok, text = pcall(WStringToString, name);
        if (ok and text) then
            normalized = text;
        end
    end

    if (not normalized and type(name) == "string") then
        normalized = name;
    end

    if (not normalized) then
        normalized = tostring(name);
    end

    if (not normalized or normalized == "") then return nil end
    return string.lower(normalized);
end

local function AddHotEffectNameForAbility(abilityId, effectName)
    local normalized = NormalizeEffectName(effectName);
    if (not abilityId or not normalized) then return end

    if (not hotEffectNamesByAbility[abilityId]) then
        hotEffectNamesByAbility[abilityId] = {};
    end

    hotEffectNamesByAbility[abilityId][normalized] = true;
end

local function EffectNameMatchesAbility(effect, abilityId)
    if (not effect or not effect.name or not hotEffectNamesByAbility[abilityId]) then return false end

    local normalized = NormalizeEffectName(effect.name);
    if (not normalized) then return false end

    if (hotEffectNamesByAbility[abilityId][normalized] == true) then
        return true;
    end

    for trackedName, _ in pairs(hotEffectNamesByAbility[abilityId]) do
        if (string.find(normalized, trackedName, 1, true) or string.find(trackedName, normalized, 1, true)) then
            return true;
        end
    end

    return false;
end

local function GetAbilityIconNum(abilityId)
    if (not abilityId) then return 0 end

    if (Hotbot.AbilityIconNums[abilityId] ~= nil) then
        return Hotbot.AbilityIconNums[abilityId];
    end

    if (not GetAbilityTable) then return 0 end

    local ok, abilityData = pcall(GetAbilityTable, GameData.AbilityType.STANDARD);
    local iconNum = 0;
    if (ok and abilityData and abilityData[abilityId]) then
        iconNum = abilityData[abilityId].iconNum or 0;
    end
    Hotbot.AbilityIconNums[abilityId] = iconNum;
    return iconNum;
end

local function SetActiveAbility(abilityId)
    if (not abilityId) then return end
    if (activeAbilityId == abilityId and Hotbot.AbilityIconNums[abilityId] ~= nil) then return end
    activeAbilityId = abilityId;
    hotIconNum = GetAbilityIconNum(abilityId);
end

local function GetAbilityLabel(abilityId)
    return hotAbilityNames[abilityId] or tostring(abilityId);
end

local function GetAbilitySummary()
    local parts = {};
    for _, abilityId in ipairs(hotAbilityIds) do
        table.insert(parts, GetAbilityLabel(abilityId) .. "(" .. tostring(abilityId) .. ")");
    end
    return table.concat(parts, ", ");
end

local function BuildHotEffectIds()
    hotEffectIds = {};
    hotEffectIdsByAbility = {};
    hotEffectNamesByAbility = {};
    hotTrackedAbilityIds = {};

    for _, abilityId in ipairs(hotAbilityIds) do
        if (hotAbilityTrackEffect[abilityId] ~= false) then
            table.insert(hotTrackedAbilityIds, abilityId);
            AddHotEffectForAbility(abilityId, abilityId);

            if (hotAbilityEffectIds[abilityId]) then
                for _, effectId in ipairs(hotAbilityEffectIds[abilityId]) do
                    AddHotEffectForAbility(abilityId, effectId);
                end
            end

            if (hotAbilityEffectNames[abilityId]) then
                for _, effectName in ipairs(hotAbilityEffectNames[abilityId]) do
                    AddHotEffectNameForAbility(abilityId, effectName);
                end
            end
        end
    end

    if (HotbotConfig.HotEffectIdsByCareer and HotbotConfig.HotEffectIdsByCareer[myCareerLine]) then
        for _, effectId in pairs(HotbotConfig.HotEffectIdsByCareer[myCareerLine]) do
            AddHotEffectForAbility(hotAbilityId, effectId);
        end
    end
end

local function IsInHotRange(distance, isDistant)
    if (isDistant) then return false end
    distance = tonumber(distance);
    if (not distance or distance <= 0) then return false end
    if (distance >= (HotbotConfig.MaxTargetDistance or BUFF_DISTANCE)) then return false end
    return true;
end

function Hotbot.IsInKnownHotRange(distance, isDistant)
    return IsInHotRange(distance, isDistant);
end

local function NormalizeHealthPercent(value)
    value = tonumber(value);
    if (not value) then return 100 end
    if (value <= 1) then return value * 100 end
    return value;
end

local function GetSelfHealthPercent()
    if (GameData.Player.hitPoints and GameData.Player.hitPoints.maximum and GameData.Player.hitPoints.maximum > 0) then
        return NormalizeHealthPercent(GameData.Player.hitPoints.current / GameData.Player.hitPoints.maximum);
    end
    return 100;
end

local function GetMemberHealthPercent(member, groupIndex)
    local health = nil;

    if (member) then
        health = member.healthPercent or member.HealthPercent or member.health or member.Health;
    end

    if ((not health) and groupIndex and PartyUtils and PartyUtils.GetPartyMember) then
        local ok, partyMember = pcall(PartyUtils.GetPartyMember, groupIndex);
        if (ok and partyMember) then
            health = partyMember.healthPercent or partyMember.HealthPercent or partyMember.health or partyMember.Health;
        end
    end

    return NormalizeHealthPercent(health);
end

local function GetCurrentFriendlyTargetHealthPercent()
    if (not TargetInfo or not TargetInfo.UnitHealth) then return 100 end

    local ok, health = pcall(function()
        return TargetInfo:UnitHealth("selffriendlytarget");
    end);

    if (not ok) then return 100 end
    return NormalizeHealthPercent(health);
end

local function IsBetterTarget(candidate, currentBest)
    if (not candidate) then return false end
    if (not currentBest) then return true end

    local candidateHealth = candidate.healthPercent or 100;
    local bestHealth = currentBest.healthPercent or 100;
    if (candidateHealth < bestHealth) then return true end
    if (candidateHealth > bestHealth) then return false end

    local candidateRemaining = candidate.remaining or 0;
    local bestRemaining = currentBest.remaining or 0;
    if (candidateRemaining < bestRemaining) then return true end
    if (candidateRemaining > bestRemaining) then return false end

    return ((candidate.distance or 999999) < (currentBest.distance or 999999));
end

local function GetRosterPlayers(groupData)
    if (not groupData) then return nil end
    if (groupData.name or groupData.Name) then
        return { groupData };
    end
    return groupData.players or groupData.members;
end

local function ForEachRosterMember(players, callback)
    if (not players) then return end

    local seen = {};
    for key, member in ipairs(players) do
        seen[key] = true;
        callback(member);
    end

    for key, member in pairs(players) do
        if (not seen[key]) then
            callback(member);
        end
    end
end

local function GetMemberName(member)
    return (member and (member.name or member.Name));
end

local function GetMemberDistance(member, distances, name)
    if (not member) then return nil end
    return member.distance or member.Distance or member.range or member.Range or distances[name];
end

local function GetMemberDistant(member)
    return (member and (member.isDistant or member.IsDistant));
end

local function GetMemberIsLeader(member)
    return (member and (member.isGroupLeader or member.IsGroupLeader or member.isLeader or member.IsLeader));
end

local function IsMemberOnline(member)
    if (not member) then return false end
    if (member.online == false or member.Online == false or member.isOnline == false or member.IsOnline == false) then
        return false;
    end
    return true;
end

local OrderCareerLines =
{
    [GameData.CareerLine.RUNE_PRIEST] = true,
    [GameData.CareerLine.ARCHMAGE] = true,
    [GameData.CareerLine.WARRIOR_PRIEST] = true,
};

local DestructionCareerLines =
{
    [GameData.CareerLine.ZEALOT] = true,
    [GameData.CareerLine.SHAMAN] = true,
    [GameData.CareerLine.DISCIPLE] = true,
};

local CareerIdToLine =
{
    [20] = GameData.CareerLine.IRON_BREAKER,
    [100] = GameData.CareerLine.SWORDMASTER,
    [64] = GameData.CareerLine.CHOSEN,
    [24] = GameData.CareerLine.BLACK_ORC,
    [60] = GameData.CareerLine.WITCH_HUNTER,
    [102] = GameData.CareerLine.WHITE_LION or GameData.CareerLine.SEER,
    [65] = GameData.CareerLine.MARAUDER or GameData.CareerLine.WARRIOR,
    [105] = GameData.CareerLine.WITCH_ELF or GameData.CareerLine.ASSASSIN,
    [62] = GameData.CareerLine.BRIGHT_WIZARD,
    [67] = GameData.CareerLine.MAGUS,
    [107] = GameData.CareerLine.SORCERER,
    [23] = GameData.CareerLine.ENGINEER,
    [101] = GameData.CareerLine.SHADOW_WARRIOR,
    [27] = GameData.CareerLine.SQUIG_HERDER,
    [63] = GameData.CareerLine.WARRIOR_PRIEST,
    [106] = GameData.CareerLine.DISCIPLE or GameData.CareerLine.BLOOD_PRIEST,
    [103] = GameData.CareerLine.ARCHMAGE,
    [26] = GameData.CareerLine.SHAMAN,
    [22] = GameData.CareerLine.RUNE_PRIEST,
    [66] = GameData.CareerLine.ZEALOT,
    [104] = GameData.CareerLine.BLACKGUARD or GameData.CareerLine.SHADE,
    [61] = GameData.CareerLine.KNIGHT,
    [25] = GameData.CareerLine.CHOPPA,
    [21] = GameData.CareerLine.SLAYER,
};

local DpsCareerLines = {};

local function AddDpsCareer(careerLine)
    if (careerLine) then
        DpsCareerLines[careerLine] = true;
    end
end

AddDpsCareer(GameData.CareerLine.ENGINEER);
AddDpsCareer(GameData.CareerLine.BRIGHT_WIZARD);
AddDpsCareer(GameData.CareerLine.SORCERER);
AddDpsCareer(GameData.CareerLine.SQUIG_HERDER);
AddDpsCareer(GameData.CareerLine.MAGUS);
AddDpsCareer(GameData.CareerLine.SHADOW_WARRIOR);
AddDpsCareer(GameData.CareerLine.WITCH_ELF or GameData.CareerLine.ASSASSIN);
AddDpsCareer(GameData.CareerLine.WHITE_LION or GameData.CareerLine.SEER);
AddDpsCareer(GameData.CareerLine.SLAYER);
AddDpsCareer(GameData.CareerLine.WITCH_HUNTER);
AddDpsCareer(GameData.CareerLine.CHOPPA);
AddDpsCareer(GameData.CareerLine.MARAUDER or GameData.CareerLine.WARRIOR);

local function GetMemberCareerLine(member)
    if (not member) then return nil end

    local careerLine = member.careerLine or member.CareerLine or member.careerline;
    if (careerLine) then return careerLine end

    local careerId = member.careerId or member.CareerId or member.careerID or member.CareerID or member.career or member.Career;
    if (careerId and CareerIdToLine[careerId]) then
        return CareerIdToLine[careerId];
    end

    return careerId;
end

local function IsDpsMember(member)
    local careerLine = GetMemberCareerLine(member);
    return (careerLine and DpsCareerLines[careerLine] == true);
end

local function GetFriendlyArmyMapPip()
    if (OrderCareerLines[myCareerLine]) then return SystemData.MapPips.ORDER_ARMY end
    if (DestructionCareerLines[myCareerLine]) then return SystemData.MapPips.DESTRUCTION_ARMY end
    return nil;
end

local function IsNearbyFallbackMapPoint(pointType, friendlyPip)
    if (not pointType) then return false end
    if (friendlyPip and pointType == friendlyPip) then return true end

    -- These are still discovered from the local overhead map, not by scanning
    -- the group/warband rosters. Include them so nearby mode works while the
    -- player or surrounding allies happen to be grouped.
    if (pointType == SystemData.MapPips.GROUP_MEMBER) then return true end
    if (pointType == SystemData.MapPips.WARBAND_MEMBER) then return true end

    -- Nearby same-realm players can appear as generic player pips rather than army pips.
    -- Ability validation after targeting still rejects enemies, corpses, and invalid targets.
    return (pointType == SystemData.MapPips.PLAYER);
end

-- Expensive client data is immutable enough for the duration of one target
-- selection pass. Keep it only for that pass so layered ability/priority scans
-- see the same data without repeatedly calling the client APIs.
function Hotbot.BeginTargetScan()
    Hotbot.ScanCache = {
        buffs = {},
        buffsLoaded = {},
        unitEffects = {},
        unitEffectsLoaded = {},
        knownAbilities = {},
        targetChecks = {},
    };
end

function Hotbot.EndTargetScan(target)
    Hotbot.ScanCache = nil;
    return target;
end

function Hotbot.GetScanBuffs(buffTargetType)
    local cache = Hotbot.ScanCache;
    if (cache and cache.buffsLoaded[buffTargetType]) then
        return cache.buffs[buffTargetType];
    end

    local effects = GetBuffs(buffTargetType);
    if (cache) then
        cache.buffsLoaded[buffTargetType] = true;
        cache.buffs[buffTargetType] = effects;
    end
    return effects;
end

function Hotbot.GetScanUnitEffects(name)
    if (not name or name == L"") then return nil end
    local cache = Hotbot.ScanCache;
    if (cache and cache.unitEffectsLoaded[name]) then
        return cache.unitEffects[name];
    end

    local effects = nil;
    local ok = pcall(function()
        effects = GetUnitEffects(name);
    end);
    if (not ok) then
        effects = nil;
    end

    if (cache) then
        cache.unitEffectsLoaded[name] = true;
        cache.unitEffects[name] = effects;
    end
    return effects;
end

function Hotbot.GetScanWarbandData()
    local cache = Hotbot.ScanCache;
    if (cache and cache.warbandDataLoaded) then
        return cache.warbandData;
    end

    local data = PartyUtils.GetWarbandData();
    if (cache) then
        cache.warbandDataLoaded = true;
        cache.warbandData = data;
    end
    return data;
end

function Hotbot.GetScanScenarioData()
    local cache = Hotbot.ScanCache;
    if (cache and cache.scenarioDataLoaded) then
        return cache.scenarioData;
    end

    local data = GameData.GetScenarioPlayerGroups();
    if (cache) then
        cache.scenarioDataLoaded = true;
        cache.scenarioData = data;
    end
    return data;
end

local function GetWarbandDistances()
    if (Hotbot.ScanCache and Hotbot.ScanCache.warbandDistances) then
        return Hotbot.ScanCache.warbandDistances;
    end

    local distances = {};
    for idx = 1, MAX_MAP_POINTS do
        local pointData = GetMapPointData("EA_Window_OverheadMapMapDisplay", idx);
        if (pointData and pointData.name and MapPointTypeFilter[pointData.pointType]) then
            local pointName = StripRealm(pointData.name);
            local pointDistance = tonumber(pointData.distance);
            if (pointDistance and pointDistance > 0) then
                distances[pointName] = math.floor(pointDistance * DISTANCE_FIX);
            end
        end
    end
    if (Hotbot.ScanCache) then
        Hotbot.ScanCache.warbandDistances = distances;
    end
    return distances;
end

local function ScheduleTargetClear()
    -- Target selection belongs to the player. Unless explicitly opted in,
    -- verification and retry timers may update recommendations but must never
    -- clear or otherwise alter the live friendly/hostile target.
    if (not HotbotConfig or HotbotConfig.AllowAutomaticTargetClearing ~= true) then
        clearTargetsTimer = nil;
        return;
    end
    clearTargetsTimer = CLEAR_TARGET_DELAY;
end

local function ClearTargetsAfterCast()
    if (GameData.TargetType and GameData.TargetType.FRIENDLY) then
        pcall(ClearTarget, GameData.TargetType.FRIENDLY);
    end
    if (GameData.TargetType and GameData.TargetType.HOSTILE) then
        pcall(ClearTarget, GameData.TargetType.HOSTILE);
    end
    Hotbot.CurrentTarget = L"";
    if (nearbyModeEnabled) then
        cycleSelectionActive = false;
    end
end

local function ClearPendingTargetAutomation()
    pendingTargetCheckTimer = nil;
    pendingTargetCheckName = L"";
    clearTargetsTimer = nil;
end

local function CancelAutomationForManualTargetChange()
    ClearPendingTargetAutomation();
    pendingApplyCheckTimer = nil;
    pendingApplyCheckName = L"";
    pendingApplyCheckAbilityId = nil;
    bestTarget = nil;
    WindowSetGameActionTrigger("HotbotFrame", 0);
    WindowSetGameActionData("HotbotFrame", GameData.PlayerActions.NONE, 0, L"");
    throttleTimer = UPDATE_THROTTLE;
    flagBarUpdate = true;
end

-- Switch between the configured roster priority and nearby-area players.
-- Macro examples:
--   /script Hotbot.SetNearbyMode(true)
--   /script Hotbot.SetNearbyMode(false)
function Hotbot.SetNearbyMode(enabled)
    if (type(enabled) ~= "boolean") then
        ChatPrint("Hotbot nearby mode: use true or false.");
        return nearbyModeEnabled;
    end

    nearbyModeEnabled = enabled;
    Hotbot.ManualTargetLock = false;
    cycleSelectionActive = false;
    cycleKeyNoticeShown = false;
    bestTarget = nil;
    ClearPendingTargetAutomation();
    WindowSetGameActionTrigger("HotbotFrame", 0);
    WindowSetGameActionData("HotbotFrame", GameData.PlayerActions.NONE, 0, L"");
    throttleTimer = UPDATE_THROTTLE;
    flagBarUpdate = true;

    if (nearbyModeEnabled) then
        ChatPrint("Hotbot cycle mode ON: self first; then use Cycle Friendly Targets and click Hotbot to apply the HoT.");
    else
        ChatPrint("Hotbot cycle mode OFF: using group, warband, scenario, and configured priorities.");
    end

    return nearbyModeEnabled;
end

function Hotbot.ToggleNearbyMode()
    return Hotbot.SetNearbyMode(not nearbyModeEnabled);
end

function Hotbot.NearbyMode(enabled)
    return Hotbot.SetNearbyMode(enabled);
end

function Hotbot.CycleFriendlyTarget()
    if (nearbyModeEnabled and not cycleKeyNoticeShown) then
        ChatPrint("Hotbot: press your Cycle Friendly Targets key, then click Hotbot to apply the HoT.");
        cycleKeyNoticeShown = true;
    end
    return false;
end

function Hotbot.DisarmDisabledNearbyTarget()
    local disabledNearby = bestTarget and bestTarget.source == "nearby" and not Hotbot.IsNearbyFallbackEnabled();
    local disabledCycle = bestTarget and bestTarget.source == "cycle" and not Hotbot.IsNearbyModeEnabled();
    if (disabledNearby or disabledCycle) then
        WindowSetGameActionTrigger("HotbotFrame", 0);
        WindowSetGameActionData("HotbotFrame", GameData.PlayerActions.NONE, 0, L"");
        bestTarget = nil;
        ClearPendingTargetAutomation();
        flagBarUpdate = true;
        DebugSkip("nearby", "nearby fallback disabled");
        return true;
    end

    return false;
end

local function IsManualFriendlyTargetChange(targetName)
    if (not targetName or targetName == L"") then return false end
    if (Hotbot.IsNearbyModeEnabled()) then return false end

    -- A target confirmation requested by the immediately preceding Hotbot
    -- click is automated by that click. Any other newly selected friendly is
    -- owned by the player and Hotbot must remain passive.
    if (pendingTargetCheckTimer and pendingTargetCheckName == targetName) then
        return false;
    end

    if (targetName ~= Hotbot.CurrentTarget) then
        return true;
    end

    if (pendingTargetCheckTimer and pendingTargetCheckName ~= L"" and targetName ~= pendingTargetCheckName) then
        return true;
    end

    if (pendingApplyCheckTimer and pendingApplyCheckName ~= L"" and targetName ~= pendingApplyCheckName) then
        return true;
    end

    if (clearTargetsTimer and ((not pendingApplyCheckName) or pendingApplyCheckName == L"" or targetName ~= pendingApplyCheckName)) then
        return true;
    end

    return false;
end

local function GetAbilityCooldownSeconds(abilityId)
    if (not abilityId or not GetAbilityCooldown) then return 0 end

    local ok, cooldown = pcall(GetAbilityCooldown, abilityId);
    if (not ok or not cooldown) then return 0 end

    cooldown = tonumber(cooldown) or 0;
    if (cooldown <= 0) then return 0 end

    -- RoR exposes ability cooldowns in milliseconds.
    return cooldown / 1000;
end

local function GetAbilityCooldownDuration(abilityId)
    local configured = hotAbilityCooldownSeconds[abilityId];
    local cooldown = configured;
    if (not cooldown or cooldown <= 0) then
        cooldown = GetAbilityCooldownSeconds(abilityId);
    end

    local padding = Hotbot.AbilityCooldownPaddingSeconds[abilityId] or 0;
    return math.max(0, (cooldown or 0) + padding);
end

local function StartAbilityCooldown(abilityId)
    if (not abilityId) then return end

    local cooldown = GetAbilityCooldownDuration(abilityId);
    if (cooldown and cooldown > 0) then
        abilityCooldownsRemaining[abilityId] = cooldown;
    end
    Hotbot.CooldownPriorityRetryRemaining[abilityId] = nil;
end

local function UpdateAbilityCooldowns(elapsed)
    for abilityId, remaining in pairs(abilityCooldownsRemaining) do
        remaining = remaining - elapsed;
        if (remaining <= 0) then
            abilityCooldownsRemaining[abilityId] = nil;
        else
            abilityCooldownsRemaining[abilityId] = remaining;
        end
    end

    for abilityId, remaining in pairs(Hotbot.CooldownPriorityRetryRemaining) do
        remaining = remaining - elapsed;
        if (remaining <= 0) then
            Hotbot.CooldownPriorityRetryRemaining[abilityId] = nil;
        else
            Hotbot.CooldownPriorityRetryRemaining[abilityId] = remaining;
        end
    end
end

local function IsAbilityCoolingDown(abilityId)
    local remaining = abilityCooldownsRemaining[abilityId] or 0;
    local grace = HotbotConfig.CooldownReadyGrace or 0.1;
    return (remaining > grace);
end

function Hotbot.IsAbilityKnown(abilityId)
    if (not abilityId) then return false end

    local cache = Hotbot.ScanCache;
    if (cache and cache.knownAbilities[abilityId] ~= nil) then
        return cache.knownAbilities[abilityId];
    end

    local known = nil;

    if (Player and Player.GetAbilityData) then
        local ok, abilityData = pcall(Player.GetAbilityData, abilityId);
        if (ok) then known = (abilityData ~= nil) end
    end

    if (known == nil and GetAbilityData) then
        local ok, abilityData = pcall(GetAbilityData, abilityId);
        if (ok) then known = (abilityData ~= nil) end
    end

    if (known == nil and GetAbilityTable and GameData and GameData.AbilityType) then
        local ok, abilityData = pcall(GetAbilityTable, GameData.AbilityType.STANDARD);
        if (ok and abilityData) then known = (abilityData[abilityId] ~= nil) end
    end

    if (known == nil) then known = true end
    if (cache) then cache.knownAbilities[abilityId] = known end
    return known;
end

local function IsAbilityReady(abilityId)
    if (not abilityId) then return false end
    if (not Hotbot.IsAbilityKnown(abilityId)) then return false end
    if (IsAbilityCoolingDown(abilityId)) then return false end
    if (hotAbilitySkipEnabledCheck[abilityId]) then return true end

    if (not IsAbilityEnabled) then return true end

    local ok, enabled = pcall(IsAbilityEnabled, abilityId);
    if (not ok) then return true end
    return enabled == true;
end

local function IsAbilityReadyForEmergencyScan(abilityId)
    if (not abilityId) then return false end
    if (not Hotbot.IsAbilityKnown(abilityId)) then return false end
    -- GetAbilityCooldown can report the ability's base cooldown before a
    -- candidate target is selected, so discovery only checks Hotbot's local
    -- cooldown state. The actual cast path still calls IsAbilityReady after
    -- targeting and will refuse a cooldown-locked ability.
    return (not IsAbilityCoolingDown(abilityId));
end

local function GetMovementHoldSeconds()
    local seconds = tonumber(HotbotConfig.PlayerMovingHoldSeconds or 0.45);
    if (not seconds or seconds < 0) then return 0.45 end
    return seconds;
end

local function GetMovementThreshold()
    local threshold = tonumber(HotbotConfig.PlayerMovementThreshold or 3);
    if (not threshold or threshold < 0) then return 3 end
    return threshold;
end

local function IsPlayerMoving()
    return (playerMovingTimer and playerMovingTimer > 0);
end

local function UpdatePlayerMovementState(elapsed)
    if (not playerMovingTimer or playerMovingTimer <= 0) then
        playerMovingTimer = 0;
        return;
    end

    playerMovingTimer = playerMovingTimer - elapsed;
    if (playerMovingTimer < 0) then
        playerMovingTimer = 0;
    end
end

local function GetEffectsForTarget(target)
    if (not target or not target.name or target.name == L"") then return nil end

    if (target.name == myName) then
        return Hotbot.GetScanBuffs(GameData.BuffTargetType.SELF);
    end

    if (Hotbot.CurrentTarget == target.name) then
        return Hotbot.GetScanBuffs(GameData.BuffTargetType.TARGET_FRIENDLY);
    end

    return nil;
end

local function EffectMatchesAnyType(effect, effectTypes)
    if (not effect or not effectTypes) then return false end

    for _, effectType in ipairs(effectTypes) do
        if (effect[effectType] == true) then return true end
    end

    return false;
end

local function TargetMeetsPreTargetRequirements(target, abilityId)
    if (hotAbilityRequiresStationary[abilityId] and IsPlayerMoving()) then
        return false, "moving";
    end

    if (hotAbilityRequiresDamagedTarget[abilityId]) then
        local healthPercent = NormalizeHealthPercent(target and target.healthPercent);
        if (healthPercent >= 100) then
            return false, "target at full health";
        end
    end

    if (hotAbilityEmergencyHealthPercent[abilityId]) then
        local healthPercent = NormalizeHealthPercent(target and target.healthPercent);
        if (healthPercent <= 0) then
            return false, "target dead";
        end
        if (healthPercent >= hotAbilityEmergencyHealthPercent[abilityId]) then
            return false, "target above emergency threshold";
        end
    end

    return true, nil;
end

local function TargetMeetsAbilityRequirements(target, abilityId)
    local ok = TargetMeetsPreTargetRequirements(target, abilityId);
    if (not ok) then return false end

    local cleanseTypes = hotAbilityCleanseTypes[abilityId];
    if (not cleanseTypes) then return true end

    local effects = GetEffectsForTarget(target);
    if (not effects) then return false end

    for _, effect in pairs(effects) do
        if (effect and effect.name and EffectMatchesAnyType(effect, cleanseTypes)) then
            return true;
        end
    end

    return false;
end

local function HasReadyHotAbility(target)
    for _, abilityId in ipairs(hotAbilityIds) do
        if (IsAbilityReady(abilityId) and TargetMeetsAbilityRequirements(target, abilityId)) then return true end
    end
    return false;
end

local function IsHotValidOnCurrentTarget(target, abilityId)
    if (not target or not abilityId) then return false end
    if (Hotbot.CurrentTarget ~= target.name) then return false end

    if (not IsTargetValid) then return true end
    local ok, valid = pcall(IsTargetValid, abilityId);
    if (not ok) then return true end
    return valid == true;
end

local function SelectReadyAbilityForTarget(target)
    if (not target or not target.name or target.name == L"") then return nil end

    if (target.requiredAbilityId) then
        local abilityId = target.requiredAbilityId;
        if (IsAbilityReady(abilityId) and TargetMeetsAbilityRequirements(target, abilityId)) then
            if (target.isEmergency or target.name == myName or IsHotValidOnCurrentTarget(target, abilityId)) then
                return abilityId;
            end
        end
        return nil;
    end

    for _, abilityId in ipairs(hotAbilityIds) do
        if (IsAbilityReady(abilityId)) then
            if (TargetMeetsAbilityRequirements(target, abilityId) and (target.name == myName or IsHotValidOnCurrentTarget(target, abilityId))) then
                return abilityId;
            end
        end
    end

    return nil;
end

local function CanCastOnCurrentTarget(target)
    return (SelectReadyAbilityForTarget(target) ~= nil);
end

local ResetFailedApply;

local function MarkVerifiedCovered(name, remaining, abilityId)
    if (not name or name == L"" or not abilityId) then return end

    remaining = remaining or 0;
    if (remaining <= Hotbot.GetRefreshThreshold()) then
        if (verifiedCovered[name]) then
            verifiedCovered[name][abilityId] = nil;
            if (not next(verifiedCovered[name])) then
                verifiedCovered[name] = nil;
            end
        end
        return;
    end

    if (not verifiedCovered[name]) then
        verifiedCovered[name] = {};
    end

    verifiedCovered[name][abilityId] = remaining;
    ResetFailedApply(name);
end

local function IsVerifiedCovered(name, abilityId)
    abilityId = abilityId or currentScanAbilityId;
    if (not name or not abilityId or not verifiedCovered[name]) then return false end
    return (verifiedCovered[name][abilityId] and verifiedCovered[name][abilityId] > Hotbot.GetRefreshThreshold());
end

ResetFailedApply = function(name)
    if (not name or name == L"") then return end
    failedApplyAttempts[name] = nil;
    failedTargetSkips[name] = nil;
end

local function IsFailedSkipped(name)
    return (name and failedTargetSkips[name] and failedTargetSkips[name] > 0);
end

local function GetFailedApplyLimit()
    local limit = HotbotConfig.FailedApplyLimit or 1;
    if (limit < 1) then return 1 end
    return limit;
end

local function GetFailedTargetSkipSeconds()
    local seconds = HotbotConfig.FailedTargetSkipSeconds or 2;
    if (seconds < 0) then return 0 end
    return seconds;
end

function Hotbot.GetApplyVerifyDelay()
    local seconds = tonumber(HotbotConfig.ApplyVerifyDelay or APPLY_VERIFY_DELAY);
    if (not seconds or seconds < 0) then return APPLY_VERIFY_DELAY end
    return seconds;
end

function Hotbot.ShouldWaitForApplyBeforeNextTarget()
    return (HotbotConfig.WaitForApplyBeforeNextTarget == true);
end

function Hotbot.ShouldClearTargetAfterApplyVerify()
    return (HotbotConfig.AllowAutomaticTargetClearing == true
        and HotbotConfig.ClearTargetAfterApplyVerify == true);
end

function Hotbot.GetGlobalCooldownSeconds()
    local seconds = tonumber(HotbotConfig.GlobalCooldownSeconds or 1.5);
    if (not seconds or seconds < 0) then return 1.5 end
    return seconds;
end

function Hotbot.ShouldWaitForGlobalCooldownBeforeNextTarget()
    return (HotbotConfig.WaitForGlobalCooldownBeforeNextTarget ~= false);
end

function Hotbot.StartPostCastLock()
    local seconds = Hotbot.GetGlobalCooldownSeconds();
    if (seconds > postCastLockTimer) then
        postCastLockTimer = seconds;
    end
end

function Hotbot.UpdatePostCastLock(elapsed)
    if (postCastLockTimer and postCastLockTimer > 0) then
        postCastLockTimer = postCastLockTimer - elapsed;
        if (postCastLockTimer < 0) then postCastLockTimer = 0 end
    end
end

function Hotbot.IsPostCastLocked()
    return (Hotbot.ShouldWaitForGlobalCooldownBeforeNextTarget() and postCastLockTimer and postCastLockTimer > 0);
end

local function GetTargetVerifyDelay()
    local seconds = tonumber(HotbotConfig.TargetVerifyDelay or 0.75);
    if (not seconds or seconds < 0) then return 0.75 end
    return seconds;
end

local function GetTargetFailureSkipSeconds()
    local seconds = tonumber(HotbotConfig.TargetFailureSkipSeconds or 8);
    if (not seconds or seconds < 0) then return 8 end
    return seconds;
end

local function MarkFailedApply(name, reason)
    if (not name or name == L"") then return end
    if (name == myName) then return end

    local attempts = (failedApplyAttempts[name] or 0) + 1;
    failedApplyAttempts[name] = attempts;

    if (attempts >= GetFailedApplyLimit()) then
        failedApplyAttempts[name] = nil;
        failedTargetSkips[name] = GetFailedTargetSkipSeconds();
        DebugSkip(name, reason or "failed apply attempts");

        if (bestTarget and bestTarget.name == name) then
            bestTarget = nil;
        end
        flagBarUpdate = true;
        ScheduleTargetClear();
        return true;
    end

    return false;
end

local function SkipUncastableCurrentTarget(target)
    if (not target or not target.name or target.name == L"") then return false end
    local abilityId = SelectReadyAbilityForTarget(target);
    if (abilityId) then
        SetActiveAbility(abilityId);
        return false, abilityId;
    end

    WindowSetGameActionData("HotbotFrame", GameData.PlayerActions.NONE, 0, L"");
    if (target.requiredAbilityId and not Hotbot.IsAbilityKnown(target.requiredAbilityId)) then
        DebugSkip(target.name, GetAbilityLabel(target.requiredAbilityId) .. " not learned");
        return true;
    end
    if (target.requiredAbilityId and not IsAbilityReady(target.requiredAbilityId)) then
        DebugSkip(target.name, GetAbilityLabel(target.requiredAbilityId) .. " cooling down");
        return true;
    end
    if (target.requiredAbilityId and not TargetMeetsAbilityRequirements(target, target.requiredAbilityId)) then
        DebugSkip(target.name, GetAbilityLabel(target.requiredAbilityId) .. " conditions unmet");
        return true;
    end
    if (HasReadyHotAbility(target)) then
        if (target.source == "nearby") then
            failedApplyAttempts[target.name] = nil;
            failedTargetSkips[target.name] = GetTargetFailureSkipSeconds();
            DebugSkip(target.name, "nearby target invalid or out of range");

            if (bestTarget and bestTarget.name == target.name) then
                bestTarget = nil;
            end

            flagBarUpdate = true;
        else
            MarkFailedApply(target.name, "target invalid");
        end
        ScheduleTargetClear();
    else
        DebugSkip(target.name, "all configured abilities cooling down or conditions unmet");
    end
    return true;
end

local function ScheduleTargetVerify(target)
    if (not target or not target.name or target.name == L"") then return end
    pendingTargetCheckName = target.name;
    pendingTargetCheckTimer = GetTargetVerifyDelay();
end

local function ClearTargetVerify(name)
    if (not pendingTargetCheckTimer) then return end
    if ((not name) or name == pendingTargetCheckName) then
        pendingTargetCheckTimer = nil;
        pendingTargetCheckName = L"";
    end
end

local function MarkTargetFailed(name)
    if (not name or name == L"" or name == myName) then return end
    failedTargetSkips[name] = GetTargetFailureSkipSeconds();
    DebugSkip(name, "target failed or too far away");

    if (bestTarget and bestTarget.name == name) then
        bestTarget = nil;
    end

    WindowSetGameActionData("HotbotFrame", GameData.PlayerActions.NONE, 0, L"");
    flagBarUpdate = true;
end

local function UpdateFailedTargetSkips(elapsed)
    for name, remaining in pairs(failedTargetSkips) do
        remaining = remaining - elapsed;
        if (remaining <= 0) then
            failedTargetSkips[name] = nil;
        else
            failedTargetSkips[name] = remaining;
        end
    end
end

local function ShouldVerifyAbility(abilityId)
    if (abilityId and hotAbilityVerify[abilityId] == false) then return false end
    return true;
end

local function GetApplyHoldSeconds(abilityId)
    local seconds = tonumber(hotAbilityApplyHoldSeconds[abilityId] or 0);
    if (not seconds or seconds < 0) then return 0 end
    return seconds;
end

local function ScheduleApplyVerify(target, abilityId)
    if (not target or not target.name or target.name == L"") then return end
    abilityId = abilityId or activeAbilityId or hotAbilityId;
    if (not ShouldVerifyAbility(abilityId)) then return end

    local applyHoldSeconds = GetApplyHoldSeconds(abilityId);
    pendingApplyCheckName = target.name;
    pendingApplyCheckAbilityId = abilityId;
    pendingApplyCheckTimer = math.max(Hotbot.GetApplyVerifyDelay(), applyHoldSeconds);

    if (Hotbot.ShouldWaitForApplyBeforeNextTarget()) then
        clearTargetsTimer = nil;
    end
end

function Hotbot.SchedulePostCastTargetClear()
    if (pendingApplyCheckTimer and Hotbot.ShouldWaitForApplyBeforeNextTarget()) then return end
    ScheduleTargetClear();
end

local function UpdateVerifiedCovered(elapsed)
    for name, abilities in pairs(verifiedCovered) do
        for abilityId, remaining in pairs(abilities) do
            remaining = remaining - elapsed;
            if (remaining <= Hotbot.GetRefreshThreshold()) then
                abilities[abilityId] = nil;
            else
                abilities[abilityId] = remaining;
            end
        end

        if (not next(abilities)) then
            verifiedCovered[name] = nil;
        end
    end
end

-- HoT detection ------------------------------------------------------------
-- Returns the remaining duration (seconds) of the tracked HoT on a given effect list,
-- or 0 if the HoT is not present / has expired.

local function GetSingleHotDurationFromEffects(effects, allowMissingCaster, abilityId)
    if (not effects or not abilityId) then return 0 end
    if (not hotEffectIdsByAbility[abilityId] and not hotEffectNamesByAbility[abilityId]) then return 0 end

    for _, effect in pairs(effects) do
        local matchesId = (effect and hotEffectIdsByAbility[abilityId] and hotEffectIdsByAbility[abilityId][effect.abilityId]);
        local matchesName = EffectNameMatchesAbility(effect, abilityId);
        if (effect and (matchesId or matchesName) and (effect.castByPlayer or allowMissingCaster)) then
            local dur = effect.duration or 0;
            if (dur > Hotbot.GetRefreshThreshold()) then
                return dur;
            end
        end
    end
    return 0;
end

local function HasRequiredCleanseEffect(effects, abilityId)
    local cleanseTypes = hotAbilityCleanseTypes[abilityId];
    if (not effects or not cleanseTypes) then return false end

    for _, effect in pairs(effects) do
        if (effect and effect.name and EffectMatchesAnyType(effect, cleanseTypes)) then
            return true;
        end
    end

    return false;
end

local function GetHotDurationFromEffects(effects, allowMissingCaster, abilityId)
    abilityId = abilityId or currentScanAbilityId;
    if (not effects or not hotAbilityId) then return 0 end

    if (abilityId and hotAbilityCleanseTypes[abilityId]) then
        if (HasRequiredCleanseEffect(effects, abilityId)) then return 0 end
        return 999999;
    end

    if (abilityId) then
        return GetSingleHotDurationFromEffects(effects, allowMissingCaster, abilityId);
    end

    local minimumRemaining = nil;
    for _, trackedAbilityId in ipairs(hotTrackedAbilityIds) do
        local remaining = GetSingleHotDurationFromEffects(effects, allowMissingCaster, trackedAbilityId);
        if (remaining <= Hotbot.GetRefreshThreshold()) then
            return 0;
        end
        if ((not minimumRemaining) or remaining < minimumRemaining) then
            minimumRemaining = remaining;
        end
    end

    return minimumRemaining or 0;
end

local function ObserveHotOn(name, effects, allowMissingCaster, abilityId)
    abilityId = abilityId or currentScanAbilityId;
    local remaining = GetHotDurationFromEffects(effects, allowMissingCaster, abilityId);

    if (abilityId and hotAbilityTrackEffect[abilityId] ~= false) then
        MarkVerifiedCovered(name, remaining, abilityId);
    elseif (not abilityId) then
        for _, trackedAbilityId in ipairs(hotTrackedAbilityIds) do
            MarkVerifiedCovered(name, GetSingleHotDurationFromEffects(effects, allowMissingCaster, trackedAbilityId), trackedAbilityId);
        end
    end

    return remaining;
end

local function ObserveCurrentFriendlyTarget(abilityId)
    if (Hotbot.CurrentTarget == L"") then return 0 end
    return ObserveHotOn(Hotbot.CurrentTarget, Hotbot.GetScanBuffs(GameData.BuffTargetType.TARGET_FRIENDLY), false, abilityId);
end

local function CheckSelectedFriendlyTarget(source, requireFallbackEnabled)
    if (not hotAbilityId) then return nil end
    if (requireFallbackEnabled and HotbotConfig.EnableFriendlyTargetFallback == false) then return nil end
    if (not TargetInfo or not TargetInfo.UnitName) then return nil end

    pcall(function() TargetInfo:UpdateFromClient() end);

    local targetName = TargetInfo:UnitName("selffriendlytarget");
    if (not targetName or targetName == L"") then return nil end

    if (TargetInfo.UnitIsNPC) then
        local ok, isNpc = pcall(function()
            return TargetInfo:UnitIsNPC("selffriendlytarget");
        end);
        if (ok and isNpc) then return nil end
    end

    local pName = StripRealm(targetName);
    if (pName == L"" or pName == myName) then return nil end
    if (IsFailedSkipped(pName)) then return nil end

    Hotbot.CurrentTarget = pName;

    -- A selected-friendly fallback has no dependable roster distance. Ask the
    -- client whether the ability being scanned can actually use this target.
    local abilityId = currentScanAbilityId or activeAbilityId or hotAbilityId;
    if (abilityId and IsTargetValid) then
        local ok, valid = pcall(IsTargetValid, abilityId);
        if (ok and valid ~= true) then return nil end
    end

    local remaining = ObserveCurrentFriendlyTarget();
    if (remaining > Hotbot.GetRefreshThreshold()) then return nil end

    return {
        name            = pName,
        displayName     = pName,
        remaining       = remaining,
        source          = source or "target",
        distance        = nil,
        healthPercent   = GetCurrentFriendlyTargetHealthPercent(),
    };
end

local function CheckFriendlyTarget()
    return CheckSelectedFriendlyTarget("target", true);
end

local function CheckCycledFriendlyTarget()
    if (not nearbyModeEnabled or not cycleSelectionActive) then return nil end
    return CheckSelectedFriendlyTarget("cycle", false);
end

local function DisarmIfCurrentTargetCovered()
    local abilityId = nil;
    if (bestTarget) then
        abilityId = bestTarget.requiredAbilityId;
    end

    local remaining = ObserveCurrentFriendlyTarget(abilityId);
    if (remaining <= Hotbot.GetRefreshThreshold()) then return false end

    WindowSetGameActionData("HotbotFrame", GameData.PlayerActions.NONE, 0, L"");
    bestTarget = nil;
    flagBarUpdate = true;
    ScheduleTargetClear();
    return true;
end

local function VerifyPendingApply()
    local name = pendingApplyCheckName;
    local abilityId = pendingApplyCheckAbilityId;
    pendingApplyCheckName = L"";
    pendingApplyCheckAbilityId = nil;
    pendingApplyCheckTimer = nil;

    if (not name or name == L"") then return end
    if (name == myName) then
        if (Hotbot.ShouldClearTargetAfterApplyVerify()) then
            ScheduleTargetClear();
        end
        return;
    end

    local remaining = 0;
    if (Hotbot.CurrentTarget == name) then
        remaining = ObserveCurrentFriendlyTarget(abilityId);
    elseif (IsVerifiedCovered(name, abilityId)) then
        remaining = verifiedCovered[name][abilityId] or 0;
    end

    if (remaining > Hotbot.GetRefreshThreshold()) then
        ResetFailedApply(name);
        if (Hotbot.ShouldClearTargetAfterApplyVerify()) then
            ScheduleTargetClear();
        end
    else
        if (abilityId) then
            abilityCooldownsRemaining[abilityId] = nil;
        end
        MarkFailedApply(name, "apply not verified");
    end

    flagBarUpdate = true;
end

-- Scan self -----------------------------------------------------------------

local function CheckSelf()
    if (not hotAbilityId) then return nil end
    if (not IsCheckEnabled("SelfCheck")) then return nil end

    local effects = Hotbot.GetScanBuffs(GameData.BuffTargetType.SELF);
    local remaining = ObserveHotOn(myName, effects, true);
    if (remaining <= Hotbot.GetRefreshThreshold()) then
        return {
            name            = myName,
            displayName     = myName,
            remaining       = remaining,
            source          = "self",
            distance        = 0,
            healthPercent   = GetSelfHealthPercent(),
        };
    end
    return nil;
end

-- Scan group ----------------------------------------------------------------

local function CheckGroup()
    if (not hotAbilityId) then return nil end
    if (not IsCheckEnabled("GroupCheck")) then return nil end

    local best = nil;

    for idx = 1, MAX_GROUP_MEMBERS do
        local gm = LibGroup.GroupMembers.ByIndex[idx];
        if (gm and gm.IsValid and gm.IsAlive and gm.IsOnline) then
            local gmName = StripRealm(gm.Name);
            local gmDistant = gm.IsDistant;

            if (gmName ~= myName and not IsFailedSkipped(gmName) and Hotbot.IsInKnownHotRange(gm.Distance, gmDistant)) then
                -- Group member buff target type is offset from GROUP_MEMBER_START
                local buffTargetType = GameData.BuffTargetType.GROUP_MEMBER_START + idx - 1;
                local effects = Hotbot.GetScanBuffs(buffTargetType);
                local remaining = ObserveHotOn(gmName, effects);

                if (remaining <= Hotbot.GetRefreshThreshold()) then
                    local candidate = {
                        name            = gmName,
                        displayName     = gmName,
                        remaining       = remaining,
                        source          = "group",
                        buffTargetType  = buffTargetType,
                        distance        = gm.Distance,
                        healthPercent   = GetMemberHealthPercent(gm, idx),
                    };
                    if (IsBetterTarget(candidate, best)) then
                        best = candidate;
                    end
                end
            end
        end
    end
    return best;
end

local function FindGroupMemberByName(name)
    if (not name or name == L"") then return nil, nil end

    for idx = 1, MAX_GROUP_MEMBERS do
        local gm = LibGroup.GroupMembers.ByIndex[idx];
        if (gm and gm.Name and StripRealm(gm.Name) == name) then
            return gm, idx;
        end
    end

    return nil, nil;
end

local function ForEachWarbandMember(warbandData, callback)
    if (not warbandData) then return end

    local maxGroups = HotbotConfig.MaxWarbandGroups or 8;
    local _, firstEntry = next(warbandData);
    if (firstEntry and GetMemberName(firstEntry)) then
        ForEachRosterMember(warbandData, callback);
        return;
    end

    local seenGroups = {};
    for wbGroup = 1, maxGroups do
        seenGroups[wbGroup] = true;
        ForEachRosterMember(GetRosterPlayers(warbandData[wbGroup]), callback);
    end

    for key, groupData in pairs(warbandData) do
        if (not seenGroups[key]) then
            ForEachRosterMember(GetRosterPlayers(groupData), callback);
        end
    end
end

local function FindWarbandMemberByName(name, warbandData)
    if (not name or name == L"") then return nil end

    local found = nil;
    ForEachWarbandMember(warbandData, function(member)
        if (found) then return end
        local rawName = GetMemberName(member);
        if (rawName and StripRealm(rawName) == name) then
            found = member;
        end
    end);

    return found;
end

local function FindWarbandLeaderInData(warbandData)
    local leaderMember = nil;
    ForEachWarbandMember(warbandData, function(member)
        if (leaderMember) then return end
        if (GetMemberIsLeader(member) and GetMemberName(member)) then
            leaderMember = member;
        end
    end);

    if (leaderMember) then
        return StripRealm(GetMemberName(leaderMember)), leaderMember;
    end

    return nil, nil;
end

local function GetWarbandLeaderTarget(warbandData)
    if (PartyUtils and PartyUtils.GetWarbandLeader) then
        local ok, leaderInfo = pcall(PartyUtils.GetWarbandLeader);
        if (ok and leaderInfo and leaderInfo.name and leaderInfo.name ~= L"") then
            local leaderName = StripRealm(leaderInfo.name);
            local leaderMember = FindWarbandMemberByName(leaderName, warbandData) or leaderInfo;
            return leaderName, leaderMember;
        end
    end

    return FindWarbandLeaderInData(warbandData);
end

local function CheckWarbandLeader()
    if (not hotAbilityId) then return nil end
    if (not IsCheckEnabled("WarbandLeaderCheck")) then return nil end
    if (IsWarBandActive and not IsWarBandActive()) then return nil end

    local warbandData = Hotbot.GetScanWarbandData();
    if (not warbandData) then return nil end

    local leaderName, leaderMember = GetWarbandLeaderTarget(warbandData);
    if (not leaderName or leaderName == L"") then return nil end
    if (IsFailedSkipped(leaderName)) then return nil end
    if (IsVerifiedCovered(leaderName)) then return nil end

    if (leaderName == myName) then
        local effects = Hotbot.GetScanBuffs(GameData.BuffTargetType.SELF);
        local remaining = ObserveHotOn(myName, effects, true);
        if (remaining <= Hotbot.GetRefreshThreshold()) then
            return {
                name            = myName,
                displayName     = myName,
                remaining       = remaining,
                source          = "leader",
                distance        = 0,
                healthPercent   = GetSelfHealthPercent(),
            };
        end
        return nil;
    end

    local distances = GetWarbandDistances();
    local groupMember, groupIndex = FindGroupMemberByName(leaderName);
    if (groupMember) then
        leaderMember = groupMember;
    end

    local memberDistance = GetMemberDistance(leaderMember, distances, leaderName);
    local memberDistant = GetMemberDistant(leaderMember);
    local memberHealth = GetMemberHealthPercent(leaderMember, groupIndex);
    if (memberHealth <= 0) then return nil end
    if (not IsMemberOnline(leaderMember)) then return nil end
    if (not Hotbot.IsInKnownHotRange(memberDistance, memberDistant)) then
        DebugSkip(leaderName, "range unknown or out of range");
        return nil;
    end

    local effects = nil;
    if (groupIndex) then
        effects = Hotbot.GetScanBuffs(GameData.BuffTargetType.GROUP_MEMBER_START + groupIndex - 1);
    else
        effects = Hotbot.GetScanUnitEffects(leaderName);
    end

    local remaining = 0;
    if (effects) then
        remaining = ObserveHotOn(leaderName, effects);
    end

    if (remaining <= Hotbot.GetRefreshThreshold()) then
        return {
            name            = leaderName,
            displayName     = leaderName,
            remaining       = remaining,
            source          = "leader",
            distance        = memberDistance,
            healthPercent   = memberHealth,
        };
    end

    return nil;
end

-- Scan warband (other groups) -----------------------------------------------

local function CheckWarband()
    if (not hotAbilityId) then return nil end
    if (not IsCheckEnabled("WarbandCheck")) then return nil end

    local warbandData = Hotbot.GetScanWarbandData();
    if (not warbandData) then return nil end

    local distances = GetWarbandDistances();
    local best = nil;

    local function ConsiderMember(member)
        local rawName = GetMemberName(member);
        if (not rawName or rawName == L"") then return end

        local mName = StripRealm(rawName);
        if (mName == myName) then return end

        local memberDistance = GetMemberDistance(member, distances, mName);
        local memberDistant = GetMemberDistant(member);
        local memberHealth = GetMemberHealthPercent(member, nil);

        if ((not IsVerifiedCovered(mName)) and (not IsFailedSkipped(mName)) and IsMemberOnline(member) and memberHealth > 0 and Hotbot.IsInKnownHotRange(memberDistance, memberDistant)) then
            -- GetUnitEffects often returns nil for other warband groups.
            -- When it cannot see remote buffs, assume the HoT needs applying.
            local effects = Hotbot.GetScanUnitEffects(mName);

            local remaining = 0;
            if (effects) then
                remaining = ObserveHotOn(mName, effects);
            end

            if (remaining <= Hotbot.GetRefreshThreshold()) then
                local candidate = {
                    name            = mName,
                    displayName     = mName,
                    remaining       = remaining,
                    source          = "warband",
                    distance        = memberDistance,
                    healthPercent   = memberHealth,
                };
                if (IsBetterTarget(candidate, best)) then
                    best = candidate;
                end
            end
        end
    end

    ForEachWarbandMember(warbandData, ConsiderMember);

    return best;
end

-- Scan scenario / city roster ----------------------------------------------

local function GetScenarioGroupIndex(member)
    if (not member) then return nil end
    return member.sgroupindex or member.sGroupIndex or member.groupIndex or member.GroupIndex;
end

local function FindMyScenarioGroup(scenarioData)
    for _, member in ipairs(scenarioData) do
        if (member and member.name and StripRealm(member.name) == myName) then
            return GetScenarioGroupIndex(member);
        end
    end
    return nil;
end

local function ShouldScanScenarioMember(member, myScenarioGroup)
    local memberScenarioGroup = GetScenarioGroupIndex(member);

    if (myScenarioGroup and memberScenarioGroup) then
        if (memberScenarioGroup == myScenarioGroup) then
            return IsCheckEnabled("ScenarioPartyCheck"), "scenario party disabled";
        end
        return IsCheckEnabled("ScenarioWarbandCheck"), "scenario warband disabled";
    end

    return (IsCheckEnabled("ScenarioPartyCheck") or IsCheckEnabled("ScenarioWarbandCheck")), "scenario checks disabled";
end

local function CheckScenario()
    if (not hotAbilityId) then return nil end
    if (not GameData.Player.isInScenario and not GameData.Player.isInSiege) then return nil end

    local scenarioPartyEnabled = IsCheckEnabled("ScenarioPartyCheck");
    local scenarioWarbandEnabled = IsCheckEnabled("ScenarioWarbandCheck");
    if (not scenarioPartyEnabled and not scenarioWarbandEnabled) then return nil end

    local scenarioData = Hotbot.GetScanScenarioData();
    if (not scenarioData) then return nil end

    local distances = GetWarbandDistances();
    local filterScenarioGroups = (not scenarioPartyEnabled or not scenarioWarbandEnabled);
    local myScenarioGroup = nil;
    if (filterScenarioGroups) then
        myScenarioGroup = FindMyScenarioGroup(scenarioData);
    end
    local best = nil;

    for _, member in ipairs(scenarioData) do
        if (member and member.name and member.name ~= L"") then
            local mName = StripRealm(member.name);
            local shouldScan = true;
            local disabledReason = nil;
            if (filterScenarioGroups) then
                shouldScan, disabledReason = ShouldScanScenarioMember(member, myScenarioGroup);
            end

            if (mName == myName) then
                DebugSkip(mName, "self");
            elseif (not shouldScan) then
                DebugSkip(mName, disabledReason);
            elseif (IsFailedSkipped(mName)) then
                -- Already logged when the failed-attempt skip was created.
            elseif (IsVerifiedCovered(mName)) then
                DebugSkip(mName, "verified covered");
            else
                local memberDistance = member.distance or member.Distance or distances[mName];
                local memberHealth = GetMemberHealthPercent(member, nil);
                local memberDistant = member.isDistant or member.IsDistant;

                if (memberHealth <= 0) then
                    DebugSkip(mName, "dead");
                elseif (not Hotbot.IsInKnownHotRange(memberDistance, memberDistant)) then
                    DebugSkip(mName, "range unknown or out of range");
                else
                    local effects = Hotbot.GetScanUnitEffects(mName);

                    local remaining = 0;
                    if (effects) then
                        remaining = ObserveHotOn(mName, effects);
                    end

                    if (remaining <= Hotbot.GetRefreshThreshold()) then
                        local candidate = {
                            name            = mName,
                            displayName     = mName,
                            remaining       = remaining,
                            source          = "scenario",
                            distance        = memberDistance,
                            healthPercent   = memberHealth,
                        };
                        if (IsBetterTarget(candidate, best)) then
                            best = candidate;
                        end
                    end
                end
            end
        end
    end

    return best;
end

-- Scan DPS players ----------------------------------------------------------

local function CheckDps()
    if (not hotAbilityId) then return nil end
    if (not IsCheckEnabled("DpsCheck")) then return nil end

    local best = nil;
    local seen = {};

    local function ConsiderDpsCandidate(name, effects, distance, healthPercent, isDistant, requireKnownRange)
        if (not name or name == L"" or seen[name]) then return end
        seen[name] = true;

        if (name == myName) then return end
        if (IsFailedSkipped(name) or IsVerifiedCovered(name)) then return end
        if ((healthPercent or 100) <= 0) then return end
        if (requireKnownRange) then
            if (not Hotbot.IsInKnownHotRange(distance, isDistant)) then return end
        elseif (not IsInHotRange(distance, isDistant)) then
            return;
        end

        local remaining = 0;
        if (effects) then
            remaining = ObserveHotOn(name, effects);
        end

        if (remaining <= Hotbot.GetRefreshThreshold()) then
            local candidate = {
                name            = name,
                displayName     = name,
                remaining       = remaining,
                source          = "dps",
                distance        = distance,
                healthPercent   = healthPercent or 100,
            };
            if (IsBetterTarget(candidate, best)) then
                best = candidate;
            end
        end
    end

    if (IsCheckEnabled("GroupCheck")) then
        for idx = 1, MAX_GROUP_MEMBERS do
            local gm = LibGroup.GroupMembers.ByIndex[idx];
            if (gm and gm.IsValid and gm.IsAlive and gm.IsOnline and IsDpsMember(gm)) then
                local gmName = StripRealm(gm.Name);
                local gmDistant = gm.IsDistant;

                local buffTargetType = GameData.BuffTargetType.GROUP_MEMBER_START + idx - 1;
                ConsiderDpsCandidate(
                    gmName,
                    Hotbot.GetScanBuffs(buffTargetType),
                    gm.Distance,
                    GetMemberHealthPercent(gm, idx),
                    gmDistant,
                    true
                );
            end
        end
    end

    if ((GameData.Player.isInScenario or GameData.Player.isInSiege) and (IsCheckEnabled("ScenarioPartyCheck") or IsCheckEnabled("ScenarioWarbandCheck"))) then
        local scenarioData = Hotbot.GetScanScenarioData();
        if (scenarioData) then
            local distances = GetWarbandDistances();
            local filterScenarioGroups = (not IsCheckEnabled("ScenarioPartyCheck") or not IsCheckEnabled("ScenarioWarbandCheck"));
            local myScenarioGroup = nil;
            if (filterScenarioGroups) then
                myScenarioGroup = FindMyScenarioGroup(scenarioData);
            end

            for _, member in ipairs(scenarioData) do
                if (member and member.name and member.name ~= L"" and IsDpsMember(member)) then
                    local shouldScan = true;
                    if (filterScenarioGroups) then
                        shouldScan = ShouldScanScenarioMember(member, myScenarioGroup);
                    end

                    if (shouldScan) then
                        local mName = StripRealm(member.name);
                        local effects = Hotbot.GetScanUnitEffects(mName);

                        ConsiderDpsCandidate(
                            mName,
                            effects,
                            member.distance or member.Distance or distances[mName],
                            GetMemberHealthPercent(member, nil),
                            member.isDistant or member.IsDistant,
                            true
                        );
                    end
                end
            end
        end
    end

    if (IsCheckEnabled("WarbandCheck")) then
        local warbandData = Hotbot.GetScanWarbandData();
        if (warbandData) then
            local distances = GetWarbandDistances();
            ForEachWarbandMember(warbandData, function(member)
                if (member and IsMemberOnline(member) and IsDpsMember(member)) then
                    local rawName = GetMemberName(member);
                    if (rawName and rawName ~= L"") then
                        local mName = StripRealm(rawName);
                        local effects = Hotbot.GetScanUnitEffects(mName);

                        ConsiderDpsCandidate(
                            mName,
                            effects,
                            GetMemberDistance(member, distances, mName),
                            GetMemberHealthPercent(member, nil),
                            GetMemberDistant(member),
                            true
                        );
                    end
                end
            end);
        end
    end

    return best;
end

-- Scan nearby same-realm players outside the roster -------------------------

local function CheckNearbyAllies()
    if (not hotAbilityId) then return nil end
    if (not Hotbot.IsNearbyFallbackEnabled()) then return nil end

    local friendlyPip = GetFriendlyArmyMapPip();
    if (not friendlyPip) then return nil end

    local best = nil;
    for idx = 1, MAX_MAP_POINTS do
        local pointData = GetMapPointData("EA_Window_OverheadMapMapDisplay", idx);
        if (pointData and pointData.name and IsNearbyFallbackMapPoint(pointData.pointType, friendlyPip)) then
            local pName = StripRealm(pointData.name);
            local pointDistance = tonumber(pointData.distance);
            local distance = pointDistance and math.floor(pointDistance * DISTANCE_FIX) or nil;

            if (pName ~= myName and not IsVerifiedCovered(pName) and not IsFailedSkipped(pName) and Hotbot.IsInKnownHotRange(distance, false)) then
                local candidate = {
                    name            = pName,
                    displayName     = pName,
                    remaining       = 0,
                    source          = "nearby",
                    distance        = distance,
                    healthPercent   = 100,
                };
                if (IsBetterTarget(candidate, best)) then
                    best = candidate;
                end
            end
        end
    end

    return best;
end

function Hotbot.RunTargetCheck(checkName, check)
    if (not check) then return nil end

    local cache = Hotbot.ScanCache;
    if (not cache) then return check() end

    local abilityKey = currentScanAbilityId or 0;
    local abilityChecks = cache.targetChecks[abilityKey];
    if (not abilityChecks) then
        abilityChecks = {};
        cache.targetChecks[abilityKey] = abilityChecks;
    end

    if (abilityChecks[checkName] ~= nil) then
        return abilityChecks[checkName] or nil;
    end

    local target = check();
    abilityChecks[checkName] = target or false;
    return target;
end

function Hotbot.CheckLowestHealth()
    if (not hotAbilityId) then return nil end

    local best = nil;
    local healthThreshold = tonumber(HotbotConfig.LowestHealthThreshold) or 95;

    local function Consider(target)
        if (not target or not target.name or target.name == L"") then return end
        if (NormalizeHealthPercent(target.healthPercent) >= healthThreshold) then return end

        if (currentScanAbilityId) then
            local ok, reason = TargetMeetsPreTargetRequirements(target, currentScanAbilityId);
            if (not ok) then
                DebugSkip(target.name, GetAbilityLabel(currentScanAbilityId) .. " " .. tostring(reason or "conditions unmet"));
                return;
            end
        end

        if (IsBetterTarget(target, best)) then
            best = target;
        end
    end

    Consider(Hotbot.RunTargetCheck("self", CheckSelf));
    Consider(Hotbot.RunTargetCheck("warbandLeader", CheckWarbandLeader));
    Consider(Hotbot.RunTargetCheck("dps", CheckDps));
    Consider(Hotbot.RunTargetCheck("group", CheckGroup));
    Consider(Hotbot.RunTargetCheck("scenario", CheckScenario));
    Consider(Hotbot.RunTargetCheck("warband", CheckWarband));
    Consider(Hotbot.RunTargetCheck("target", CheckFriendlyTarget));

    if (Hotbot.IsNearbyFallbackEnabled()) then
        Consider(Hotbot.RunTargetCheck("nearby", CheckNearbyAllies));
    end

    return best;
end

function Hotbot.DebugNearby()
    local friendlyPip = GetFriendlyArmyMapPip();
    local totalNamed = 0;
    local acceptedPips = 0;
    local inRangeCandidates = 0;
    local skippedSelf = 0;
    local skippedCovered = 0;
    local skippedFailed = 0;
    local skippedRange = 0;
    local closestName = nil;
    local closestDistance = nil;
    local typeCounts = {};

    for idx = 1, MAX_MAP_POINTS do
        local pointData = GetMapPointData("EA_Window_OverheadMapMapDisplay", idx);
        if (pointData and pointData.name) then
            totalNamed = totalNamed + 1;
            local pointType = pointData.pointType;
            local pointTypeKey = tostring(pointType or "nil");
            typeCounts[pointTypeKey] = (typeCounts[pointTypeKey] or 0) + 1;

            if (IsNearbyFallbackMapPoint(pointType, friendlyPip)) then
                acceptedPips = acceptedPips + 1;
                local pName = StripRealm(pointData.name);
                local distance = math.floor((pointData.distance or 0) * DISTANCE_FIX);

                if (pName == myName) then
                    skippedSelf = skippedSelf + 1;
                elseif (IsVerifiedCovered(pName)) then
                    skippedCovered = skippedCovered + 1;
                elseif (IsFailedSkipped(pName)) then
                    skippedFailed = skippedFailed + 1;
                elseif (not IsInHotRange(distance, false)) then
                    skippedRange = skippedRange + 1;
                else
                    inRangeCandidates = inRangeCandidates + 1;
                    if ((not closestDistance) or distance < closestDistance) then
                        closestDistance = distance;
                        closestName = pName;
                    end
                end
            end
        end
    end

    local typeSummary = "";
    for pointType, count in pairs(typeCounts) do
        typeSummary = typeSummary .. pointType .. "=" .. tostring(count) .. " ";
    end

    ChatPrint("Hotbot nearby debug: enabled=" .. tostring(Hotbot.IsNearbyFallbackEnabled()) .. " nearbyOnly=" .. tostring(Hotbot.IsNearbyModeEnabled()) .. " abilities=" .. GetAbilitySummary() .. " friendlyPip=" .. tostring(friendlyPip));
    ChatPrint("Hotbot nearby debug: named=" .. tostring(totalNamed) .. " accepted=" .. tostring(acceptedPips) .. " candidates=" .. tostring(inRangeCandidates) .. " self=" .. tostring(skippedSelf) .. " covered=" .. tostring(skippedCovered) .. " failed=" .. tostring(skippedFailed) .. " range=" .. tostring(skippedRange));
    ChatPrint("Hotbot nearby debug: closest=" .. tostring(closestName or "none") .. " distance=" .. tostring(closestDistance or "?") .. " types=" .. typeSummary);
end

function Hotbot.DebugSelfBuffs()
    local effects = Hotbot.GetScanBuffs(GameData.BuffTargetType.SELF);
    local count = 0;

    ChatPrint("Hotbot self buffs: tracking abilities=" .. GetAbilitySummary() .. " threshold=" .. tostring(Hotbot.GetRefreshThreshold()));
    for _, effect in pairs(effects or {}) do
        if (effect and effect.abilityId) then
            count = count + 1;
            ChatPrint("Hotbot buff: id=" .. tostring(effect.abilityId) .. " name=" .. tostring(effect.name or "") .. " dur=" .. tostring(effect.duration or 0) .. " byMe=" .. tostring(effect.castByPlayer) .. " healing=" .. tostring(effect.isHealing));
        end
    end
    ChatPrint("Hotbot self buffs total=" .. tostring(count));
end

function Hotbot.DebugSerenity()
    local abilityId = 1601;
    local enabled = "n/a";
    if (IsAbilityEnabled) then
        local ok, value = pcall(IsAbilityEnabled, abilityId);
        enabled = ok and tostring(value) or "error";
    end

    local targetValid = "n/a";
    if (IsTargetValid) then
        local ok, value = pcall(IsTargetValid, abilityId);
        targetValid = ok and tostring(value) or "error";
    end

    ChatPrint(
        "Hotbot Serenity debug: ready=" .. tostring(IsAbilityReady(abilityId)) ..
        " cooldown=" .. tostring(abilityCooldownsRemaining[abilityId] or 0) ..
        " enabled=" .. tostring(enabled) ..
        " targetValid=" .. tostring(targetValid)
    );
    ChatPrint(
        "Hotbot Serenity debug: moving=" .. tostring(IsPlayerMoving()) ..
        " moveTimer=" .. tostring(playerMovingTimer or 0) ..
        " threshold=" .. tostring(GetMovementThreshold()) ..
        " hold=" .. tostring(GetMovementHoldSeconds()) ..
        " currentTarget=" .. tostring(Hotbot.CurrentTarget or "")
    );
    if (bestTarget) then
        ChatPrint(
            "Hotbot Serenity debug: best=" .. tostring(bestTarget.name or "") ..
            " required=" .. tostring(bestTarget.requiredAbilityName or bestTarget.requiredAbilityId or "") ..
            " source=" .. tostring(bestTarget.source or "")
        );
    else
        ChatPrint("Hotbot Serenity debug: best=none");
    end
end

-- Main scan -----------------------------------------------------------------

local DefaultTargetPriority =
{
    "self",
    "group",
    "warbandLeader",
    "dps",
    "scenario",
    "warband",
    "target",
};

local TargetChecks =
{
    self          = CheckSelf,
    group         = CheckGroup,
    warbandLeader = CheckWarbandLeader,
    leader        = CheckWarbandLeader,
    dps           = CheckDps,
    scenario      = CheckScenario,
    warband       = CheckWarband,
    target        = CheckFriendlyTarget,
    currentTarget = CheckFriendlyTarget,
    cycleTarget   = CheckCycledFriendlyTarget,
    nearby        = CheckNearbyAllies,
    lowestHealth  = Hotbot.CheckLowestHealth,
    lowestHp      = Hotbot.CheckLowestHealth,
    lowestHP      = Hotbot.CheckLowestHealth,
};

local function GetLayeredTargetPriorityCount()
    local count = tonumber(HotbotConfig.LayeredTargetPriorityCount or 0);
    if (not count or count < 1) then return 0 end
    return math.floor(count);
end

local function FindBestTargetInPriority(priority, priorityLimit)
    local checkedCount = 0;

    for _, checkName in ipairs(priority) do
        checkedCount = checkedCount + 1;
        if (priorityLimit and priorityLimit > 0 and checkedCount > priorityLimit) then
            break;
        end

        local check = TargetChecks[checkName];
        if (checkName == "nearby" and not Hotbot.IsNearbyFallbackEnabled()) then
            DebugSkip(checkName, "nearby fallback disabled");
        elseif (check) then
            local target = Hotbot.RunTargetCheck(checkName, check);
            if (target) then
                if (currentScanAbilityId) then
                    local ok, reason = TargetMeetsPreTargetRequirements(target, currentScanAbilityId);
                    if (ok) then
                        return target;
                    end
                    DebugSkip(target.name, GetAbilityLabel(currentScanAbilityId) .. " " .. tostring(reason or "conditions unmet"));
                else
                    return target;
                end
            end
        else
            DebugSkip(checkName, "unknown target priority");
        end
    end

    return nil;
end

local function FindBestTargetForAbility(priority, abilityId, priorityLimit)
    -- Stationary-only is a player-wide condition. Check it once before any
    -- roster/effect work instead of repeating an expensive scan while moving.
    if (hotAbilityRequiresStationary[abilityId] and IsPlayerMoving()) then
        DebugSkip(GetAbilityLabel(abilityId), "moving");
        return nil;
    end

    currentScanAbilityId = abilityId;
    local target = FindBestTargetInPriority(priority, priorityLimit);
    currentScanAbilityId = nil;

    if (target) then
        target.requiredAbilityId = abilityId;
        target.requiredAbilityName = GetAbilityLabel(abilityId);
        SetActiveAbility(abilityId);
    end

    return target;
end

local function FindBestTargetInLayers(priority, priorityLimit, startIndex, endIndex)
    startIndex = startIndex or 1;
    endIndex = endIndex or #hotTrackedAbilityIds;

    for idx = startIndex, endIndex do
        local abilityId = hotTrackedAbilityIds[idx];
        if (abilityId) then
            if (hotAbilityCastOnCooldown[abilityId]) then
                -- Already handled by the full-priority pass in FindBestTarget.
            elseif (not Hotbot.IsAbilityKnown(abilityId)) then
                DebugSkip(GetAbilityLabel(abilityId), "not learned");
            elseif (IsAbilityReady(abilityId)) then
                local target = FindBestTargetForAbility(priority, abilityId, priorityLimit);
                if (target) then
                    return target, false;
                end
            else
                DebugSkip(GetAbilityLabel(abilityId), "cooling down");
            end
        end
    end

    return nil, false;
end

local function FindBestCleanseTarget(priority)
    for _, abilityId in ipairs(hotAbilityIds) do
        if (hotAbilityCleanseTypes[abilityId] and IsAbilityReady(abilityId)) then
            local target = FindBestTargetForAbility(priority, abilityId, nil);
            if (target) then return target end
        end
    end

    return nil;
end

local function FindBestEmergencyTarget(priority)
    if (not emergencyAbilityIds or #emergencyAbilityIds == 0) then return nil end

    for _, checkName in ipairs(priority) do
        local check = TargetChecks[checkName];
        if (checkName == "nearby" and not Hotbot.IsNearbyFallbackEnabled()) then
            DebugSkip(checkName, "nearby fallback disabled");
        elseif (check) then
            for _, abilityId in ipairs(emergencyAbilityIds) do
                if (not Hotbot.IsAbilityKnown(abilityId)) then
                    DebugSkip(GetAbilityLabel(abilityId), "not learned");
                elseif (IsAbilityReadyForEmergencyScan(abilityId)) then
                    currentScanAbilityId = abilityId;
                    local target = Hotbot.RunTargetCheck(checkName, check);
                    currentScanAbilityId = nil;

                    if (target) then
                        local ok, reason = TargetMeetsPreTargetRequirements(target, abilityId);
                        if (ok) then
                            target.requiredAbilityId = abilityId;
                            target.requiredAbilityName = GetAbilityLabel(abilityId);
                            target.isEmergency = true;
                            SetActiveAbility(abilityId);
                            return target;
                        end
                        DebugSkip(target.name, GetAbilityLabel(abilityId) .. " " .. tostring(reason or "conditions unmet"));
                    end
                else
                    DebugSkip(GetAbilityLabel(abilityId), "cooling down");
                end
            end
        else
            DebugSkip(checkName, "unknown target priority");
        end
    end

    currentScanAbilityId = nil;
    return nil;
end

local function FindBestTarget()
    Hotbot.BeginTargetScan();
    local priority = nil;

    if (Hotbot.IsNearbyModeEnabled()) then
        priority = { "self", "cycleTarget" };
    else
        priority = HotbotConfig.TargetPriority or DefaultTargetPriority;
        if (type(priority) ~= "table") then
            priority = DefaultTargetPriority;
        end
    end

    local emergencyTarget = FindBestEmergencyTarget(priority);
    if (emergencyTarget) then return Hotbot.EndTargetScan(emergencyTarget) end

    -- Abilities explicitly marked castOnCooldown get one full target-priority
    -- pass before normal coverage layering. Their usual requirements still
    -- apply, including requiresStationary and requiresDamagedTarget.
    for _, abilityId in ipairs(hotTrackedAbilityIds) do
        if (hotAbilityCastOnCooldown[abilityId]
                and not Hotbot.CooldownPriorityRetryRemaining[abilityId]
                and IsAbilityReady(abilityId)) then
            local cooldownTarget = FindBestTargetForAbility(priority, abilityId, nil);
            if (cooldownTarget) then return Hotbot.EndTargetScan(cooldownTarget) end
            Hotbot.CooldownPriorityRetryRemaining[abilityId] = 0.5;
        end
    end

    local priorityLimit = GetLayeredTargetPriorityCount();
    if (priorityLimit > 0) then
        local priorityTarget, blocked = FindBestTargetInLayers(priority, priorityLimit, 1, 1);
        if (priorityTarget) then return Hotbot.EndTargetScan(priorityTarget) end
        if (blocked) then return Hotbot.EndTargetScan(nil) end

        local followupTarget, followupBlocked = FindBestTargetInLayers(priority, nil, 2, #hotTrackedAbilityIds);
        if (followupTarget) then return Hotbot.EndTargetScan(followupTarget) end
        if (followupBlocked) then return Hotbot.EndTargetScan(nil) end

        local primaryTarget, primaryBlocked = FindBestTargetInLayers(priority, nil, 1, 1);
        if (primaryTarget) then return Hotbot.EndTargetScan(primaryTarget) end
        if (primaryBlocked) then return Hotbot.EndTargetScan(nil) end

        return Hotbot.EndTargetScan(FindBestCleanseTarget(priority));
    end

    local target, blocked = FindBestTargetInLayers(priority, nil);
    if (target) then return Hotbot.EndTargetScan(target) end
    if (blocked) then return Hotbot.EndTargetScan(nil) end

    return Hotbot.EndTargetScan(FindBestCleanseTarget(priority));
end

-- Action wiring (arms the button for next click) ---------------------------

local function ArmButton()
    if (Hotbot.DisarmDisabledNearbyTarget()) then return end

    if (not bestTarget or not hotAbilityId) then
        WindowSetGameActionTrigger("HotbotFrame", 0);
        WindowSetGameActionData("HotbotFrame", GameData.PlayerActions.NONE, 0, L"");
        return;
    end

    if (Hotbot.CurrentTarget == bestTarget.name) then
        if (not DisarmIfCurrentTargetCovered()) then
            local skipped, abilityId = SkipUncastableCurrentTarget(bestTarget);
            if (skipped) then return end
            WindowSetGameActionTrigger("HotbotFrame", abilityId);
            WindowSetGameActionData("HotbotFrame", GameData.PlayerActions.DO_ABILITY, abilityId, L"");
        end
    else
        WindowSetGameActionTrigger("HotbotFrame", 0);
        WindowSetGameActionData("HotbotFrame", GameData.PlayerActions.SET_TARGET, 0, bestTarget.name);
    end
end

-- GUI update ---------------------------------------------------------------
-- Child window names are $parent-expanded at load time by WAR's XML engine,
-- so "HotbotFrame" + "$parentSpellIcon" becomes "HotbotFrameSpellIcon" etc.

local FRAME      = "HotbotFrame";
local labelName  = FRAME .. "TargetName";   -- $parentTargetName
local labelTimer = FRAME .. "Timer";         -- $parentTimer
local labelSrc   = FRAME .. "Source";        -- $parentSource
local iconEl     = FRAME .. "SpellIcon";     -- $parentSpellIcon

local function ApplyFrameStyle()
    WindowSetTintColor(FRAME .. "Background", 0, 0, 0);
    WindowSetAlpha(FRAME .. "Background", 1);
    WindowSetAlpha(FRAME, 1);
end

function Hotbot.GetRenderSignature()
    if (bestTarget) then
        local displayedValue = nil;
        if (bestTarget.isEmergency) then
            displayedValue = math.floor(bestTarget.healthPercent or 0);
        else
            displayedValue = math.floor(bestTarget.remaining or 0);
        end

        return table.concat({
            "target",
            tostring(bestTarget.displayName or bestTarget.name or ""),
            tostring(bestTarget.source or ""),
            tostring(bestTarget.isEmergency == true),
            tostring(displayedValue),
            tostring(bestTarget.distance and bestTarget.distance >= BUFF_DISTANCE or false),
            tostring(hotIconNum or 0),
        }, "|");
    end

    if (Hotbot.ManualTargetLock) then return "status|manual" end
    if (Hotbot.IsPostCastLocked()) then return "status|gcd" end
    if (Hotbot.IsNearbyModeEnabled()) then return "status|cycle" end
    return "status|covered";
end

local function UpdateBar()
    if (not isLoaded) then return end

    local renderSignature = Hotbot.GetRenderSignature();
    if (Hotbot.RenderSignature ~= renderSignature) then
        Hotbot.RenderSignature = renderSignature;

      if (bestTarget) then
        LabelSetText(labelName, bestTarget.displayName);

        -- Time remaining, colour-coded
        local remaining = bestTarget.remaining or 0;
        if (bestTarget.isEmergency) then
            local hp = math.floor(bestTarget.healthPercent or 0);
            LabelSetText(labelTimer, towstring(tostring(hp) .. "%"));
            LabelSetTextColor(labelTimer, 200, 40, 40);
        else
            local m = math.floor(remaining / 60);
            local s = math.floor(remaining - m * 60);
            LabelSetText(labelTimer, towstring(string.format("%02d:%02d", m, s)));

            local r, g, b = 255, 255, 255;
            if   (remaining <= 5)  then r, g, b = 200, 40, 40;
            elseif (remaining <= 20) then r, g, b = 255, 160, 0;
            end
            LabelSetTextColor(labelTimer, r, g, b);
        end

        -- Source label
        local srcStr = L"";
        if (bestTarget.source == "self")    then srcStr = L"[Self]"    end
        if (bestTarget.source == "group")   then srcStr = L"[Group]"   end
        if (bestTarget.source == "warband") then srcStr = L"[Warband]" end
        if (bestTarget.source == "scenario") then srcStr = L"[Scenario]" end
        if (bestTarget.source == "leader")  then srcStr = L"[Leader]"  end
        if (bestTarget.source == "dps")     then srcStr = L"[DPS]"     end
        if (bestTarget.source == "target")  then srcStr = L"[Target]"  end
        if (bestTarget.source == "cycle")   then srcStr = L"[Cycle]"   end
        if (bestTarget.source == "nearby")  then srcStr = L"[Nearby]"  end
        if (bestTarget.isEmergency)         then srcStr = L"[Emerg]"   end
        LabelSetText(labelSrc, srcStr);

        -- Distance tint on the icon
        local dist = bestTarget.distance;
        if (dist and dist >= BUFF_DISTANCE) then
            WindowSetTintColor(iconEl, 165, 12, 8);
        else
            WindowSetTintColor(iconEl, 255, 255, 255);
        end

        -- Spell icon
        if (hotIconNum and hotIconNum > 0) then
            local tex, texX, texY = GetIconData(hotIconNum);
            DynamicImageSetTexture(iconEl, tex, texX, texY);
            DynamicImageSetTextureScale(iconEl, 1);
            DynamicImageSetTextureDimensions(iconEl, 50, 50);
            WindowSetShowing(iconEl, true);
        end

      else
        -- Everything is covered, unless the next cast is still GCD-locked.
        if (Hotbot.ManualTargetLock) then
            LabelSetText(labelName,  L"Manual target");
        elseif (Hotbot.IsPostCastLocked()) then
            LabelSetText(labelName,  L"GCD Wait");
        elseif (Hotbot.IsNearbyModeEnabled()) then
            LabelSetText(labelName,  L"Use Cycle key");
        else
            LabelSetText(labelName,  L"All covered");
        end
        LabelSetText(labelTimer, L"");
        LabelSetText(labelSrc,   L"");
        WindowSetShowing(iconEl, false);
        WindowSetTintColor(iconEl, 255, 255, 255);
      end
    end

    if (not Hotbot.ManualTargetLock) then
        ArmButton();
    end
end

local function RequestHotCommandTarget(targetName, verbose)
    if (not targetName or targetName == L"") then return false end

    WindowSetGameActionData(FRAME, GameData.PlayerActions.SET_TARGET, 0, targetName);

    local actionRunner = clientWindowGameAction or WindowGameAction;
    local ok = false;
    local err = nil;
    if (actionRunner) then
        ok, err = pcall(actionRunner, FRAME);
    end

    SendChatText(L"/target " .. targetName, L"");

    if (verbose) then
        if (ok) then
            if (WindowGameAction ~= actionRunner) then
                ChatPrint("Hotbot HoT: using cached WindowGameAction.");
            end
            ChatPrint("Hotbot HoT: requested target " .. tostring(targetName) .. ".");
        elseif (err) then
            ChatPrint("Hotbot HoT: target request failed: " .. tostring(err));
        else
            ChatPrint("Hotbot HoT: target request could not use WindowGameAction.");
        end
    end

    return ok;
end

local function ExecuteHotCommandAction(verbose)
    if (not isLoaded or not hotAbilityId or not bestTarget) then return false end

    if (Hotbot.CurrentTarget ~= bestTarget.name) then
        if (verbose) then
            ChatPrint("Hotbot HoT: waiting for target " .. tostring(bestTarget.name) .. ".");
        end
        return false;
    end

    if (DisarmIfCurrentTargetCovered()) then
        if (verbose) then
            ChatPrint("Hotbot HoT: " .. tostring(bestTarget.name) .. " is already covered.");
        end
        return true;
    end

    local skipped, abilityId = SkipUncastableCurrentTarget(bestTarget);
    if (skipped) then
        if (verbose) then
            ChatPrint("Hotbot HoT: " .. tostring(bestTarget.name) .. " is not castable right now.");
        end
        return true;
    end

    WindowSetGameActionTrigger(FRAME, abilityId);
    WindowSetGameActionData(FRAME, GameData.PlayerActions.DO_ABILITY, abilityId, L"");

    local actionRunner = clientWindowGameAction or WindowGameAction;
    if (actionRunner) then
        local ok, err = pcall(actionRunner, FRAME);
        if (verbose) then
            if (ok) then
                if (WindowGameAction ~= actionRunner) then
                    ChatPrint("Hotbot HoT: using cached WindowGameAction.");
                end
                ChatPrint("Hotbot HoT: requested " .. GetAbilityLabel(abilityId) .. " on " .. tostring(bestTarget.name) .. ".");
            else
                ChatPrint("Hotbot HoT: WindowGameAction failed: " .. tostring(err));
            end
        end

        if (ok) then
            StartAbilityCooldown(abilityId);
            Hotbot.StartPostCastLock();
            ScheduleApplyVerify(bestTarget, abilityId);
            Hotbot.SchedulePostCastTargetClear();
        end
    else
        ChatPrint("Hotbot HoT: WindowGameAction is not available in this context.");
    end

    return true;
end

-- Event handlers -----------------------------------------------------------

function Hotbot.OnTargetUpdated(classification)
    if (classification == "selffriendlytarget") then
        TargetInfo:UpdateFromClient();
        local targetName = TargetInfo:UnitName("selffriendlytarget");
        local newTargetName = L"";
        if (targetName and targetName ~= L"") then
            newTargetName = StripRealm(targetName);
        end

        if (IsManualFriendlyTargetChange(newTargetName)) then
            -- A delayed apply verification or post-cast clear must never act on
            -- a friendly target the player selected manually afterward.
            CancelAutomationForManualTargetChange();
            Hotbot.ManualTargetLock = true;
        end

        Hotbot.CurrentTarget = newTargetName;
        if (Hotbot.IsNearbyModeEnabled()) then
            -- NEXT_FRIENDLY_TARGET is a protected client keybinding rather than
            -- a broadcastable UI event. A real friendly-target update is the
            -- reliable signal that the player used the native cycle action.
            cycleSelectionActive = (newTargetName ~= L"");
            cycleKeyNoticeShown = false;
            throttleTimer = UPDATE_THROTTLE;
            flagBarUpdate = true;
        end
        if (Hotbot.CurrentTarget ~= L"") then
            ClearTargetVerify(Hotbot.CurrentTarget);
        end
        -- Re-arm now that target is confirmed
        if (bestTarget and Hotbot.CurrentTarget == bestTarget.name and hotAbilityId) then
            if (not DisarmIfCurrentTargetCovered()) then
                local skipped, abilityId = SkipUncastableCurrentTarget(bestTarget);
                if (skipped) then return end
                WindowSetGameActionTrigger("HotbotFrame", abilityId);
                WindowSetGameActionData("HotbotFrame", GameData.PlayerActions.DO_ABILITY, abilityId, L"");
            end
        end
    end
end

function Hotbot.OnEffectsUpdated()
    if (Hotbot.CurrentTarget ~= L"") then
        ObserveCurrentFriendlyTarget();
    end
    if (myName ~= L"") then
        ObserveHotOn(myName, Hotbot.GetScanBuffs(GameData.BuffTargetType.SELF), true);
    end
    flagBarUpdate = true;
end

function Hotbot.OnPlayerBeginCast(abilityId)
    abilityId = tonumber(abilityId);
    if (not abilityId or not hotAbilityCooldownSeconds[abilityId]) then return end

    Hotbot.CastingTrackedAbilityId = abilityId;

    -- Immediately suppress the suggestion for the duration of the cast and
    -- cooldown. PLAYER_END_CAST will replace this fallback with an exact timer.
    StartAbilityCooldown(abilityId);
    throttleTimer = UPDATE_THROTTLE;
    flagBarUpdate = true;
end

function Hotbot.OnPlayerEndCast(failed)
    local abilityId = Hotbot.CastingTrackedAbilityId;
    Hotbot.CastingTrackedAbilityId = nil;
    if (not abilityId) then return end

    if (failed) then
        -- An interrupted cast never started its real cooldown.
        abilityCooldownsRemaining[abilityId] = nil;
    else
        -- RoR starts this cooldown when the 1-second cast completes. Anchoring
        -- here avoids the click-path timing drift that made the suggestion
        -- appear while the client still showed the ability on cooldown.
        local cooldown = hotAbilityCooldownSeconds[abilityId];
        if (not cooldown or cooldown <= 0) then
            cooldown = GetAbilityCooldownSeconds(abilityId);
        end
        if (cooldown and cooldown > 0) then
            abilityCooldownsRemaining[abilityId] = cooldown;
        end
    end

    Hotbot.CooldownPriorityRetryRemaining[abilityId] = nil;
    bestTarget = nil;
    throttleTimer = UPDATE_THROTTLE;
    flagBarUpdate = true;
end

function Hotbot.OnZoneChange()
    playerMovingTimer = 0;
    lastPlayerWorldX = nil;
    lastPlayerWorldY = nil;
    cycleSelectionActive = false;
    cycleKeyNoticeShown = false;
    Hotbot.ManualTargetLock = false;
    flagBarUpdate = true;
end

function Hotbot.OnPlayerPositionUpdated(newWorldX, newWorldY)
    newWorldX = tonumber(newWorldX);
    newWorldY = tonumber(newWorldY);
    if (not newWorldX or not newWorldY) then return end

    if (lastPlayerWorldX and lastPlayerWorldY) then
        local dx = newWorldX - lastPlayerWorldX;
        local dy = newWorldY - lastPlayerWorldY;
        local threshold = GetMovementThreshold();
        if ((dx * dx + dy * dy) > (threshold * threshold)) then
            playerMovingTimer = GetMovementHoldSeconds();
        end
    end

    lastPlayerWorldX = newWorldX;
    lastPlayerWorldY = newWorldY;
end

function Hotbot.OnLoadComplete()
    if (isLoaded) then return end

    local currentCareerLine = nil;
    if (GameData and GameData.Player and GameData.Player.career) then
        currentCareerLine = GameData.Player.career.line;
    end

    -- A known, unsupported career never registers Hotbot's gameplay events or
    -- action. Pause retries without resetting state used by healer loading.
    if (currentCareerLine and currentCareerLine ~= 0 and not IsCareerConfigured(currentCareerLine)) then
        WindowSetShowing("HotbotFrame", false);
        WindowSetGameActionData("HotbotFrame", GameData.PlayerActions.NONE, 0, L"");
        isUnsupportedCareer = true;
        return;
    end

    isUnsupportedCareer = false;

    if (not IsPlayerDataReady()) then
        loadRetryTimer = 0.5;
        return;
    end

    myCareerLine = GameData.Player.career.line;
    myName       = StripRealm(GameData.Player.name);
    BuildHotAbilities();
    BuildHotEffectIds();

    if (hotAbilityId) then
        SetActiveAbility(hotAbilityId);
        ChatPrint("Hotbot v" .. VERSION .. " loaded. Configured abilities: " .. GetAbilitySummary());
    else
        ChatPrint("Hotbot: No HoT abilities configured for career line " .. tostring(myCareerLine) .. ". Edit Config.lua.");
    end

    Hotbot.CurrentTarget = L"";

    WindowSetDimensions("HotbotFrame", 240, 104);
    WindowSetMovable("HotbotFrame", false);
    ApplyFrameStyle();
    LayoutEditor.RegisterWindow("HotbotFrame", L"Hotbot", L"Hotbot HoT tracker", false, false, true, nil);

    registeredEvents = {};
    table.insert(registeredEvents, CreateEvent(SystemData.Events.PLAYER_TARGET_UPDATED,  "Hotbot.OnTargetUpdated"));
    table.insert(registeredEvents, CreateEvent(SystemData.Events.PLAYER_EFFECTS_UPDATED, "Hotbot.OnEffectsUpdated"));
    table.insert(registeredEvents, CreateEvent(SystemData.Events.GROUP_EFFECTS_UPDATED,  "Hotbot.OnEffectsUpdated"));
    table.insert(registeredEvents, CreateEvent(SystemData.Events.PLAYER_ZONE_CHANGED,    "Hotbot.OnZoneChange"));
    table.insert(registeredEvents, CreateEvent(SystemData.Events.RELOAD_INTERFACE,       "Hotbot.OnLoadComplete"));
    if (SystemData.Events.PLAYER_BEGIN_CAST) then
        table.insert(registeredEvents, CreateEvent(SystemData.Events.PLAYER_BEGIN_CAST, "Hotbot.OnPlayerBeginCast"));
    end
    if (SystemData.Events.PLAYER_END_CAST) then
        table.insert(registeredEvents, CreateEvent(SystemData.Events.PLAYER_END_CAST, "Hotbot.OnPlayerEndCast"));
    end
    if (SystemData.Events.PLAYER_POSITION_UPDATED) then
        table.insert(registeredEvents, CreateEvent(SystemData.Events.PLAYER_POSITION_UPDATED, "Hotbot.OnPlayerPositionUpdated"));
    end
    RegisterEvents(registeredEvents, true);

    WindowSetShowing("HotbotFrame", true);
    Hotbot.RenderSignature = nil;
    loadRetryTimer = 0;
    loadRetryElapsed = 0;
    loadRetryAnnounced = false;
    isLoaded    = true;
    flagBarUpdate = true;
end

function Hotbot.OnUnload()
    if (not isLoaded) then return end
    LayoutEditor.UnregisterWindow("HotbotFrame");
    RegisterEvents(registeredEvents, false);
    WindowSetShowing("HotbotFrame", false);
    isLoaded = false;
end

local function ResetForPlayerDataChange()
    if (isLoaded) then
        LayoutEditor.UnregisterWindow("HotbotFrame");
        RegisterEvents(registeredEvents, false);
        WindowSetShowing("HotbotFrame", false);
    end

    registeredEvents = {};
    isLoaded = false;
    bestTarget = nil;
    Hotbot.CurrentTarget = L"";
    hotAbilityId = nil;
    activeAbilityId = nil;
    hotAbilityIds = {};
    hotAbilityNames = {};
    emergencyAbilityIds = {};
    hotAbilityEmergencyHealthPercent = {};
    hotTrackedAbilityIds = {};
    hotEffectIds = {};
    hotEffectIdsByAbility = {};
    hotEffectNamesByAbility = {};
    abilityCooldownsRemaining = {};
    Hotbot.CooldownPriorityRetryRemaining = {};
    Hotbot.CastingTrackedAbilityId = nil;
    Hotbot.ManualTargetLock = false;
    Hotbot.ScanCache = nil;
    Hotbot.RenderSignature = nil;
    verifiedCovered = {};
    failedApplyAttempts = {};
    failedTargetSkips = {};
    cycleSelectionActive = false;
    cycleKeyNoticeShown = false;
    pendingApplyCheckTimer = nil;
    pendingApplyCheckName = L"";
    pendingApplyCheckAbilityId = nil;
    postCastLockTimer = 0;
    ClearPendingTargetAutomation();
    throttleTimer = 0;
    loadRetryTimer = 0;
    loadRetryElapsed = 0;
    loadRetryAnnounced = false;
    flagBarUpdate = true;
    WindowSetGameActionData("HotbotFrame", GameData.PlayerActions.NONE, 0, L"");
end

-- Main update loop ---------------------------------------------------------

function Hotbot.OnUpdate(elapsed)
    if (not isLoaded) then
        if (isUnsupportedCareer) then
            local currentCareerLine = nil;
            if (GameData and GameData.Player and GameData.Player.career) then
                currentCareerLine = GameData.Player.career.line;
            end
            if (not currentCareerLine or currentCareerLine == 0 or not IsCareerConfigured(currentCareerLine)) then
                return;
            end
            isUnsupportedCareer = false;
            loadRetryTimer = 0;
        end

        loadRetryTimer = loadRetryTimer - elapsed;
        loadRetryElapsed = loadRetryElapsed + elapsed;

        if (loadRetryTimer <= 0) then
            Hotbot.OnLoadComplete();
            if (not isLoaded) then
                loadRetryTimer = 0.5;
                if ((not loadRetryAnnounced) and loadRetryElapsed >= 10) then
                    ChatPrint("Hotbot: waiting for player data before loading.");
                    loadRetryAnnounced = true;
                end
            end
        end
        return;
    end

    if (PlayerDataChangedSinceLoad()) then
        ResetForPlayerDataChange();
        Hotbot.OnLoadComplete();
        return;
    end

    UpdateAbilityCooldowns(elapsed);
    Hotbot.UpdatePostCastLock(elapsed);
    UpdatePlayerMovementState(elapsed);
    UpdateVerifiedCovered(elapsed);
    UpdateFailedTargetSkips(elapsed);
    Hotbot.DisarmDisabledNearbyTarget();

    if (Hotbot.ManualTargetLock) then
        bestTarget = nil;
        -- CancelAutomationForManualTargetChange disarms once when the lock is
        -- acquired. Do not repeat protected window writes every rendered frame.
        if (flagBarUpdate) then
            UpdateBar();
            flagBarUpdate = false;
        end
        return;
    end

    if (pendingApplyCheckTimer) then
        pendingApplyCheckTimer = pendingApplyCheckTimer - elapsed;
        if (pendingApplyCheckTimer <= 0) then
            VerifyPendingApply();
        end
    end

    if (pendingApplyCheckTimer and Hotbot.ShouldWaitForApplyBeforeNextTarget()) then
        if (flagBarUpdate) then
            UpdateBar();
            flagBarUpdate = false;
        end
        return;
    end

    if (Hotbot.IsPostCastLocked()) then
        if (flagBarUpdate) then
            UpdateBar();
            flagBarUpdate = false;
        end
        return;
    end

    if (pendingTargetCheckTimer) then
        pendingTargetCheckTimer = pendingTargetCheckTimer - elapsed;
        if (pendingTargetCheckTimer <= 0) then
            local targetName = pendingTargetCheckName;
            pendingTargetCheckTimer = nil;
            pendingTargetCheckName = L"";
            if (targetName and targetName ~= L"" and Hotbot.CurrentTarget ~= targetName) then
                MarkTargetFailed(targetName);
            end
        end
    end

    if (clearTargetsTimer) then
        clearTargetsTimer = clearTargetsTimer - elapsed;
        if (clearTargetsTimer <= 0) then
            clearTargetsTimer = nil;
            ClearTargetsAfterCast();
        end
    end

    throttleTimer = throttleTimer + elapsed;
    if (throttleTimer < UPDATE_THROTTLE) then return end
    throttleTimer = 0;

    bestTarget    = FindBestTarget();
    flagBarUpdate = true;

    if (flagBarUpdate) then
        UpdateBar();
        flagBarUpdate = false;
    end
end

-- Button left-click --------------------------------------------------------
-- The XML OnLButtonUp fires this. By the time the click lands, ArmButton()
-- has already set WindowSetGameActionData on the frame, so WAR fires the
-- game action automatically on LButtonUp. This function is a safety net
-- for cases where the target changed between arm and click.

function Hotbot.OnButtonClick()
    ClearPendingTargetAutomation();
    if (Hotbot.DisarmDisabledNearbyTarget()) then return end

    if (not isLoaded or not hotAbilityId) then return end

    if (Hotbot.ManualTargetLock) then
        Hotbot.ManualTargetLock = false;
        bestTarget = FindBestTarget();
        UpdateBar();
    end

    -- RoR does not expose NEXT_FRIENDLY_TARGET as an addon-callable event. The
    -- real client key changes the target; OnTargetUpdated then arms the HoT.
    if (Hotbot.IsNearbyModeEnabled() and not bestTarget) then
        Hotbot.CycleFriendlyTarget();
        return;
    end

    if (not bestTarget) then return end

    if (Hotbot.CurrentTarget ~= bestTarget.name) then
        -- Target not yet selected — switch target; next click will cast
        WindowSetGameActionTrigger("HotbotFrame", 0);
        WindowSetGameActionData("HotbotFrame", GameData.PlayerActions.SET_TARGET, 0, bestTarget.name);
        SendChatText(L"/target " .. bestTarget.name, L"");
        ScheduleTargetVerify(bestTarget);

    else
        -- Target is already selected, just cast
        if (DisarmIfCurrentTargetCovered()) then return end
        local skipped, abilityId = SkipUncastableCurrentTarget(bestTarget);
        if (skipped) then return end
        WindowSetGameActionTrigger("HotbotFrame", abilityId);
        WindowSetGameActionData("HotbotFrame", GameData.PlayerActions.DO_ABILITY, abilityId, L"");
        StartAbilityCooldown(abilityId);
        Hotbot.StartPostCastLock();
        ScheduleApplyVerify(bestTarget, abilityId);
        Hotbot.SchedulePostCastTargetClear();
    end
end

-- Public macro/script entry point -----------------------------------------
-- Use in-game as:
--   /script Hotbot.HoT()
--
-- RoR appears to block protected target/cast actions when they are started
-- from chat scripts. Keep this as a diagnostic path; use HotbotFrame for real
-- click/key input.

function Hotbot.HoT(debugOutput)
    local verbose = (debugOutput == true) or (HotbotConfig and HotbotConfig.DebugHotCommand == true);

    if (debugOutput == true) then
        ChatPrint("Hotbot HoT: debug command reached.");
    end

    if (not isLoaded) then
        ChatPrint("Hotbot HoT: addon is not loaded yet. Try /reloadui, then try again.");
        return;
    end

    if (not hotAbilityId) then
        ChatPrint("Hotbot HoT: no HoT ability is configured for this career.");
        return;
    end

    -- One macro invocation performs one action only. Cancel any legacy delayed
    -- action so an earlier invocation can never change or cast on a later target.
    ClearPendingTargetAutomation();
    Hotbot.ManualTargetLock = false;
    bestTarget = FindBestTarget();
    UpdateBar();

    if (not bestTarget) then
        if (verbose) then
            ChatPrint("Hotbot HoT: no target currently needs a HoT.");
        end
        return;
    end

    if (Hotbot.CurrentTarget ~= bestTarget.name) then
        RequestHotCommandTarget(bestTarget.name, verbose);
        ScheduleTargetVerify(bestTarget);
        if (verbose) then
            ChatPrint("Hotbot HoT: targeting " .. tostring(bestTarget.name) .. ". Invoke the macro again to cast.");
        end
        return;
    end

    ExecuteHotCommandAction(verbose);
end

function Hotbot.HoTDebug()
    Hotbot.HoT(true);
end

function Hotbot.EmergencyDebug()
    if (not isLoaded) then
        ChatPrint("Hotbot emergency: addon is not loaded.");
        return;
    end

    local threshold = tonumber(HotbotConfig.EmergencyHealthPercent or 50) or 50;
    ChatPrint(
        "Hotbot emergency: career=" .. tostring(myCareerLine or "") ..
        " threshold<" .. tostring(threshold) ..
        " abilities=" .. tostring(emergencyAbilityIds and #emergencyAbilityIds or 0)
    );

    if ((not emergencyAbilityIds) or #emergencyAbilityIds == 0) then
        ChatPrint("Hotbot emergency: no emergency abilities configured for this career.");
        return;
    end

    for _, abilityId in ipairs(emergencyAbilityIds) do
        ChatPrint(
            "Hotbot emergency ability: " .. GetAbilityLabel(abilityId) ..
            "(" .. tostring(abilityId) .. ")" ..
            " learned=" .. tostring(Hotbot.IsAbilityKnown(abilityId)) ..
            " scanReady=" .. tostring(IsAbilityReadyForEmergencyScan(abilityId)) ..
            " castReady=" .. tostring(IsAbilityReady(abilityId)) ..
            " gameCd=" .. tostring(GetAbilityCooldownSeconds(abilityId)) ..
            " localCd=" .. tostring(abilityCooldownsRemaining[abilityId] or 0)
        );
    end

    local priority = HotbotConfig.TargetPriority or DefaultTargetPriority;
    if (type(priority) ~= "table") then
        priority = DefaultTargetPriority;
    end

    for _, checkName in ipairs(priority) do
        local check = TargetChecks[checkName];
        if (checkName == "nearby" and not Hotbot.IsNearbyFallbackEnabled()) then
            DebugSkip(checkName, "nearby fallback disabled");
        elseif (check) then
            for _, abilityId in ipairs(emergencyAbilityIds) do
                currentScanAbilityId = abilityId;
                local target = Hotbot.RunTargetCheck(checkName, check);
                currentScanAbilityId = nil;

                if (target) then
                    local ok, reason = TargetMeetsPreTargetRequirements(target, abilityId);
                    ChatPrint(
                        "Hotbot emergency check: " .. tostring(checkName) ..
                        " target=" .. tostring(target.name or "") ..
                        " hp=" .. tostring(target.healthPercent or "nil") ..
                        " ability=" .. GetAbilityLabel(abilityId) ..
                        " ok=" .. tostring(ok) ..
                        " reason=" .. tostring(reason or "")
                    );
                else
                    ChatPrint(
                        "Hotbot emergency check: " .. tostring(checkName) ..
                        " target=none ability=" .. GetAbilityLabel(abilityId)
                    );
                end
            end
        else
            ChatPrint("Hotbot emergency check: unknown priority " .. tostring(checkName));
        end
    end

    currentScanAbilityId = nil;

    local previousBestTarget = bestTarget;
    local selected = FindBestTarget();
    bestTarget = previousBestTarget;

    if (selected) then
        ChatPrint(
            "Hotbot emergency selected: target=" .. tostring(selected.name or "") ..
            " hp=" .. tostring(selected.healthPercent or "nil") ..
            " ability=" .. tostring(selected.requiredAbilityName or selected.requiredAbilityId or "") ..
            " emergency=" .. tostring(selected.isEmergency == true)
        );
    else
        ChatPrint("Hotbot emergency selected: none");
    end
end

function Hotbot.EmergDebug()
    Hotbot.EmergencyDebug();
end

function Hotbot.HOT()
    Hotbot.HoT(true);
end

function Hotbot.Hot()
    Hotbot.HoT(true);
end

function HotbotHoTDebug()
    Hotbot.HoT(true);
end
