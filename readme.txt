Hotbot README
=============

Hotbot is a single-target Heal over Time helper for Return of Reckoning.
It tracks whether your configured HoT or support effect is already active on
possible targets and arms the Hotbot window so clicking it will target/cast on
the best target.

The addon is designed for healer support abilities configured in Config.lua.
The base setup tracks healer HoTs, with optional follow-up abilities, cleanse
abilities, and emergency abilities per career.


Requirements / Supplementary Addons
-----------------------------------

Hotbot declares these dependencies in Hotbot.mod:

- EASystem_LayoutEditor, supplied by the standard Return of Reckoning UI.
- LibGroup, which must be present as an addon/library. The Hotbot package should
  include it under Hotbot\Libraries; if you install Hotbot manually, make sure
  Hotbot\Libraries\LibGroup remains in place.

No other addon is required for core Hotbot behaviour. MapMonster, Enemy, Pure,
BuffHead, and similar UI addons are optional and are not required. Stationary
checks, including the Rune of Serenity movement check, use RoR's own
PLAYER_POSITION_UPDATED event.


What the Window Shows
---------------------

When Hotbot finds a target, the label shows the target source and the selected
ability. Common source labels are:

- [Self] for your own character.
- [Leader] for the warband leader.
- [DPS] for DPS career targets.
- [Group] for regular group members.
- [Scenario] for scenario/city roster members.
- [Warband] for warband members.
- [Target] for your current friendly target.
- [Cycle] for a friendly selected by Cycle Friendly Targets mode.
- [Nearby] for nearby map fallback targets, only when enabled.
- [Emerg] for emergency abilities.

If no valid target currently needs anything, the window shows:

    All covered

Immediately after a cast request, while Hotbot is waiting for the configured
global cooldown lock, the window shows:

    GCD Wait


Target Priority
---------------

Hotbot chooses targets using HotbotConfig.TargetPriority in Config.lua. The
current default order is:

1. self
2. lowestHealth
3. warbandLeader
4. dps
5. group
6. scenario
7. warband
8. target

Valid entries are:

- self: your own character, controlled by HotbotConfig.SelfCheck.
- warbandLeader: the warband leader, controlled by
  HotbotConfig.WarbandLeaderCheck.
- dps: DPS career members from group/scenario/warband, controlled by
  HotbotConfig.DpsCheck.
- lowestHealth: lowest-HP target from the enabled self/leader/group/DPS/
  scenario/warband/current-target pools. Use this in HotbotConfig.TargetPriority
  wherever you want health to outrank category order.
- group: group members other than yourself, controlled by
  HotbotConfig.GroupCheck.
- scenario: scenario/city roster members, controlled by
  HotbotConfig.ScenarioPartyCheck and
  HotbotConfig.ScenarioWarbandCheck.
- warband: warband members, controlled by HotbotConfig.WarbandCheck and
  HotbotConfig.MaxWarbandGroups.
- target: your current friendly target, controlled by
  HotbotConfig.EnableFriendlyTargetFallback.
- nearby: overhead-map nearby fallback, controlled by
  HotbotConfig.EnableNearbyFallback.

Nearby fallback is disabled by default and is not in the default priority list.
Even if "nearby" is manually added to TargetPriority, Hotbot will ignore it
unless HotbotConfig.EnableNearbyFallback is true.


Nearby-Only Macro Mode
----------------------

Nearby-only mode temporarily replaces the normal group/warband/scenario
priority. It checks you first, then responds to the client's native Cycle
Friendly Targets key. It does not use overhead-map pips to discover
out-of-group players. RoR does not expose that protected key action as an
addon-callable event, so the Hotbot window itself cannot generate the cycle.

Create separate in-game macros for the two switch positions:

    /script Hotbot.NearbyMode(true)

    /script Hotbot.NearbyMode(false)

The first macro enables self-then-cycle targeting. The second restores the
normal configured target priority. You can instead use one toggle macro:

    /script Hotbot.ToggleNearbyMode()

Hotbot prints the resulting mode in chat. The switch lasts for the current UI
session and defaults to OFF after /reloadui or a game restart. Once self is
covered, use the game's Cycle Friendly Targets key (Ctrl+Tab by default), then
click Hotbot to cast on that selected friendly if they need the HoT.


