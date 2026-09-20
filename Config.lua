-- Hotbot Config.lua
-- Defines which ability ID is the Heal over Time (HoT) for each career line.
-- The key is the GameData.CareerLine value (a number).
-- The value is the ability ID of the HoT to track and cast.
--
-- HOW TO FIND ABILITY IDs:
--   Open the WAR ability browser or check RoR spell databases.
--   You can also use: /script d(GetAbilityTable(GameData.AbilityType.STANDARD)[abilityId].name)
--   to verify a specific ID in-game.
--
-- ADDING A NEW CAREER:
--   Add a new entry:  [GameData.CareerLine.CAREER_NAME] = abilityId,
--
-- Only careers listed here will have HoT tracking active.
-- If your career line is not listed, Hotbot will show no target and do nothing on click.

HotbotConfig = {};

HotbotConfig.HotAbilityByCareer =
{
    -- =========================================================
    -- ORDER
    -- =========================================================

    -- Rune Priest
    -- "Rune of Regeneration" - a persistent HoT rune
    [GameData.CareerLine.RUNE_PRIEST]   = 1590,

    -- Archmage
    -- "Lambent Aura" - core single-target HoT
    [GameData.CareerLine.ARCHMAGE]      = 9238,

    -- Warrior Priest
    -- "Healing Hand" - core single-target HoT
    [GameData.CareerLine.WARRIOR_PRIEST] = 8241,

    -- =========================================================
    -- DESTRUCTION
    -- =========================================================

    -- Zealot
    -- "Tzeench's Cordial" - core single-target HoT
    [GameData.CareerLine.ZEALOT]        = 8558,

    -- Shaman
    -- "'Ey, Quit Bleedin'" - core single-target HoT
    [GameData.CareerLine.SHAMAN]        = 1901,

    -- Disciple of Khaine
    -- "Soul Infusion" - core single-target HoT
    [GameData.CareerLine.DISCIPLE]      = 9550,

    -- =========================================================
    -- Add additional careers below as needed.
    -- Example:
    --   [GameData.CareerLine.IRON_BREAKER] = 12345,
    -- =========================================================
};

-- Optional: HotAbilitiesByCareer can define a cast priority list for a career.
-- Hotbot checks each ability in order and arms the first one that is off
-- cooldown and valid for the current target. HotAbilityByCareer is still used
-- as a fallback when a career does not have a list here.
HotbotConfig.HotAbilitiesByCareer =
{
    -- Rune Priest. Keep Rune of Regeneration first to preserve the original
    -- HoT behaviour, then fall back to the other configured runes as cooldowns
    -- and target validity allow.
    [GameData.CareerLine.RUNE_PRIEST] =
    {
        { id = 1590, name = "Rune of Regeneration", effectNames = { "Rune of Regeneration" } },
        { id = 1599, name = "Rune of Mending", effectIds = { 3551 }, effectNames = { "Rune of Mending", "Lingering Rune of Mending" }, applyHoldSeconds = 2, requiresDamagedTarget = true },
        { id = 1601, name = "Rune of Serenity", effectNames = { "Rune of Serenity" }, cooldownSeconds = 5, requiresStationary = true, skipEnabledCheck = true, requiresDamagedTarget = true },
        { id = 1602, name = "Rune of Cleansing", verifyApply = false, trackEffect = false, requiresCleanse = true, cleanseTypes = { "isCurse", "isAilment" } },
    },
    [GameData.CareerLine.ARCHMAGE] =
    {
        { id = 9238, name = "Lambent Aura", effectNames = { "Lambent Aura" } },
        { id = 9236, name = "Healing Energy", effectNames = { "Healing Energy" } },
        { id = 9242, name = "Boon of Hysh", effectNames = { "Boon of Hysh" }, verifyApply = false, requiresDamagedTarget = true },
        { id = 9244, name = "Cleansing Light", verifyApply = false, trackEffect = false, requiresCleanse = true, cleanseTypes = { "isHex", "isAilment" } },
    },
    [GameData.CareerLine.WARRIOR_PRIEST] =
    {
        { id = 8241, name = "Healing Hand", effectIds = { 3365 }, effectNames = { "Healing Hand" } },
        { id = 8238, name = "Divine Aid", verifyApply = false, requiresDamagedTarget = true },
        { id = 8265, name = "Pious Restoration", verifyApply = false, requiresDamagedTarget = true },
        { id = 8246, name = "Purify", verifyApply = false, trackEffect = false, requiresCleanse = true, cleanseTypes = { "isCurse", "isHex" } },
    },
    [GameData.CareerLine.ZEALOT] =
    {
        { id = 8558, name = "Tzeench's Cordial", effectNames = { "Tzeench's Cordial" } },
        { id = 8549, name = "Dark Medicine", effectNames = { "Lingering Dark Medicine" }, applyHoldSeconds = 2, requiresDamagedTarget = true },
        { id = 8557, name = "Leaping Alteration", effectNames = { "Leaping Alteration" }, cooldownSeconds = 10, cooldownPaddingSeconds = 1, castOnCooldown = true, requiresStationary = true, skipEnabledCheck = true, requiresDamagedTarget = true },
        { id = 8554, name = "Glimpse of Chaos", verifyApply = false, trackEffect = false, requiresCleanse = true, cleanseTypes = { "isCurse", "isAilment" } },
    },
    [GameData.CareerLine.SHAMAN] =
    {
        { id = 1901, name = "'Ey, Quit Bleedin'", effectIds = { 3908 }, effectNames = { "'Ey, Quit Bleedin'" } },
        { id = 1898, name = "Gork'll Fix It", effectIds = { 3552 }, effectNames = { "Lingering Gork'll Fix It" } },
        { id = 1906, name = "Greener 'n Cleaner", verifyApply = false, trackEffect = false, requiresCleanse = true, cleanseTypes = { "isCurse", "isAilment" } },
    },
    [GameData.CareerLine.DISCIPLE] =
    {
        { id = 9550, name = "Soul Infusion", effectNames = { "Soul Infusion" } },
        { id = 9548, name = "Restore Essence", effectNames = { "Restore Essence" } },
        { id = 9573, name = "Khaine's Vigor", verifyApply = false, requiresDamagedTarget = true },
        { id = 9556, name = "Patch Wounds", verifyApply = false, trackEffect = false, requiresCleanse = true, cleanseTypes = { "isHex", "isAilment" } },
    },
};