Emergency Abilities
-------------------

Emergency abilities are checked before normal HoT/follow-up coverage. Hotbot
scans HotbotConfig.TargetPriority first, then arms the first ready emergency
ability for the first valid target below HotbotConfig.EmergencyHealthPercent.

Current global threshold:

    HotbotConfig.EmergencyHealthPercent = 65

That means emergency abilities are considered when visible target health is
below 65 percent.

Current Rune Priest emergency abilities:

- Rune of Shielding, ability ID 1593.
- Protection of the Ancestors, ability ID 1606.

Current Archmage emergency abilities:

- Shield of Saphery, ability ID 9268.
- Prismatic Shield, ability ID 9248, is present as a commented optional line.

Current Warrior Priest emergency abilities:

- Divine Aid, ability ID 8238.
- Pious Restoration, ability ID 8265.

Current Zealot emergency abilities:

- Veil of Chaos, ability ID 8564.
- Daemonic Fortitute, ability ID 8561.

Current Shaman emergency abilities:

- Don' Feel Nuthin, ability ID 1932.
- Mork's Buffer, ability ID 1910, is present as a commented optional line.

Current Disciple of Khaine emergency abilities:

- Restore Essence, ability ID 9548.
- Khaine's Vigor, ability ID 9573.

Emergency abilities only trigger when the ability is learned, ready, and not on
cooldown. Emergency abilities also skip entries your character has not learned.
They also include self when "self" is present in TargetPriority and
HotbotConfig.SelfCheck is true.

Use this in game to print emergency scan details:

    /script Hotbot.EmergencyDebug()

Short alias:

    /script Hotbot.EmergDebug()


How Casting Works
-----------------

Hotbot works in two explicit steps, whether you click its window or invoke
Hotbot.HoT() from a macro:

1. First click targets the chosen player.
2. Next click casts the selected ability once that target is confirmed.

If the target is already selected, Hotbot can cast immediately.

After a cast request, Hotbot starts a post-cast lock using
HotbotConfig.GlobalCooldownSeconds. While this lock is active, it does not arm
the next target and the window shows GCD Wait.

Hotbot also verifies whether the effect landed by reading buffs/effects. With
HotbotConfig.WaitForApplyBeforeNextTarget enabled, it waits for that
verification before moving on to another target. This helps when the game eats a
click, the target swap is delayed, or latency makes the buff appear late.

Background verification and retry timers do not change or clear your selected
targets. Automatic target clearing can only be restored by explicitly enabling
HotbotConfig.AllowAutomaticTargetClearing.

Selecting a friendly player manually disarms Hotbot and pauses its target
automation. This leaves that player available for your normal heals or
resurrection abilities. Hotbot resumes only when you explicitly click its
window or invoke Hotbot.HoT() again.


Range, Failed Targets, and Skipping
-----------------------------------

Hotbot avoids obvious out-of-range roster targets using distance data when the
game provides it. Remote roster targets without usable range data are skipped.
The current friendly target fallback remains allowed because the game can
validate the already selected target directly.

For selected targets, Hotbot also uses the game's target validity check for the
configured ability. This catches targets that cannot currently receive the
spell, such as out-of-range, line-of-sight, invalid, hostile, or dead targets.

If Hotbot tries to apply an ability but cannot verify that it landed, it counts
that as a failed attempt. Once the failed-attempt limit is reached, that target
is temporarily skipped so Hotbot can move on.

Self is exempt from this failed-target move-on behavior.


Configured Abilities
--------------------

HotbotConfig.HotAbilityByCareer maps each career line to its base HoT ability.

Current configured base IDs:

- Rune Priest: 1590, Rune of Regeneration.
- Archmage: 9238, Lambent Aura.
- Warrior Priest: 8241, Healing Hand.
- Zealot: 8558, Tzeench's Cordial.
- Shaman: 1901, 'Ey, Quit Bleedin'.
- Disciple of Khaine: 9550, Soul Infusion.

HotbotConfig.HotAbilitiesByCareer can define an ordered list of abilities for a
career. Hotbot checks these in order and arms the first one that is learned,
ready, valid, and needed for the current target/layer.

Configured abilities that your character has not learned are skipped
automatically. This lets the config contain higher-level or optional abilities
without forcing you to comment them out while levelling.

Current Rune Priest list:

- 1590, Rune of Regeneration.
- 1599, Rune of Mending. Requires damaged target, has applyHoldSeconds = 2,
  and also tracks Lingering Rune of Mending/effect ID 3551.
- 1601, Rune of Serenity. Requires damaged target, requires you to be
  stationary, has local cooldownSeconds = 5, and skips the normal ability
  enabled check.
- 1602, Rune of Cleansing. Requires a cleanseable Curse or Ailment, does not
  verify a tracked HoT effect after cast.

Current Archmage list:

- 9238, Lambent Aura.
- 9236, Healing Energy.
- 9242, Boon of Hysh. Requires damaged target and does not wait for a tracked
  buff verification after cast.
- 9244, Cleansing Light. Requires a cleanseable Hex or Ailment, does not verify
  a tracked HoT effect after cast.

Current Warrior Priest list:

- 8241, Healing Hand. Also tracks effect ID 3365.
- 8247, Touch of the Divine. Requires damaged target and does not wait for a
  tracked buff verification after cast.
- 8246, Purify. Requires a cleanseable Curse or Hex, does not verify a tracked
  HoT effect after cast.

Current Zealot list:

- 8558, Tzeench's Cordial.
- 8549, Dark Medicine. Requires damaged target, has applyHoldSeconds = 2, and
  tracks Lingering Dark Medicine.
- 8557, Leaping Alteration. Has castOnCooldown enabled, but still requires a
  damaged target and requires you to be stationary. Its 10-second cooldown has
  a 1-second local padding for the cast time, and it skips the normal ability
  enabled check. PLAYER_BEGIN_CAST and PLAYER_END_CAST synchronize the local
  timer with successful or interrupted casts.
- 8554, Glimpse of Chaos. Requires a cleanseable Curse or Ailment, does not
  verify a tracked HoT effect after cast.

Current Shaman list:

- 1901, 'Ey, Quit Bleedin'. Also tracks effect ID 3908.
- 1898, Gork'll Fix It. Also tracks effect ID 3552.
- 1904, Bigger, Better, An' Greener. Requires damaged target and does not wait
  for a tracked buff verification after cast.
- 1906, Greener 'n Cleaner. Requires a cleanseable Curse or Ailment, does not
  verify a tracked HoT effect after cast.

Current Disciple of Khaine list:

- 9550, Soul Infusion.
- 9557, Khaine's Embrace. Requires damaged target and does not wait for a
  tracked buff verification after cast.
- 9556, Patch Wounds. Requires a cleanseable Hex or Ailment, does not verify a
  tracked HoT effect after cast.

HotbotConfig.HotEffectIdsByCareer adds extra effect IDs that count as coverage
for a base HoT.

Current configured extra effect IDs:

- Warrior Priest Healing Hand: 3365.


Config.lua Parameters
---------------------

HotbotConfig.EmergencyHealthPercent
    Health percentage threshold for emergency abilities.

    Default: 65

HotbotConfig.EmergencyAbilitiesByCareer
    Per-career emergency ability list checked before normal HoT coverage.

    Current Rune Priest defaults:
    - 1593, Rune of Shielding.
    - 1606, Protection of the Ancestors.

    Current Archmage defaults:
    - 9268, Shield of Saphery.
    - 9248, Prismatic Shield, commented optional line.

    Current Warrior Priest defaults:
    - 8238, Divine Aid.
    - 8265, Pious Restoration.

    Current Zealot defaults:
    - 8564, Veil of Chaos.
    - 8561, Daemonic Fortitute.

    Current Shaman defaults:
    - 1932, Don' Feel Nuthin.
    - 1910, Mork's Buffer, commented optional line.

    Current Disciple of Khaine defaults:
    - 9548, Restore Essence.
    - 9573, Khaine's Vigor.

HotbotConfig.LayeredTargetPriorityCount
    Number of target-priority entries checked for the primary HoT before
    Hotbot tries secondary healing layers. Applies to all configured careers.

    Default: 0

    Zero scans the whole priority list for the primary HoT before moving to
    secondary layers. A value of 3 checks self, lowestHealth, and warbandLeader
    first, then allows secondary heals before primary HoTs on the rest of the
    roster. Emergency and castOnCooldown abilities keep their earlier priority.