-- Emergency abilities are checked before normal HoTs. Hotbot scans
-- TargetPriority first, then arms the first ready emergency ability for the
-- first target below this HP percent.
HotbotConfig.EmergencyHealthPercent = 65;

HotbotConfig.EmergencyAbilitiesByCareer =
{
    [GameData.CareerLine.RUNE_PRIEST] =
    {
        { id = 1593, name = "Rune of Shielding" },
        { id = 1606, name = "Protection of the Ancestors" },
--        { id = 1587, name = "Grungni's Gift"}
    },
    [GameData.CareerLine.ARCHMAGE] =
    {
        { id = 9268, name = "Shield of Saphery" },
        { id = 9248, name = "Prismatic Shield" },
    },
    [GameData.CareerLine.WARRIOR_PRIEST] =
    {
--        { id = 8265, name = "Pious Restoration" },
    },
    [GameData.CareerLine.ZEALOT] =
    {
        { id = 8564, name = "Veil of Chaos" },
        { id = 8561, name = "Daemonic Fortitute" },
--        { id = 8569, name = "Flash of Chaos"}
    },
    [GameData.CareerLine.SHAMAN] =
    {
        { id = 1932, name = "Don' Feel Nuthin" },
    },
    [GameData.CareerLine.DISCIPLE] =
    {
        { id = 9573, name = "Khaine's Vigor" },
    },
};

--

-- Spread the primary HoT through the whole target priority list before
-- selecting secondary healing layers. Emergency and castOnCooldown abilities
-- retain their separate priority passes.
-- A positive value restricts the initial primary-HoT pass to that many entries,
-- allowing secondary heals to delay coverage of the remaining roster.
HotbotConfig.LayeredTargetPriorityCount = 0;

-- Cooldown grace in seconds. An ability with more than this remaining cooldown
-- is treated as unavailable and will not be selected as the active layer.
HotbotConfig.CooldownReadyGrace = 0.1;

-- Movement check used by stationary-only abilities such as Rune of Serenity.
-- Hotbot receives position updates from RoR and treats recent position changes
-- as movement, then avoids recommending abilities marked requiresStationary.
HotbotConfig.PlayerMovingHoldSeconds = 0.45;
HotbotConfig.PlayerMovementThreshold = 3;

-- Some abilities cast with one ID but appear in the buff/effect list with a
-- different ID. Hotbot casts the configured abilities, then treats these IDs as
-- the same HoT when checking whether the target is already covered.
HotbotConfig.HotEffectIdsByCareer =
{
    -- Warrior Priest: "Healing Hand" casts as 8241 but appears as buff 3365.
    [GameData.CareerLine.WARRIOR_PRIEST] = { 3365 },
};