HotbotConfig.CooldownReadyGrace
    Number of seconds of remaining cooldown that Hotbot treats as effectively
    ready. This avoids waiting on tiny cooldown display leftovers.

    Default: 0.1

Per-ability applyHoldSeconds
    Optional setting inside a HotbotConfig.HotAbilitiesByCareer entry.

    After Hotbot requests a cast, it waits at least this many seconds before
    verifying whether a delayed effect landed.

    Current use:
    - Rune of Mending: 2
    - Dark Medicine: 2

Per-ability requiresDamagedTarget
    Optional setting inside a HotbotConfig.HotAbilitiesByCareer entry.

    When true, Hotbot only recommends that ability if the target's visible
    health is below 100 percent. If health cannot be read, Hotbot treats the
    target as full health and skips the ability.

HotbotConfig.PlayerMovingHoldSeconds
    Number of seconds after a position change that Hotbot treats you as moving.
    Stationary-only abilities, such as Rune of Serenity and Leaping Alteration,
    are not recommended while this movement timer is active.

    Default: 0.45

HotbotConfig.PlayerMovementThreshold
    Minimum position change needed before Hotbot treats you as moving.

    Default: 3

HotbotConfig.RefreshThreshold
    Number of seconds remaining before a HoT is considered due for refresh.

    Default: 0

    With 0, Hotbot only refreshes when your HoT is missing or expired. Set this
    higher if you want earlier refreshes, for example 3 or 5.

HotbotConfig.DebugSkips
    Prints skip reasons to chat for roster/range debugging.

    Default: false

HotbotConfig.MaxTargetDistance
    Maximum roster/map distance Hotbot will consider targetable. Remote roster
    targets without usable distance data are skipped.

    Default: 95

HotbotConfig.SelfCheck
    Enables checking your own character.

    Default: true

HotbotConfig.GroupCheck
    Enables checking regular group members other than yourself.

    Default: true

HotbotConfig.ScenarioPartyCheck
    Enables checking members of your own scenario party.

    Default: true

HotbotConfig.ScenarioWarbandCheck
    Enables checking other scenario parties in the scenario/city roster.

    Default: true

HotbotConfig.WarbandCheck
    Enables checking the warband roster.

    Default: true

HotbotConfig.WarbandLeaderCheck
    Enables checking the warband leader when "warbandLeader" is present in
    HotbotConfig.TargetPriority.

    Default: true

HotbotConfig.DpsCheck
    Enables checking DPS career members when "dps" is present in
    HotbotConfig.TargetPriority.

    Default: true

HotbotConfig.TargetPriority
    Configures the order Hotbot uses when choosing who should receive support.

    Current default:
    - self
    - lowestHealth
    - warbandLeader
    - dps
    - group
    - scenario
    - warband
    - target

    Move "lowestHealth" anywhere in this list to choose where lowest visible
    health should outrank category order.

HotbotConfig.FailedApplyLimit
    Number of failed application attempts before Hotbot temporarily skips a
    target.

    Default: 2

HotbotConfig.FailedTargetSkipSeconds
    Number of seconds to skip a target after it reaches the failed-apply limit.

    Default: 2

HotbotConfig.WaitForApplyBeforeNextTarget
    When true, Hotbot waits for cast verification before scanning for the next
    target.

    Default: true

HotbotConfig.ApplyVerifyDelay
    Seconds to wait before verifying whether the HoT/effect landed.
    Per-ability applyHoldSeconds can extend this for delayed effects.

    Default: 0.9

HotbotConfig.GlobalCooldownSeconds
    Post-cast lock duration. Hotbot will not arm another cast while this timer
    is active.

    Default: 1.2

    The current value is intentionally under the game's 1.5 second global
    cooldown so the next cast can be queued promptly without Hotbot moving on
    instantly.

HotbotConfig.WaitForGlobalCooldownBeforeNextTarget
    Enables the post-cast global cooldown wait.

    Default: true

HotbotConfig.ClearTargetAfterApplyVerify
    When true, successful verification may schedule a target clear, but only
    when HotbotConfig.AllowAutomaticTargetClearing is also true.

    Default: false

HotbotConfig.AllowAutomaticTargetClearing
    Master opt-in for delayed target clearing. When false, background timers
    may update Hotbot's recommendation but cannot clear your selected targets.

    Default: false

HotbotConfig.TargetVerifyDelay
    Number of seconds Hotbot waits after requesting a target before checking
    whether RoR actually switched to that target.

    Default: 0.75

HotbotConfig.TargetFailureSkipSeconds
    Number of seconds to skip a target when RoR refuses to target them.

    Default: 8

HotbotConfig.EnableNearbyFallback
    Enables the overhead-map nearby fallback.

    Default: false

    This is disabled by default because testing showed map pips are not reliable
    for out-of-group players. Use the current friendly target fallback instead:
    manually select the player, then click Hotbot if it shows [Target].

HotbotConfig.EnableFriendlyTargetFallback
    Enables using your current selected friendly target after roster targets are
    covered.

    Default: true

    This is the most reliable way to HoT a player outside your group/warband:
    manually select them, then click Hotbot if it shows [Target].

HotbotConfig.MaxWarbandGroups
    Maximum number of warband groups to scan.

    Default: 4

    Warbands can have up to 8 groups. Set to 8 to scan the entire warband.
    Set to 1 to effectively ignore other warband groups.


Changing Settings In Game
-------------------------

Most simple config values can be changed for the current session with /script.
These changes last until you reload UI or restart the game.

Examples:

    /script Hotbot.NearbyMode(true)
    /script Hotbot.NearbyMode(false)
    /script Hotbot.ToggleNearbyMode()
    /script HotbotConfig.EnableNearbyFallback = false
    /script HotbotConfig.EnableFriendlyTargetFallback = true
    /script HotbotConfig.SelfCheck = true
    /script HotbotConfig.GroupCheck = false
    /script HotbotConfig.ScenarioPartyCheck = true
    /script HotbotConfig.ScenarioWarbandCheck = false
    /script HotbotConfig.WarbandCheck = true
    /script HotbotConfig.RefreshThreshold = 3
    /script HotbotConfig.FailedApplyLimit = 2
    /script HotbotConfig.GlobalCooldownSeconds = 1.2
    /script HotbotConfig.WaitForGlobalCooldownBeforeNextTarget = true

To make a setting permanent, edit Config.lua.


Debug Commands
--------------

Hotbot.DebugCoverage()
    Prints a read-only snapshot of primary-HoT readiness, group member range
    and buff data, and warband range totals. Use when "All covered" appears
    even though group members need a HoT. Does not target or cast.

        /script Hotbot.DebugCoverage()

Hotbot.DebugNearby()
    Prints what the nearby map scanner can see and whether nearby-only mode is
    active.

    Run with:

        /script Hotbot.DebugNearby()

Hotbot.DebugSelfBuffs()
    Prints your visible self buffs and the tracked Hotbot ability IDs.

    Run with:

        /script Hotbot.DebugSelfBuffs()

Hotbot.DebugSerenity()
    Prints Rune of Serenity movement/target/cooldown details.

    Run with:

        /script Hotbot.DebugSerenity()

Hotbot.EmergencyDebug()
    Prints emergency ability readiness, target checks, and selected emergency
    target.

    Run with:

        /script Hotbot.EmergencyDebug()

Hotbot.HoTDebug()
    Runs the diagnostic macro/script path with extra chat output. Use the
    Hotbot window/button for normal play.

    Run with:

        /script Hotbot.HoTDebug()


Window and Layout
-----------------

The Hotbot window is registered with the layout editor.

The window should not be freely movable during normal play. Move it through the
layout editor, then exit layout editing before normal use.


Known Limitations
-----------------

Hotbot can only work with target, roster, range, cooldown, and buff data the
game exposes to addons.

Random nearby players outside your group/warband are not always exposed as
usable map points, especially while solo. In that case, use the current friendly
target fallback: click/select the player manually, then click Hotbot.

Buff verification is strongest when the target is selected or is in your group.
For some remote warband/scenario members, the game may not expose full buff data
until they are targeted.