-- How many seconds remaining on the HoT before it is considered "needs refresh".
-- A target whose HoT has more than this many seconds left will be skipped.
-- Increase this value if you want to refresh earlier (e.g. 5 = refresh when 5s left).
HotbotConfig.RefreshThreshold = 0;

-- Print scenario/group skip reasons to chat. Useful when testing roster/range issues.
HotbotConfig.DebugSkips = false;

-- Maximum roster/map distance Hotbot will consider targetable.
-- Remote roster targets without distance data are skipped; current friendly
-- target fallback remains allowed because the game validates the selected target.
-- A small margin below the usual 100-foot heal range avoids stale/rounded
-- roster positions being recommended at the range boundary.
HotbotConfig.MaxTargetDistance = 95;

-- Enable or disable each main roster check. These can be changed live with /script.
HotbotConfig.SelfCheck = true;
HotbotConfig.GroupCheck = true;
HotbotConfig.WarbandCheck = true;
HotbotConfig.ScenarioPartyCheck = true;
HotbotConfig.ScenarioWarbandCheck = true;
HotbotConfig.WarbandLeaderCheck = true;
HotbotConfig.DpsCheck = true;

-- "lowestHealth" only wins target priority below this health percentage.
HotbotConfig.LowestHealthThreshold = 95;

-- Target priority order. Hotbot checks these from top to bottom and uses the
-- first category that currently needs a HoT.
--
-- Valid entries:
--   "self"           your own character
--   "group"          group members, excluding yourself
--   "warbandLeader"  the warband leader, when you are in a warband
--   "dps"            DPS class members from group/scenario/warband
--   "lowestHealth"   lowest-HP target from enabled self/leader/roster pools
--   "scenario"       scenario/city roster
--   "warband"        warband members
--   "target"         your current friendly target
--
-- Move "warbandLeader" earlier if you want the leader HoTed before group/self.
HotbotConfig.TargetPriority =
{
    "self",
    "lowestHealth",
    "warbandLeader",
    "dps",
    "group",
    "scenario",
    "warband",
    "target",
};

-- Number of cast attempts to try before temporarily skipping a target whose HoT cannot be verified.
HotbotConfig.FailedApplyLimit = 2;

-- How long, in seconds, to skip a target after the failed-apply limit is reached.
HotbotConfig.FailedTargetSkipSeconds = 2;

-- After a cast click, wait for the HoT/effect to be verified before scanning
-- for the next target. This is safer under lag or when the game eats a click.
HotbotConfig.WaitForApplyBeforeNextTarget = true;

-- Seconds to wait before verifying whether the HoT/effect landed. Per-ability
-- applyHoldSeconds can extend this for delayed effects.
HotbotConfig.ApplyVerifyDelay = 0.9;

-- RoR global cooldown. Hotbot will not arm the next cast until this has elapsed
-- after a cast request, even if effect verification finishes sooner.
HotbotConfig.GlobalCooldownSeconds = 0.70;  -- Setting to under the GCD so its got the next cast queued up already
HotbotConfig.WaitForGlobalCooldownBeforeNextTarget = true;

-- Never let background verification/retry timers clear or change your selected
-- targets. Set this true only if you explicitly want the old automatic clear.
HotbotConfig.AllowAutomaticTargetClearing = false;
HotbotConfig.ClearTargetAfterApplyVerify = false;

-- If RoR refuses to switch to the requested target, skip that name briefly
-- instead of repeatedly selecting someone who is too far away to target.
HotbotConfig.TargetVerifyDelay = 0.75;
HotbotConfig.TargetFailureSkipSeconds = 8;

-- Optional legacy map-pip fallback in normal roster mode. The macro-controlled
-- cycle mode works independently of this setting and responds when you use the
-- client's native Cycle Friendly Targets key; it does not use map pips:
--   /script Hotbot.NearbyMode(true)      -- self, then friendly players in the area
--   /script Hotbot.NearbyMode(false)     -- normal configured roster priorities
--   /script Hotbot.ToggleNearbyMode()    -- toggle between the two modes
-- Nearby map pips can be unreliable for out-of-group players.
HotbotConfig.EnableNearbyFallback = false;

-- When group/warband are covered, allow your current friendly target as a HoT target.
HotbotConfig.EnableFriendlyTargetFallback = true;

-- Maximum number of warband groups to scan (warband has up to 8 groups of 6).
-- Keeping this at 8 scans the entire warband.  Set to 1 to ignore warband members.
HotbotConfig.MaxWarbandGroups = 4;
