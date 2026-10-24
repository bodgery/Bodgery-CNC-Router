-- VECTRIC LUA SCRIPT
--[[
  ClockReviewReport.lua

  Pre-flight review checker for the "Dragonfly Clock" student project.
  Run from VCarve's Gadgets menu against a student's open file before
  their machine appointment.

  STANDING NOTE - DO NOT SAVE THE FILE AFTER RUNNING THIS GADGET,
  unless you specifically intend to keep whatever changed. This gadget
  now runs a toolpath recalculation as part of its normal checks (see
  RECALCULATE_TOOLPATHS_TO_CHECK_ERRORS below) - this is the only
  known way to catch a toolpath whose source vectors have been deleted
  (VCarve's own UI gives no visible indication of this - confirmed
  2026-08-15 against a real file with exactly this problem). Running
  it will mark the job as "modified" in VCarve even when nothing was
  actually wrong. That's expected and harmless AS LONG AS you close
  without saving (or explicitly discard changes) once you're done
  reviewing - the change only exists in VCarve's in-memory session
  until you choose to save it.

  Status: v1, built directly from the "Dragonfly Clock Instructions"
  Google Doc, NOT YET VALIDATED against a real student file's actual
  toolpath data (unlike CribbageBoardReviewReport.lua and
  BoxProjectReviewReport.lua, which both went through a dump-and-
  validate cycle against real geometry before their checks were
  trusted). Built now because a real student has chosen this project
  for the first time - the checks below that depend on hard numbers
  from the instructions are on solid footing; the ones that would
  require guessing at toolpath identification are deliberately left as
  a manual-review listing instead of an automated check - see
  IDENTIFICATION GAP below.

  IDENTIFICATION GAP - why toolpath-specific RPM/feed/plunge checking
  is NOT attempted here (unlike Cribbage Board and Box Project):
    - This project is a "Single-Sided" job (per explicit instruction)
      even though it's physically machined on both faces - the
      student flips the stock and re-zeros by hand between the pocket/
      shaft-hole (back) operations and the carving/cutout (front)
      operations. Cribbage Board's toolpath identification relied on
      job:GetSideName() to distinguish sides; that signal doesn't
      exist here the same way, since VCarve's own data model only
      knows about one side for a Single-Sided job.
    - Depth alone doesn't uniquely identify every operation either.
      Several are cleanly unique (pocket ~ thickness-0.25", shaft hole
      0.27", final cutout ~ thickness+0.02" overcut), but the two
      V-Carve operations (numbers, dragonfly) don't have a fixed
      numeric depth at all - it's whatever falls out of the V-bit
      angle and each vector's width, which varies per student's exact
      artwork placement. And the accent circle (explicit 0.1" cut
      depth) and the chamfer (instructions only SUGGEST "you may want
      0.1"", not a hard spec) could easily collide at the same depth
      even though they're different operations on different geometry.
    - Rather than build a fragile identification scheme on paper
      without a real toolpath dump to check it against (the same
      trap Box Project's early feeds/speeds check nearly fell into
      before the compression-vs-downcut tool-library realization),
      every toolpath is listed for manual review instead (name, tool,
      feed/plunge/RPM, computed depth) - once a real student file's
      dump is available, ambiguous cases can be tightened the same
      way Box Project's checks were refined over several rounds.

  What it reports, for the currently open job:
    1. Job name + units
    2. Material size (9" x 9") and thickness vs. the 0.75" nominal,
       with a tolerance-based plausibility check plus a separate
       "exactly the nominal value" check (student likely never
       measured) - same two-check pattern as the other two projects
    3. Z-Zero (must be material surface) and XY-Datum (must be centre)
    4. Job type (must be Single-Sided, despite being physically
       machined on both faces - see IDENTIFICATION GAP above)
    5. Pocket geometry: a radiused rectangle, centred at the
       origin, 2.6875" (2 11/16") square, 0.5" corner radius - found
       by geometry across all layers, not by any assumed layer name
       (only "Pocket" was ever specified to students, and per Mike's
       direction this check no longer assumes any layer naming
       convention at all - same geometry-search approach as the
       Circles check)
    6. Overcut on the final cutout toolpath (the one whose depth
       exceeds material thickness) - reuses the same tp:Statistics().
       MinimumZ + CalcDepthFromAbsoluteZ mechanism validated on both
       other projects, target 0.02" into the spoilboard (same number
       as both other projects, though NOT independently confirmed
       with Mike for this project specifically - worth double-checking
       before trusting this flag)
    7. Standing manual reminders: tabs (same automatable-check gap as
       Box Project - see BoxProjectReviewReport.lua's
       FormatManualTabsReminder for the full investigation history)
       and first-pass depth for the compression-bit cutout (same
       upcut-length reasoning as Box Project)
    8. Every layer: name, object count, visible/locked
    9. Every toolpath: name, tool name/diameter/number, feeds/speeds,
       and computed depth from Z-zero - listed for MANUAL REVIEW, not
       spec-checked - see IDENTIFICATION GAP above

  REPORT ARCHITECTURE: uses the same Report/NewReport()/RecordsToHtml/
  BulletSectionHtml pattern as CribbageBoardReviewReport.lua and
  BoxProjectReviewReport.lua - severity is a real Lua value on each
  line record (nil / "warning" / "error"), never encoded as text. See
  either of those files' headers for the full history of why (a real
  copy/paste corruption bug from an earlier "!!"/"~~" text-marker
  design). Built into this file from day one rather than needing its
  own separate discovery/migration.
]]

require "strict"

-- GADGET VERSION - shown in the report header so any report can be
-- traced to the exact file that produced it. Scheme (Mike,
-- 2026-10-14), versioned PER GADGET, bumped by hand in the SAME commit
-- as the change (no build step, and VCarve's Lua sandbox can't reach
-- git, so this can't be generated automatically):
--   third digit  - any commit that changes this file
--   second digit - any commit that changes the report's OUTPUT, fixes
--                  included (resets the third digit to 0)
--   first digit  - ready to share beyond Steve; 0.x means beta
g_version = "0.10.0"
g_title = "Clock Review Report"
g_width = 900
g_height = 700
g_html_file = "ClockReviewReport.html"

-- Escapes text for safe insertion into the HTML dialog's innerHTML.
local function EscapeHtml(s)
    s = tostring(s)
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    return s
end

-- Returns a timestamp string for the report header, so a copy/pasted
-- report can be filed alongside the student's saved file with a clear
-- record of when it was reviewed. Wrapped in pcall since os.date()'s
-- availability in VCarve's sandboxed Lua environment wasn't confirmed
-- before adding this - falls back to a plain label if unavailable
-- rather than erroring out the whole report.
local function GetTimestampString()
    local ok, result = pcall(function() return os.date("%Y-%m-%d %H:%M") end)
    if ok and result then
        return result
    end
    return "(timestamp unavailable)"
end

--------------------------------------------------------------------
-- REPORT: a small builder for an ordered list of {text=, severity=}
-- records. See the REPORT ARCHITECTURE note at the top of this file.
-- Identical to CribbageBoardReviewReport.lua / BoxProjectReviewReport.lua's
-- version - ported from there.
--------------------------------------------------------------------
function NewReport()
    local report = { records = {}, flagged = false }

    function report:Line(text, severity)
        table.insert(self.records, { text = text, severity = severity })
        if severity == "warning" or severity == "error" then
            self.flagged = true
        end
    end

    function report:Blank()
        table.insert(self.records, { text = "", severity = nil })
    end

    function report:Header(text)
        self:Line(text)
        self:Line(string.rep("-", 40))
    end

    function report:Append(other)
        for _, rec in ipairs(other.records) do
            table.insert(self.records, rec)
        end
        if other.flagged then
            self.flagged = true
        end
    end

    return report
end

-- Renders a flat list of {text=, severity=} records as HTML. See
-- CribbageBoardReviewReport.lua / BoxProjectReviewReport.lua for the
-- full rationale - identical implementation, ported from there.
local function RecordsToHtml(records)
    local out = {}
    local current_severity = nil
    local current_run = {}

    local function FlushRun()
        if #current_run == 0 then return end
        local joined = table.concat(current_run, "<br>\n")
        if current_severity == "warning" then
            table.insert(out, "<b style=\"color:#b35900;\">" .. joined .. "</b>")
        elseif current_severity == "error" then
            table.insert(out, "<b style=\"color:#b00000;\">" .. joined .. "</b>")
        else
            table.insert(out, joined)
        end
        current_run = {}
    end

    for _, rec in ipairs(records) do
        local text = rec.text or ""
        local leading_spaces = text:match("^( *)") or ""
        local rest = text:sub(#leading_spaces + 1)
        local nbsp_prefix = string.rep("&nbsp;", #leading_spaces)
        local html_line = nbsp_prefix .. EscapeHtml(rest)

        if rec.severity ~= current_severity then
            FlushRun()
            current_severity = rec.severity
        end
        table.insert(current_run, html_line)
    end
    FlushRun()

    return table.concat(out, "<br>\n")
end

-- Renders one compact-summary section (WARNINGS or ERRORS) as a
-- colored header plus a numbered HTML list (switched from bullets to
-- numbers 2026-08-17, per Mike - lets us refer to "item 3" etc.
-- efficiently while working through a report together). Identical to
-- CribbageBoardReviewReport.lua / BoxProjectReviewReport.lua otherwise
-- (no severity-marker text anywhere in the displayed/copied content,
-- by construction) - only the list tag changed.
local function NumberedSectionHtml(title, records, color)
    local li_parts = {}
    for _, rec in ipairs(records) do
        local trimmed = (rec.text or ""):gsub("^%s*", "")
        table.insert(li_parts, "<li>" .. EscapeHtml(trimmed) .. "</li>")
    end
    return "<br>\n<div style=\"color:" .. color .. ";\"><b>" .. title .. "</b>" ..
        "<ol style=\"margin:2px 0 10px 0; padding-left:20px;\">" ..
        table.concat(li_parts, "\n") .. "</ol></div>"
end

--------------------------------------------------------------------
-- EXPECTED PROJECT SETUP (Dragonfly Clock)
-- Source: "Dragonfly Clock Instructions" (Google Doc)
--------------------------------------------------------------------

-- Same units-conversion approach as BoxProjectReviewReport.lua - every
-- inches-denominated constant below is converted to the job's actual
-- units before comparing, in case a student's job is set to mm.
INCHES_TO_MM = 25.4

function ToJobUnits(value_inches, mtl_block)
    if mtl_block.InMM then
        return value_inches * INCHES_TO_MM
    end
    return value_inches
end

-- Stock: 9" x 9" x 0.75" (square, so no orientation ambiguity to
-- worry about the way Box Project's rectangular stock had).
STOCK_SIZE_IN = 9.0     -- inches
STOCK_SIZE_TOLERANCE_IN = 0.1  -- inches - small margin for cutting/kerf

NOMINAL_THICKNESS_IN = 0.75  -- inches
THICKNESS_PLAUSIBLE_TOL_IN = 0.05  -- inches - same plausibility-band
                                     -- approach as the other two
                                     -- projects: catches a wildly
                                     -- wrong/stale value, not a strict
                                     -- spec (student measures their
                                     -- own stock)

-- Pocket rectangle: 2.6875" (2 11/16") square, centred at the
-- origin, with 0.5" radiused corners. Its layer is NOT assumed to
-- have any particular name (only "Pocket" was ever specified to
-- students, and even that wasn't consistently enforceable) - found by
-- geometry across ALL layers instead, same approach as the circles
-- check below. Detection band set well clear of the shaft hole
-- (~0.35") and the two big circles (7.5"/8.25"), so nothing else in
-- the file should land in this range.
POCKET_SIZE_IN = 2.6875  -- inches
POCKET_SIZE_TOLERANCE_IN = 0.02  -- inches
POCKET_CORNER_RADIUS_IN = 0.5  -- inches
POCKET_CORNER_RADIUS_TOLERANCE_IN = 0.01  -- inches
POCKET_CENTER_TOLERANCE_IN = 0.02  -- inches
POCKET_SQUARENESS_TOLERANCE_IN = 0.05  -- inches - max allowed
                                         -- width/height mismatch to
                                         -- still count as "square-ish"
POCKET_DETECTION_MIN_IN = 2.0  -- inches
POCKET_DETECTION_MAX_IN = 3.5  -- inches

-- Circles: outer circle 8.25" diameter, centred at origin. Inner
-- circle inset 3/8" from the outer one via Offset Vectors, so its
-- diameter is 8.25" - 2*0.375" = 7.5" exactly, same centre. Neither
-- circle's layer is named in the instructions, so these are searched
-- for across ALL layers rather than one specific layer - detection
-- band set well above the shaft hole (~0.35") and well below the 9"
-- stock edge, so nothing else in the file should land in this range.
CIRCLE_OUTER_DIA_IN = 8.25  -- inches
CIRCLE_INNER_OFFSET_IN = 0.375  -- inches (3/8")
CIRCLE_DIA_TOLERANCE_IN = 0.02  -- inches
CIRCLE_CENTER_TOLERANCE_IN = 0.02  -- inches
CIRCLE_ROUNDNESS_TOLERANCE_IN = 0.01  -- inches - max allowed
                                        -- width/height mismatch to
                                        -- still count as "circular"
                                        -- (same technique validated in
                                        -- CribbageBoardReviewReport.lua's
                                        -- dowel hole detection)
CIRCLE_DETECTION_MIN_IN = 5.0  -- inches
CIRCLE_DETECTION_MAX_IN = 9.0  -- inches

-- Numbers arrangement: 12 text objects ("1" through "12"), placed via
-- Circular Copy centred on the origin. We do NOT try to read the
-- actual digit content (the SDK exposes a castable TxtBlock type via
-- CastCadObjectToTxtBlock(), but its properties - including whether
-- it even has a readable text string - are entirely undocumented in
-- the 7000+ line SDK reference, unlike every other CAD object type,
-- which all get full property listings). Per Mike, that's fine - he'll
-- see at a glance whether the numbers read 1-12 correctly. What's hard
-- to catch by eye is whether the ring is subtly OFF-CENTER from the
-- workpiece origin while still looking evenly spaced - that's what
-- this check targets: centroid of all 12 bounding-box centers should
-- sit at the origin, and each one's distance from that centroid should
-- be consistent (a clean circle, not stretched/lopsided).
--
-- CONFIRMED against clock01.crv 2026-08-13: ClassName is "txtBlock"
-- (lowercase, no "vc" prefix - breaks the naming pattern every other
-- cast helper follows, e.g. CastCadObjectToCadBitmap <-> "vcCadBitmap").
-- Found exactly 12 objects on the "numbers" layer, matching the
-- layer's own object count exactly - strong confirmation this is the
-- right detection target. The class-name fallback dump (see
-- FindNumberTextCandidates) is what caught the original wrong guess
-- ("vcTxtBlock") in one round rather than a blind second guess.
NUMBERS_COUNT_EXPECTED = 12
NUMBERS_CENTER_TOLERANCE_IN = 0.02  -- inches - max allowed distance
                                     -- of the combined bounding box's
                                     -- centre from the origin
NUMBERS_ANGULAR_OUTLIER_SIGMA_THRESHOLD = 2.0  -- degrees are
                                     -- converted to a z-score, same
                                     -- method as the radius-outlier
                                     -- check below.

-- Radius-outlier and angular-position checks - see
-- NUMBERS_POSITION_CHECKS_ENABLED below for their current disabled
-- status and the full reason why.

-- Radius-outlier check (2026-08-18, per Mike): catches a SINGLE
-- number pushed radially in/out from the ring while still at the
-- correct ANGLE - a genuinely different failure mode from angular
-- spacing, which is blind to this by construction. Real motivating
-- case: the instructions explicitly warn students not to let a
-- number overlap the dragonfly's wings, and the natural fix for an
-- inexperienced user is to nudge just that one number outward, not
-- rebuild the whole ring.
--
-- Method: z-score outlier detection. For each digit, compute how many
-- STANDARD DEVIATIONS its radius (from the combined-bbox centre) is
-- from the mean radius of all 12. Flag any digit exceeding the
-- threshold below.
--
-- CRITICAL METHODOLOGY NOTE: the mean and standard deviation MUST be
-- computed across ALL 12 digits, including whichever one might be
-- the outlier - a real check can never know in advance which digit is
-- bad, so it can't exclude it from its own baseline statistics. An
-- early hand calculation (2026-08-18) mistakenly computed the
-- baseline using only the 11 known-good digits on a test file,
-- which inflated the apparent signal strength (~4 sigma) - the
-- honest, all-12 calculation on the same file gave a real but
-- meaningfully weaker signal (~2.5 sigma), because a genuine outlier
-- inflates the very spread being used to detect it. Uses SAMPLE
-- standard deviation (N-1 denominator, Bessel's correction) - the
-- standard choice for estimating spread from a small sample.
--
-- THRESHOLD UNVALIDATED - 2 sigma is Mike's chosen starting point,
-- confirmed to catch a ~0.11" radial displacement (~2.5 sigma,
-- computed honestly) on one real test file. A second test file with a
-- smaller, deliberately marginal displacement (the smallest one that
-- reads as visually wrong) is in progress (2026-08-18) to find out
-- where the real detection boundary sits - this threshold should be
-- revisited once that data comes in.
NUMBERS_RADIUS_OUTLIER_SIGMA_THRESHOLD = 2.0

-- DISABLED (2026-08-18) - see FormatNumbersArrangementReport for how
-- this gates both the centering check AND both outlier checks above.
-- FULL HISTORY, for whoever picks this back up:
--
-- The centering check (combined bounding box vs origin) and both
-- outlier checks (radius, angular) were built and validated across
-- several real test files on 2026-08-18 - genuinely good validation
-- work, confirmed against deliberate displacements AND confirmed
-- silent on Mike's original CorrectClock reference file.
--
-- Then Mike rebuilt CorrectClock completely from scratch, following
-- the WRITTEN INSTRUCTIONS exactly (not reusing the original file),
-- to test whether the checks held up independently. They didn't: the
-- rebuild produced the SAME false-positive centering offset (0.0457
-- inches both times) and the SAME false-positive angular outlier, at
-- the SAME 11-12 boundary, to a TENTH OF A DEGREE, on both the
-- original CorrectClock and the from-scratch rebuild. That precision
-- ruled out random noise - it's a deterministic artifact of the
-- construction method itself, not bad luck on one file.
--
-- ROOT CAUSE, CONFIRMED via a bounding-box-size diagnostic: the
-- instructions have students create numbers using VCarve's Text in a
-- Box mode with a fixed 1x1 inch box. For single-digit numbers (1-9),
-- height is the binding constraint (locked at exactly 0.8000 inches
-- every time); for two-digit numbers (10/11/12), WIDTH becomes the
-- binding constraint instead, and height shrinks to preserve the
-- glyph's natural proportions (measured 0.64-0.67 inches vs the
-- single digits' 0.80). This is a genuine, deterministic bias in the
-- Text in a Box rendering mechanism itself, not measurement noise -
-- it will reproduce identically on every file built this way.
--
-- A candidate fix was tried and tested: switching from Text in a Box
-- to plain Text mode (VCarve DOES support this - confirmed via
-- Vectric's own documentation: text can be created at any height -
-- not a made-up feature) with a fixed font height instead of a fixed
-- box. This DID eliminate both false positives - but Mike judged the
-- visual RESULT worse: without the box-fit squishing narrower, 10/11/
-- 12 sit too close to the inner accent circle by eye. The old method
-- was accidentally solving a real spacing problem that the cleaner
-- method doesn't.
--
-- DECISION (Mike, 2026-08-18): keep the ORIGINAL Text in a Box
-- construction method - it produces the better visual result, and
-- that matters more than measurability. Independent corroboration
-- (Mike recalled, 2026-08-18): a VCarve clock-building tutorial he'd
-- watched previously used plain "Text" mode and explicitly warned
-- that Circular Copy's automatic placement needed tedious manual
-- "tweaking" afterward to avoid numbers crowding each other - almost
-- certainly the exact unsquished-two-digit-width problem this
-- investigation found. "Text in a Box" isn't just Mike's aesthetic
-- preference - it appears to solve a real, apparently well-known
-- VCarve pain point automatically, by construction, without anyone
-- needing to manually adjust anything.
--
-- Given the false-positive risk (see the design-principle memory note
-- on why even ONE false positive can cost an entire tool's
-- credibility, especially for student-facing/grading tools), these
-- two checks are DISABLED rather than shipped with a corrected
-- threshold - a correction built from only two data points, on one
-- VCarve version/font-rendering setup, is exactly the kind of
-- fragile, unvalidated fix this project has learned NOT to trust.
--
-- If revisiting this: the deterministic 0.8 vs ~0.65 inch height
-- split, and the exact 0.0457 inch centering offset it produces, are
-- BOTH real and reproducible - not values to re-tune around, but a
-- correction FACTOR that could in principle be computed and
-- subtracted out (e.g. correcting the combined bounding box using
-- each candidate's OWN measured width/height ratio to infer whether
-- it hit the box's width or height constraint, and adjusting
-- accordingly). That's a real, buildable idea - just not attempted
-- yet, and would need fresh validation against new real files before
-- trusting it either.
NUMBERS_POSITION_CHECKS_ENABLED = false

-- Dragonfly artwork: identified by ELIMINATION (2026-08-16 redesign),
-- not by grouping. Earlier versions of this check required the
-- dragonfly to be a single vcCadObjectGroup, but that broke down for
-- a real reason Mike identified: the Center Hole toolpath needs to
-- target one specific small circle INSIDE the artwork individually,
-- which isn't possible while it's wrapped in a group. The correct
-- student workflow is now: group temporarily (to protect the ~52
-- pieces from accidental distortion during move/scale/align), then
-- UNGROUP once alignment is done, so every piece - including that one
-- circle - stays individually selectable for toolpath creation
-- afterward. That means a correctly-built file may have the dragonfly
-- grouped, ungrouped, or (mid-workflow) briefly regrouped again by
-- the time it's reviewed - no assumption about grouping state is
-- reliable anymore.
--
-- Per Mike: since circles, pocket, and numbers are all already
-- reliably identified elsewhere in this file, "the dragonfly" doesn't
-- need its own positive-identification scheme - it's simply
-- everything left over once those three are accounted for. This is
-- inherently indifferent to grouping state, since it never looks for
-- a group at all: it walks every object in the job (recursing one
-- level into any group encountered, exactly like the numbers check
-- already does for a grouped-numbers case), and excludes anything
-- whose Id matches an object already claimed by the circles/pocket/
-- numbers finders (see GetObjectIdString / GetDragonflyClaimedIds
-- below). CONFIRMED 2026-08-16 via live diagnostic against a real
-- file: CadObject.Id does NOT expose :AsString() (contrary to its
-- documented type) and does NOT accept the luaUUID()+SetId() wrapper
-- that works for Toolpath.Id - but tostring(obj.Id) DOES produce a
-- stable, identical GUID string across independent scans of the same
-- object, which is what's actually used for matching.
--
-- Per Mike, the dragonfly should also live on its OWN layer,
-- isolated from every other feature - not about the layer's NAME (see
-- the same principle already established for the pocket layer
-- above), but about exclusivity. Unlike the pocket's version of this
-- check (a WARNING, since it's just good practice), Mike confirmed
-- this should be an ERROR for the dragonfly (2026-08-16) - he's
-- comfortable requiring it outright, and it also serves as a sanity
-- check on the elimination logic itself: if the leftover objects
-- aren't cleanly isolated to one layer, something's likely gone wrong
-- upstream (e.g. a mis-detected circle/pocket/number).

-- Center-alignment circles WITHIN the dragonfly artwork: per Mike,
-- there are two (or more) concentric circles near the dragonfly's
-- visual center that should align with the workpiece origin. Per the
-- instructions, this alignment is explicitly done BY EYE ("You cannot
-- use VCarve's centering tool for this because the center of the
-- artwork doesn't correspond with the center of the circle") - unlike
-- the numbers ring, Mike hasn't asked to eliminate the by-eye method
-- here (there's no Alignment-tool substitute available, since the
-- target point isn't the bounding-box center of anything). So this
-- check has a real, non-zero expected tolerance rather than a tight
-- one - Mike's starting point, to be tuned once real data comes in:
-- 0.5mm.
--
-- No target DIAMETER exists for these circles (whatever size the SVG
-- artist drew) - detection instead looks for circles that share a
-- common center with each other (true concentricity, which two
-- deliberately-drawn concentric circles will have almost exactly,
-- since they came from the same original artwork), among the
-- dragonfly's leftover objects (see above - no longer specifically a
-- group's members, just whatever the elimination logic found). A
-- cluster of matching centers is the alignment target; that cluster's
-- position is then checked against the origin.
DRAGONFLY_CENTER_CIRCLE_TOLERANCE_IN = 0.5 / INCHES_TO_MM  -- 0.5mm,
                                     -- Mike's starting point ("let's
                                     -- try .5mm and see how that
                                     -- works out") - by-eye alignment,
                                     -- so meaningfully looser than the
                                     -- numbers ring's 0.02"
DRAGONFLY_CIRCLE_ROUNDNESS_TOLERANCE_IN = 0.01  -- inches - same
                                     -- roundness check as other
                                     -- circle detection in this file
DRAGONFLY_CONCENTRIC_CLUSTER_TOLERANCE_IN = 0.01  -- inches - how
                                     -- close two circles' centers
                                     -- must be to count as the SAME
                                     -- center (true concentricity,
                                     -- not the by-eye alignment
                                     -- tolerance above) - tight,
                                     -- since genuinely concentric
                                     -- circles from the original
                                     -- artwork should match almost
                                     -- exactly. UNVALIDATED against
                                     -- real geometry - if this proves
                                     -- too tight or too loose against
                                     -- Mike's test file, the fallback
                                     -- dump (see
                                     -- FormatDragonflyCenterCircleReport)
                                     -- shows every circular candidate
                                     -- found, for tuning.

-- Final cutout overcut target - same number as both other projects
-- (0.02" into the spoilboard), carried over by analogy. NOT
-- independently confirmed with Mike for this specific project - worth
-- double-checking before trusting this particular flag.
OVERCUT_TARGET_IN = 0.020  -- inches into the spoilboard
OVERCUT_TOLERANCE_IN = 0.010  -- inches

-- Float slack on the tolerance comparison (2026-10-14, v0.10.0),
-- ported from BoxProjectReviewReport.lua. Overcut = depth - thickness,
-- both floats, so a value meant to sit exactly on the tolerance edge
-- (e.g. 0.010") can compute as 0.0099999..., print as "0.0100", and
-- still fail - a real false positive seen on a Box Project file.
-- 0.001" per Mike: physically negligible for spoilboard overcut.
BOUNDARY_EPSILON_IN = 0.001  -- inches

-- Expected toolpath count: 7 (pocket, accent circle, shaft hole,
-- V-carve numbers, V-carve dragonfly, final cutout, chamfer). Simple
-- count check - catches a leftover/unrecognized toolpath from an
-- earlier design (a real example: a "Micrometer" toolpath found in
-- CorrectClock 2026-08-15, referencing vectors no longer in the
-- design) without needing to identify WHICH 7 operations are present
-- - see IDENTIFICATION GAP at the top of this file for why that
-- deeper identification isn't attempted.
TOOLPATHS_COUNT_EXPECTED = 7

-- Toolpath ORDER requirements (per Mike, 2026-08-17):
--   1. Pocket toolpath must be FIRST - it's the very first operation,
--      since work starts on the back of the workpiece.
--   2. Cutout toolpath must be LAST or SECOND-TO-LAST.
--   3. If anything follows the cutout, it must be a V-BIT toolpath -
--      once the piece is only tab-held (not fully embedded in the
--      stock), an end-mill operation's lateral cutting loads could
--      break the tabs prematurely; a shallow V-bit pass (the chamfer)
--      is the only thing considered safe to run at that point.
-- Deliberately does NOT try to identify "the chamfer" specifically by
-- name (per Mike: don't identify tools by name) - the requirement is
-- checked directly via Tool.ToolType == Tool.VBIT, a documented
-- integer enum read straight off the toolpath's actual tool, immune
-- to renaming.
--
-- Pocket identified by DEPTH (thickness - 0.25", the instructions'
-- "z-.25" formula) - already noted as "cleanly unique" in the
-- IDENTIFICATION GAP note above, just not previously built as an
-- actual check. Cutout identified via the SAME through-cut threshold
-- the Overcut check uses (see IsThroughCutDepth below) - deliberately
-- NOT via a second independent scan matched back to this check's own
-- scan by object reference: Toolpath has no documented == operator
-- (same category of risk already hit and worked around differently
-- for CadObject.Id, 2026-08-16), so this check does its OWN single
-- scan and applies the identical depth-threshold predicate rather
-- than trying to match toolpath objects across two separate scans.
POCKET_TOOLPATH_DEPTH_OFFSET_IN = 0.25  -- inches, subtracted from
                                          -- material thickness
POCKET_TOOLPATH_DEPTH_TOLERANCE_IN = 0.02  -- inches

-- Toolpath recalculation check - DESTRUCTIVE, but ON BY DEFAULT as
-- of 2026-08-15. :RecalculateToolpath() explicitly destroys the
-- original toolpath and creates a new one with the same ID (per the
-- SDK reference) - this is the only known way to detect a toolpath
-- whose source vectors have been deleted (no documented read-only
-- "IsBroken"/"SourceVectorsMissing" flag exists on the Toolpath
-- object - checked the full documented property list; the closest
-- candidate, ToolpathStats.IsValid, only reflects whether the
-- toolpath has EVER been calculated, not whether its current source
-- geometry still exists).
--
-- WHY DEFAULT-ON despite being destructive: per Mike, VCarve's own
-- UI gives NO visible indication when a toolpath's source vectors are
-- gone (confirmed against a real file - CorrectClock's leftover
-- "Micrometer" toolpath referenced deleted vectors with nothing in
-- the Toolpaths list or elsewhere flagging it). Without this check
-- actively running, that kind of broken toolpath would reach the
-- machine appointment completely undetected. Given the two real risks
-- below are both now confirmed safe, the risk of a SILENT machining
-- failure outweighs the inconvenience of remembering not to save.
--
-- PASS DEPTHS AND TABS BOTH CONFIRMED SAFE (per Mike, direct
-- experience, 2026-08-15): a plain recalculation preserves per-pass
-- depth settings AND tab placement/enablement. What actually resets
-- pass depths is CHANGING MATERIAL THICKNESS - VCarve then
-- recalculates passes from tool properties alone, with no way to know
-- the instructor's own first-pass-depth convention for compression
-- bits. Tabs surviving recalculation is expected VCarve behavior too
-- (per Mike: losing tab placement on a routine recalculation would be
-- a widely-reported bug, not a quiet edge case). This check never
-- touches material thickness, only calls :RecalculateToolpath(), so
-- the thickness-driven reset path is never triggered either way.
--
-- Regardless of the above: recalculating will mark the in-memory job
-- as modified ("dirty") even for a fully healthy file where nothing
-- actually changed - see the STANDING NOTE at the very top of this
-- file, and the report's own output, which repeats this reminder
-- every time the check runs.
RECALCULATE_TOOLPATHS_TO_CHECK_ERRORS = true

-- Set to true to see the FULL report (every layer, every toolpath,
-- all passing checks included) instead of just the flagged issues.
-- No separate gadget needed - flip this, save, and re-run the same
-- gadget from the menu. Flip back to false afterward to go back to
-- the compact summary.
VERBOSE_OUTPUT = false

function FormatMaterialSetupReport(mtl_block)
    local r = NewReport()
    local units = mtl_block.InMM and "mm" or "inches"

    r:Header("MATERIAL SETUP CHECKS")

    -- Stock size: 9" x 9", square, so both dimensions checked the same way
    local stock_size = ToJobUnits(STOCK_SIZE_IN, mtl_block)
    local stock_tol = ToJobUnits(STOCK_SIZE_TOLERANCE_IN, mtl_block)
    if math.abs(mtl_block.Width - stock_size) > stock_tol
       or math.abs(mtl_block.Height - stock_size) > stock_tol then
        r:Line(string.format(
            "  STOCK SIZE MISMATCH: expected %.2f x %.2f %s, actual %.3f x %.3f %s",
            stock_size, stock_size, units, mtl_block.Width, mtl_block.Height, units
        ), "error")
    end

    -- Thickness plausibility - NOT a strict spec, student measures
    -- their own stock (instructions explicitly call this out: "The
    -- 0.75" here is close enough to get you started on the design
    -- work, but not good enough for the actual cutting operations").
    local nominal_thickness = ToJobUnits(NOMINAL_THICKNESS_IN, mtl_block)
    local thickness_plausible_tol = ToJobUnits(THICKNESS_PLAUSIBLE_TOL_IN, mtl_block)
    local thickness_diff = mtl_block.Thickness - nominal_thickness
    if math.abs(thickness_diff) > thickness_plausible_tol then
        r:Line(string.format(
            "  THICKNESS UNUSUAL: nominal=%.3f actual=%.3f %s",
            nominal_thickness, mtl_block.Thickness, units
        ), "error")
    end

    -- Exact-default detection - same rationale as both other projects:
    -- real measured stock essentially never comes out to EXACTLY the
    -- nominal value. Several of this project's operations (the pocket
    -- depth "z-.25", the shaft hole depth 0.27", the cutout depth
    -- "z+.02") are all expressed RELATIVE to material thickness, so an
    -- unmeasured default here has knock-on effects on several
    -- operations at once, not just one - worth flagging clearly.
    local exact_default_epsilon = ToJobUnits(0.0005, mtl_block)
    if math.abs(thickness_diff) < exact_default_epsilon then
        r:Line(string.format(
            "  THICKNESS IS EXACTLY %.3f %s (the nominal default) - has the student measured their actual stock?",
            nominal_thickness, units
        ), "warning")
    end

    -- Z-zero: should be material surface (Z_TOP) - explicit
    -- instruction: "set your Z Zero Position to the material surface"
    local z_origin = mtl_block.ZOrigin
    local z_origin_text = "unknown"
    if z_origin == MaterialBlock.Z_TOP then
        z_origin_text = "Top of Material (correct)"
    elseif z_origin == MaterialBlock.Z_CENTRE then
        z_origin_text = "Centre of Material"
    elseif z_origin == MaterialBlock.Z_BOTTOM then
        z_origin_text = "Bottom of Material"
    end
    r:Line("  Z-Zero: " .. z_origin_text)
    if z_origin ~= MaterialBlock.Z_TOP then
        r:Line("  Z-ZERO should be material surface, is " .. z_origin_text, "error")
    end

    -- XY-Datum: should be centre of workpiece - explicit instruction:
    -- "set your ... XY Datum to the center of your workpiece"
    local xy_origin = mtl_block.XYOrigin
    local xy_origin_text = "unknown"
    if xy_origin == MaterialBlock.CENTRE then
        xy_origin_text = "Centre (correct)"
    elseif xy_origin == MaterialBlock.BLC then
        xy_origin_text = "Bottom Left Corner"
    elseif xy_origin == MaterialBlock.BRC then
        xy_origin_text = "Bottom Right Corner"
    elseif xy_origin == MaterialBlock.TRC then
        xy_origin_text = "Top Right Corner"
    elseif xy_origin == MaterialBlock.TLC then
        xy_origin_text = "Top Left Corner"
    end
    r:Line("  XY-Datum: " .. xy_origin_text)
    if xy_origin ~= MaterialBlock.CENTRE then
        r:Line("  XY-DATUM should be centre of workpiece, is " .. xy_origin_text, "error")
    end

    return r
end

function FormatJobTypeReport(job)
    local r = NewReport()
    r:Blank()
    r:Header("JOB TYPE CHECK")

    -- Explicit instruction: "Even though this is technically a
    -- double-sided job, we are not using the special features VCarve
    -- has for this kind of work. Please set up for a 'Single Sided' job."
    -- Severity is WARNING, not error, per Mike (2026-08-15): a
    -- Two-Sided setup doesn't actually break the file if the student
    -- is manually flipping/re-zeroing rather than relying on VCarve's
    -- built-in alignment mechanism (confirmed against a real test file
    -- that ran correctly despite this setting) - it's a genuine
    -- conceptual gap worth addressing with the student, but not
    -- something that prevents the job from being cut correctly the way
    -- the other ERROR-level checks in this file do.
    if not job.IsDoubleSided then
        r:Line("  Job type: Single-Sided (correct)")
    else
        r:Line("  JOB TYPE: expected Single-Sided (per instructions, even though physically machined on both faces), is set up as two-sided", "warning")
    end

    return r
end

-- Finds closed contours across ALL non-system layers whose bounding
-- box is square-ish and within a given size band, AND that mix at
-- least one straight-line span with at least one arc span - that
-- combination is what a rounded-corner rectangle produces (4 lines +
-- 4 corner arcs), which a plain circle (drawn via the Circle tool,
-- typically 1-2 pure arc spans with no lines) would not match even if
-- its diameter happened to fall in the same size band. Returns a list
-- of {x_len=, y_len=, x=, y=, layer_name=, contour=}.
function FindRadiusedRectangleContours(job, min_size, max_size, squareness_tol)
    local candidates = {}
    local layer_manager = job.LayerManager
    local layer_pos = layer_manager:GetHeadPosition()

    while layer_pos ~= nil do
        local layer
        layer, layer_pos = layer_manager:GetNext(layer_pos)

        if not layer.IsSystemLayer then
            local obj_pos = layer:GetHeadPosition()
            while obj_pos ~= nil do
                local obj
                obj, obj_pos = layer:GetNext(obj_pos)

                local ok, contour = pcall(function() return obj:GetContour() end)
                if ok and contour and contour.IsClosed then
                    local bb = contour.BoundingBox2D
                    if bb and not bb.IsInvalid
                       and bb.XLength >= min_size and bb.XLength <= max_size
                       and bb.YLength >= min_size and bb.YLength <= max_size
                       and math.abs(bb.XLength - bb.YLength) < squareness_tol then

                        local has_line, has_arc = false, false
                        local span_pos = contour:GetHeadPosition()
                        while span_pos ~= nil do
                            local span
                            span, span_pos = contour:GetNext(span_pos)
                            if span.IsLineType then has_line = true end
                            if span.IsArcType then has_arc = true end
                        end

                        if has_line and has_arc then
                            table.insert(candidates, {
                                x_len = bb.XLength,
                                y_len = bb.YLength,
                                x = bb.Centre.x,
                                y = bb.Centre.y,
                                layer_name = layer.Name,
                                layer_object_count = layer.Count,
                                contour = contour,
                                obj = obj,
                            })
                        end
                    end
                end
            end
        end
    end

    return candidates
end

-- Returns a stable string identity for a CadObject. CONFIRMED
-- 2026-08-16 via live diagnostic against a real file: obj.Id does NOT
-- have an :AsString() method (contrary to documentation, which claims
-- it's already a luaUUID) and does NOT accept the luaUUID()+SetId()
-- wrapper pattern that works for Toolpath.Id either (a type mismatch
-- - "No matching overload found") - both of those were dead ends.
-- What DOES work, confirmed directly: tostring(obj.Id) produces the
-- object's real, stable GUID string (e.g.
-- "69f06b80-4232-487e-afa6-951766773a2b"), IDENTICAL across two
-- completely independent scans of the same underlying object - exactly
-- the property needed to use it as a table key for the "already
-- claimed by another check" set below. Used by the dragonfly-by-
-- elimination logic - see the DRAGONFLY comment block above.
function GetObjectIdString(obj)
    local ok, id_str = pcall(function() return tostring(obj.Id) end)
    if ok and id_str then
        return id_str, nil
    end
    return nil, string.format("tostring(obj.Id) failed: %s", tostring(id_str))
end

-- Builds the set of object-id-strings already claimed by the circles,
-- pocket, and numbers checks - reusing those checks' EXACT finder
-- functions (same parameters used in their own Format* reports), so
-- the claimed set can never disagree with what those checks actually
-- found. Used by the dragonfly-by-elimination logic below - see the
-- DRAGONFLY comment block above for the full rationale.
function GetDragonflyClaimedIds(job, mtl_block)
    local claimed = {}
    local sample_diagnostic = nil

    local function ClaimAll(candidates)
        for _, c in ipairs(candidates) do
            if c.obj then
                local id_str, diag = GetObjectIdString(c.obj)
                if id_str then
                    claimed[id_str] = true
                elseif not sample_diagnostic then
                    sample_diagnostic = diag
                end
            end
        end
    end

    local circle_min = ToJobUnits(CIRCLE_DETECTION_MIN_IN, mtl_block)
    local circle_max = ToJobUnits(CIRCLE_DETECTION_MAX_IN, mtl_block)
    ClaimAll(FindLargeCircularContours(job, circle_min, circle_max))

    local pocket_squareness_tol = ToJobUnits(POCKET_SQUARENESS_TOLERANCE_IN, mtl_block)
    local pocket_min = ToJobUnits(POCKET_DETECTION_MIN_IN, mtl_block)
    local pocket_max = ToJobUnits(POCKET_DETECTION_MAX_IN, mtl_block)
    ClaimAll(FindRadiusedRectangleContours(job, pocket_min, pocket_max, pocket_squareness_tol))

    local number_candidates = FindNumberTextCandidates(job)
    ClaimAll(number_candidates)

    return claimed, sample_diagnostic
end

-- Walks every object in the job (recursing one level into any group
-- encountered, exactly like FindNumberTextCandidates already does for
-- a grouped-numbers case), and returns whatever is NOT in the claimed
-- set - this is "the dragonfly" by elimination (see DRAGONFLY comment
-- block above). Also returns per-layer statistics (leftover_count,
-- claimed_count) used to check layer isolation. Returns
-- (leftover_objects, layer_stats) where leftover_objects is a list of
-- {obj=, layer_name=}.
function FindDragonflyObjectsAndLayerStats(job, claimed_ids)
    local leftovers = {}
    local layer_stats = {}
    local sample_diagnostic = nil

    local function Track(layer_name, is_claimed)
        local stats = layer_stats[layer_name]
        if not stats then
            stats = { leftover_count = 0, claimed_count = 0 }
            layer_stats[layer_name] = stats
        end
        if is_claimed then
            stats.claimed_count = stats.claimed_count + 1
        else
            stats.leftover_count = stats.leftover_count + 1
        end
    end

    local layer_manager = job.LayerManager
    local layer_pos = layer_manager:GetHeadPosition()
    while layer_pos ~= nil do
        local layer
        layer, layer_pos = layer_manager:GetNext(layer_pos)

        if not layer.IsSystemLayer then
            local obj_pos = layer:GetHeadPosition()
            while obj_pos ~= nil do
                local obj
                obj, obj_pos = layer:GetNext(obj_pos)

                local ok_class, class_name = pcall(function() return obj.ClassName end)
                if ok_class and class_name == "vcCadObjectGroup" then
                    local ok_group, group = pcall(function() return CastCadObjectToCadObjectGroup(obj) end)
                    if ok_group and group then
                        local gpos = group:GetHeadPosition()
                        while gpos ~= nil do
                            local gobj
                            gobj, gpos = group:GetNext(gpos)
                            local id_str, diag = GetObjectIdString(gobj)
                            if not id_str and not sample_diagnostic then
                                sample_diagnostic = diag
                            end
                            local is_claimed = id_str and claimed_ids[id_str] == true
                            Track(layer.Name, is_claimed)
                            if not is_claimed then
                                table.insert(leftovers, { obj = gobj, layer_name = layer.Name })
                            end
                        end
                    end
                else
                    local id_str, diag = GetObjectIdString(obj)
                    if not id_str and not sample_diagnostic then
                        sample_diagnostic = diag
                    end
                    local is_claimed = id_str and claimed_ids[id_str] == true
                    Track(layer.Name, is_claimed)
                    if not is_claimed then
                        table.insert(leftovers, { obj = obj, layer_name = layer.Name })
                    end
                end
            end
        end
    end

    return leftovers, layer_stats, sample_diagnostic
end

-- Dragonfly layer check: finds the dragonfly by elimination (see
-- DRAGONFLY comment block above) and verifies it's isolated on its
-- own layer - not by name, by exclusivity (same principle as the
-- pocket's layer-sharing check, but ERROR severity here per Mike's
-- explicit confirmation, since he's comfortable requiring this
-- outright rather than just recommending it).
function FormatDragonflyLayerReport(job, mtl_block)
    local r = NewReport()

    r:Blank()
    r:Header("DRAGONFLY LAYER CHECK")

    local claimed_ids, claim_diag = GetDragonflyClaimedIds(job, mtl_block)
    local leftovers, layer_stats, walk_diag = FindDragonflyObjectsAndLayerStats(job, claimed_ids)

    if #leftovers == 0 then
        r:Line("  NO leftover objects found after accounting for circles/pocket/numbers - dragonfly missing?", "error")
        return r
    end

    local layer_names_seen = {}
    for _, lo in ipairs(leftovers) do
        layer_names_seen[lo.layer_name] = true
    end
    local distinct_layers = {}
    for name in pairs(layer_names_seen) do
        table.insert(distinct_layers, name)
    end

    if #distinct_layers > 1 then
        local breakdown_parts = {}
        for _, name in ipairs(distinct_layers) do
            table.insert(breakdown_parts, string.format("'%s'=%d", name, layer_stats[name].leftover_count))
        end
        r:Line(string.format(
            "  DRAGONFLY NOT ON ITS OWN LAYER: %d leftover object(s) span %d different layers (%s) - should be isolated on a single layer",
            #leftovers, #distinct_layers, table.concat(breakdown_parts, ", ")
        ), "error")
        -- ID-resolution diagnostic (see GetObjectIdString comment):
        -- if a sample failure exists from EITHER the claim-building
        -- pass or the leftover-walk pass, surface the real pcall error
        -- text directly, guaranteed-visible - this is likely the ACTUAL
        -- cause if it fires, not a genuine multi-layer split.
        if claim_diag or walk_diag then
            r:Line(string.format(
                "  ID RESOLUTION DIAGNOSTIC (likely the real cause above): claim-side=[%s] walk-side=[%s]",
                claim_diag or "ok", walk_diag or "ok"
            ), "error")
        end
        return r
    end

    local dragonfly_layer = distinct_layers[1]
    local stats = layer_stats[dragonfly_layer]

    r:Line(string.format("  %d object(s) found on layer '%s'", #leftovers, dragonfly_layer))

    if stats.claimed_count > 0 then
        r:Line(string.format(
            "  DRAGONFLY LAYER NOT ISOLATED: layer '%s' also contains %d object(s) already claimed by circles/pocket/numbers - should be on its own layer",
            dragonfly_layer, stats.claimed_count
        ), "error")
    end

    return r
end

-- Pocket geometry check: a radiused rectangle, 2.6875" square,
-- centred at the origin, with 0.5" corner radius. Found by geometry
-- (see FindRadiusedRectangleContours above) rather than by layer
-- name - see POCKET_* constants for why. Corner radius measured
-- directly off the arc spans, same technique validated in
-- BoxProjectReviewReport.lua's offset-radius check
-- (CastSpanToArcSpan:RadiusAndCentre()).
function FormatPocketGeometryReport(job, mtl_block)
    local r = NewReport()
    local units = mtl_block.InMM and "mm" or "inches"
    local pocket_size = ToJobUnits(POCKET_SIZE_IN, mtl_block)
    local pocket_size_tol = ToJobUnits(POCKET_SIZE_TOLERANCE_IN, mtl_block)
    local corner_radius_target = ToJobUnits(POCKET_CORNER_RADIUS_IN, mtl_block)
    local corner_radius_tol = ToJobUnits(POCKET_CORNER_RADIUS_TOLERANCE_IN, mtl_block)
    local center_tol = ToJobUnits(POCKET_CENTER_TOLERANCE_IN, mtl_block)
    local squareness_tol = ToJobUnits(POCKET_SQUARENESS_TOLERANCE_IN, mtl_block)
    local detect_min = ToJobUnits(POCKET_DETECTION_MIN_IN, mtl_block)
    local detect_max = ToJobUnits(POCKET_DETECTION_MAX_IN, mtl_block)

    r:Blank()
    r:Header("POCKET GEOMETRY CHECK")

    local candidates = FindRadiusedRectangleContours(job, detect_min, detect_max, squareness_tol)

    if #candidates == 0 then
        r:Line(string.format(
            "  NO radiused-rectangle-shaped contour found (expected 1, ~%.4f\" square) - pocket missing?",
            pocket_size
        ), "error")
        return r
    elseif #candidates > 1 then
        local candidate_parts = {}
        for i, c in ipairs(candidates) do
            table.insert(candidate_parts, string.format("#%d %.4fx%.4f at (%.4f,%.4f) layer='%s'", i, c.x_len, c.y_len, c.x, c.y, c.layer_name))
        end
        r:Line(string.format(
            "  %d radiused-rectangle-shaped contours found - expected exactly 1, review manually: %s",
            #candidates, table.concat(candidate_parts, "; ")
        ), "error")
        return r
    end

    local candidate = candidates[1]
    local contour = candidate.contour

    r:Line(string.format(
        "  Bounding box: %.4f x %.4f %s, centre (%.4f, %.4f)",
        candidate.x_len, candidate.y_len, units, candidate.x, candidate.y
    ))

    if math.abs(candidate.x_len - pocket_size) > pocket_size_tol
       or math.abs(candidate.y_len - pocket_size) > pocket_size_tol then
        r:Line(string.format(
            "  POCKET SIZE MISMATCH: expected %.4f x %.4f %s, actual %.4f x %.4f %s",
            pocket_size, pocket_size, units, candidate.x_len, candidate.y_len, units
        ), "error")
    end

    if math.abs(candidate.x) > center_tol or math.abs(candidate.y) > center_tol then
        r:Line(string.format(
            "  POCKET NOT CENTRED ON ORIGIN: centre=(%.4f, %.4f) %s (tolerance=%.3f)",
            candidate.x, candidate.y, units, center_tol
        ), "error")
    end

    -- Layer isolation: NOT about what the layer is named (see comment
    -- above POCKET_SIZE_IN) - about whether the pocket shares its
    -- layer with anything else. Per Mike, this is worth flagging as a
    -- genuine best-practice miss even though it doesn't affect the
    -- pocket's own geometry: an isolated layer makes it easy to select
    -- cleanly when building the pocket toolpath, regardless of what
    -- that layer happens to be called.
    if candidate.layer_object_count > 1 then
        r:Line(string.format(
            "  POCKET SHARES ITS LAYER with %d other object(s) - should be on its own layer",
            candidate.layer_object_count - 1
        ), "warning")
    end

    -- Corner radius, measured off the arc spans
    local arc_radii = {}
    local span_pos = contour:GetHeadPosition()
    while span_pos ~= nil do
        local span
        span, span_pos = contour:GetNext(span_pos)
        if span.IsArcType then
            local ok, radius = pcall(function()
                local centre = Point3D()
                local arc_span = CastSpanToArcSpan(span)
                return arc_span:RadiusAndCentre(centre)
            end)
            if ok then
                table.insert(arc_radii, radius)
            end
        end
    end

    if #arc_radii == 0 then
        r:Line("  No corner-rounding arcs found - expected 4 (0.5\" radius corners)", "error")
    else
        local radius_sum = 0
        for _, rad in ipairs(arc_radii) do
            radius_sum = radius_sum + rad
        end
        local avg_radius = radius_sum / #arc_radii
        r:Line(string.format(
            "  Corner radius: %.4f %s (from %d arcs), target %.3f %s",
            avg_radius, units, #arc_radii, corner_radius_target, units
        ))
        if math.abs(avg_radius - corner_radius_target) > corner_radius_tol then
            r:Line(string.format(
                "  CORNER RADIUS MISMATCH: expected %.3f %s, actual %.4f %s",
                corner_radius_target, units, avg_radius, units
            ), "error")
        end
        if #arc_radii ~= 4 then
            r:Line(string.format(
                "  %d corner arcs found - expected 4",
                #arc_radii
            ), "error")
        end
    end

    return r
end

-- Finds roughly-circular closed contours across ALL non-system
-- layers, within a given diameter band - same roundness-check
-- technique validated in CribbageBoardReviewReport.lua's
-- FindDowelHoleCandidates (width/height nearly equal = circular).
-- Returns a list of {dia=, x=, y=, layer_name=}.
function FindLargeCircularContours(job, min_dia, max_dia)
    local candidates = {}
    local layer_manager = job.LayerManager
    local layer_pos = layer_manager:GetHeadPosition()

    while layer_pos ~= nil do
        local layer
        layer, layer_pos = layer_manager:GetNext(layer_pos)

        if not layer.IsSystemLayer then
            local obj_pos = layer:GetHeadPosition()
            while obj_pos ~= nil do
                local obj
                obj, obj_pos = layer:GetNext(obj_pos)

                local ok, contour = pcall(function() return obj:GetContour() end)
                if ok and contour and contour.IsClosed then
                    local bb = contour.BoundingBox2D
                    if bb and not bb.IsInvalid then
                        local roundness_diff = math.abs(bb.XLength - bb.YLength)
                        local avg_dia = (bb.XLength + bb.YLength) / 2.0
                        if roundness_diff < CIRCLE_ROUNDNESS_TOLERANCE_IN
                           and avg_dia >= min_dia and avg_dia <= max_dia then
                            table.insert(candidates, {
                                dia = avg_dia,
                                x = bb.Centre.x,
                                y = bb.Centre.y,
                                layer_name = layer.Name,
                                obj = obj,
                            })
                        end
                    end
                end
            end
        end
    end

    return candidates
end

-- Circles check: outer circle 8.25" diameter and inner circle 7.5"
-- diameter (8.25" - 2*0.375" offset), both centred at the origin.
-- Searches all layers (see CIRCLE_* constants above for why) rather
-- than one named layer.
function FormatCirclesGeometryReport(job, mtl_block)
    local r = NewReport()
    local units = mtl_block.InMM and "mm" or "inches"
    local outer_target = ToJobUnits(CIRCLE_OUTER_DIA_IN, mtl_block)
    local inner_target = outer_target - 2 * ToJobUnits(CIRCLE_INNER_OFFSET_IN, mtl_block)
    local dia_tol = ToJobUnits(CIRCLE_DIA_TOLERANCE_IN, mtl_block)
    local center_tol = ToJobUnits(CIRCLE_CENTER_TOLERANCE_IN, mtl_block)
    local detect_min = ToJobUnits(CIRCLE_DETECTION_MIN_IN, mtl_block)
    local detect_max = ToJobUnits(CIRCLE_DETECTION_MAX_IN, mtl_block)

    r:Blank()
    r:Header("CIRCLES CHECK")

    local candidates = FindLargeCircularContours(job, detect_min, detect_max)

    if #candidates == 0 then
        r:Line(string.format(
            "  NO large circular contours found (expected 2, dia %.2f-%.2f %s) - outer/accent circles missing?",
            detect_min, detect_max, units
        ), "error")
        return r
    elseif #candidates == 1 then
        r:Line(string.format(
            "  Only 1 large circle found at (%.4f, %.4f) dia=%.4f %s - expected 2 (outer 8.25\" and inner 7.5\")",
            candidates[1].x, candidates[1].y, candidates[1].dia, units
        ), "error")
        return r
    elseif #candidates > 2 then
        local candidate_parts = {}
        for i, c in ipairs(candidates) do
            table.insert(candidate_parts, string.format("#%d (%.4f,%.4f) dia=%.4f layer='%s'", i, c.x, c.y, c.dia, c.layer_name))
        end
        r:Line(string.format(
            "  %d large circular contours found - expected exactly 2, can't determine which are the clock face circles: %s",
            #candidates, table.concat(candidate_parts, "; ")
        ), "error")
        return r
    end

    -- exactly 2 candidates - sort by diameter so we know which is
    -- "outer" vs "inner" without needing to guess from layer/order
    local a, b = candidates[1], candidates[2]
    local outer, inner
    if a.dia >= b.dia then
        outer, inner = a, b
    else
        outer, inner = b, a
    end

    r:Line(string.format("  Outer circle: (%.4f, %.4f) dia=%.4f %s", outer.x, outer.y, outer.dia, units))
    r:Line(string.format("  Inner circle: (%.4f, %.4f) dia=%.4f %s", inner.x, inner.y, inner.dia, units))

    if math.abs(outer.dia - outer_target) > dia_tol then
        r:Line(string.format(
            "  OUTER CIRCLE DIAMETER MISMATCH: expected %.3f %s, actual %.4f %s",
            outer_target, units, outer.dia, units
        ), "error")
    end
    if math.abs(inner.dia - inner_target) > dia_tol then
        r:Line(string.format(
            "  INNER CIRCLE DIAMETER MISMATCH: expected %.3f %s (8.25\" - 2x0.375\" offset), actual %.4f %s",
            inner_target, units, inner.dia, units
        ), "error")
    end

    if math.abs(outer.x) > center_tol or math.abs(outer.y) > center_tol then
        r:Line(string.format(
            "  OUTER CIRCLE NOT CENTRED: (%.4f, %.4f) %s (tolerance=%.3f)",
            outer.x, outer.y, units, center_tol
        ), "error")
    end
    if math.abs(inner.x) > center_tol or math.abs(inner.y) > center_tol then
        r:Line(string.format(
            "  INNER CIRCLE NOT CENTRED: (%.4f, %.4f) %s (tolerance=%.3f)",
            inner.x, inner.y, units, center_tol
        ), "error")
    end

    return r
end

-- Finds candidate "number" text objects across ALL non-system
-- layers by ClassName (see NUMBERS_* constants above for the naming
-- assumption and its fallback). Uses the base CadObject method
-- :GetBoundingBox() rather than :GetContour() - TxtBlock isn't
-- guaranteed to have a contour representation the way a plain vector
-- does ("not all objects will have a contour representation" per the
-- SDK reference), but :GetBoundingBox() is documented as a universal
-- CadObject method, so it should work regardless of the object's
-- specific type. Returns (candidates, class_name_counts) - the second
-- value is a table of {ClassName -> count} across the WHOLE job, used
-- as a diagnostic fallback if zero candidates match the guessed name.
function FindNumberTextCandidates(job)
    local candidates = {}
    local class_name_counts = {}
    local layer_manager = job.LayerManager
    local layer_pos = layer_manager:GetHeadPosition()

    while layer_pos ~= nil do
        local layer
        layer, layer_pos = layer_manager:GetNext(layer_pos)

        if not layer.IsSystemLayer then
            local obj_pos = layer:GetHeadPosition()
            while obj_pos ~= nil do
                local obj
                obj, obj_pos = layer:GetNext(obj_pos)

                local ok_class, class_name = pcall(function() return obj.ClassName end)
                if ok_class and class_name then
                    class_name_counts[class_name] = (class_name_counts[class_name] or 0) + 1
                end

                if ok_class and class_name == "txtBlock" then
                    local ok_bb, bb = pcall(function() return obj:GetBoundingBox() end)
                    if ok_bb and bb and not bb.IsInvalid then
                        table.insert(candidates, {
                            x = bb.Centre.x,
                            y = bb.Centre.y,
                            min_x = bb.MinX, max_x = bb.MaxX,
                            min_y = bb.MinY, max_y = bb.MaxY,
                            layer_name = layer.Name,
                            obj = obj,
                        })
                    end
                elseif ok_class and class_name == "vcCadObjectGroup" then
                    -- Numbers may have been grouped by the student (a
                    -- reasonable thing to do, same protective benefit
                    -- as the dragonfly grouping - see FormatNumbersArrangementReport
                    -- comment) - recurse one level into any group found
                    -- and pull out its txtBlock members too, so numbers
                    -- are found either way (grouped or not).
                    local ok_group, group = pcall(function() return CastCadObjectToCadObjectGroup(obj) end)
                    if ok_group and group then
                        local gpos = group:GetHeadPosition()
                        while gpos ~= nil do
                            local gobj
                            gobj, gpos = group:GetNext(gpos)
                            local ok_gclass, gclass_name = pcall(function() return gobj.ClassName end)
                            if ok_gclass and gclass_name then
                                class_name_counts[gclass_name] = (class_name_counts[gclass_name] or 0) + 1
                            end
                            if ok_gclass and gclass_name == "txtBlock" then
                                local ok_gbb, gbb = pcall(function() return gobj:GetBoundingBox() end)
                                if ok_gbb and gbb and not gbb.IsInvalid then
                                    table.insert(candidates, {
                                        x = gbb.Centre.x,
                                        y = gbb.Centre.y,
                                        min_x = gbb.MinX, max_x = gbb.MaxX,
                                        min_y = gbb.MinY, max_y = gbb.MaxY,
                                        layer_name = layer.Name .. " (grouped)",
                                        obj = gobj,
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return candidates, class_name_counts
end

-- Numbers arrangement check: verifies the 12 number objects form a
-- ring centred on the origin. Uses the COMBINED bounding box across
-- all 12 numbers (leftmost/rightmost/topmost/bottommost extent of the
-- whole set) rather than averaging each digit's own individual centre
-- - this is a deliberate fix (2026-08-15) after discovering the two
-- disagree: averaging individual centres is sensitive to per-digit
-- glyph-shape noise (a "1" is narrower than a "12"), which can make a
-- correctly-built ring read as "off-centre" even when it isn't. The
-- combined-bounding-box measure is ALSO exactly what VCarve's own
-- Alignment tool optimizes when centring a multi-object selection, so
-- this check now agrees with both of Mike's two sanctioned methods:
-- (1) building the ring correctly via Circular Copy centred at the
-- origin, and (2) grouping the numbers afterward and using the
-- Alignment tool to centre the group - previously only method (2)
-- would reliably pass.
--
-- Does NOT verify the numbers actually read 1-12 in order - see the
-- NUMBERS_* constants comment above for why, and per Mike, that part
-- is easy to catch by eye anyway.
function FormatNumbersArrangementReport(job, mtl_block)
    local r = NewReport()
    local units = mtl_block.InMM and "mm" or "inches"
    local center_tol = ToJobUnits(NUMBERS_CENTER_TOLERANCE_IN, mtl_block)

    r:Blank()
    r:Header("NUMBERS ARRANGEMENT CHECK")

    local candidates, class_name_counts = FindNumberTextCandidates(job)

    if #candidates == 0 then
        local class_parts = {}
        for class_name, count in pairs(class_name_counts) do
            table.insert(class_parts, string.format("%s=%d", class_name, count))
        end
        r:Line(string.format(
            "  NO objects found with ClassName 'txtBlock' - numbers missing? ClassNames present: %s",
            table.concat(class_parts, ", ")
        ), "error")
        return r
    end

    r:Line(string.format("  Found %d candidate number object(s) (expected %d)", #candidates, NUMBERS_COUNT_EXPECTED))
    if #candidates ~= NUMBERS_COUNT_EXPECTED then
        r:Line(string.format(
            "  NUMBER COUNT MISMATCH: found %d, expected %d",
            #candidates, NUMBERS_COUNT_EXPECTED
        ), "error")
    end

    if #candidates < 3 then
        r:Line("  Too few candidates to assess circular arrangement (need at least 3)", "error")
        return r
    end

    -- Position checks (centering, radius-outlier, angular-position) -
    -- DISABLED by default, see NUMBERS_POSITION_CHECKS_ENABLED comment
    -- above for the full history of why. The count check above this
    -- point stays active regardless - it carries no false-positive
    -- risk from the box-fit rendering issue that disabled these.
    if NUMBERS_POSITION_CHECKS_ENABLED then

    -- Combined bounding box across ALL candidates - the extreme
    -- outermost edges of the whole set, same quantity the Alignment
    -- tool centres. Only a handful of numbers near the ring's compass
    -- points actually determine this, unlike averaging every digit's
    -- own centre (which lets every digit's individual shape contribute
    -- noise).
    local agg_min_x, agg_max_x = candidates[1].min_x, candidates[1].max_x
    local agg_min_y, agg_max_y = candidates[1].min_y, candidates[1].max_y
    for i = 2, #candidates do
        local c = candidates[i]
        agg_min_x = math.min(agg_min_x, c.min_x)
        agg_max_x = math.max(agg_max_x, c.max_x)
        agg_min_y = math.min(agg_min_y, c.min_y)
        agg_max_y = math.max(agg_max_y, c.max_y)
    end
    local group_center_x = (agg_min_x + agg_max_x) / 2
    local group_center_y = (agg_min_y + agg_max_y) / 2
    local group_offset = math.sqrt(group_center_x * group_center_x + group_center_y * group_center_y)

    r:Line(string.format(
        "  Combined bounding box centre: (%.4f, %.4f) %s, offset from origin=%.4f %s",
        group_center_x, group_center_y, units, group_offset, units
    ))
    if group_offset > center_tol then
        r:Line(string.format(
            "  NUMBERS RING NOT CENTRED ON ORIGIN: offset=%.4f %s (tolerance=%.3f)",
            group_offset, units, center_tol
        ), "error")
    end

    -- Angular spacing between consecutive numbers (replaces the old
    -- radius-consistency check - see NUMBERS_ANGULAR_SPACING_TOLERANCE_DEG
    -- comment above for why). Average radius is still reported, purely
    -- informational, since it's useful context even though it's not a
    -- reliable pass/fail signal on its own.
    local radius_sum = 0
    for _, c in ipairs(candidates) do
        local dx = c.x - group_center_x
        local dy = c.y - group_center_y
        radius_sum = radius_sum + math.sqrt(dx * dx + dy * dy)
    end
    local avg_radius = radius_sum / #candidates
    r:Line(string.format(
        "  Average radius from centre: %.4f %s (informational only)",
        avg_radius, units
    ))

    -- Radius-outlier check - see NUMBERS_RADIUS_OUTLIER_SIGMA_THRESHOLD
    -- comment above for the full methodology and history. Mean and
    -- sample standard deviation computed across ALL 12 radii (never
    -- excluding any digit in advance - see the methodology note for
    -- why that matters). z-score per digit embedded directly in the
    -- error text when flagged, so the finding is self-contained.
    local radii = {}
    for _, c in ipairs(candidates) do
        local dx = c.x - group_center_x
        local dy = c.y - group_center_y
        table.insert(radii, math.sqrt(dx * dx + dy * dy))
    end

    local radius_variance_sum = 0
    for _, rad in ipairs(radii) do
        radius_variance_sum = radius_variance_sum + (rad - avg_radius) * (rad - avg_radius)
    end
    local radius_stddev = math.sqrt(radius_variance_sum / (#radii - 1))

    r:Line(string.format(
        "  Radius sample standard deviation: %.4f %s",
        radius_stddev, units
    ))

    local outlier_parts = {}
    for i, rad in ipairs(radii) do
        local z = (radius_stddev > 0) and ((rad - avg_radius) / radius_stddev) or 0
        if math.abs(z) > NUMBERS_RADIUS_OUTLIER_SIGMA_THRESHOLD then
            table.insert(outlier_parts, string.format(
                "#%d radius=%.4f %s (%.1f sigma from mean)",
                i, rad, units, z
            ))
        end
    end

    if #outlier_parts > 0 then
        r:Line(string.format(
            "  NUMBER(S) AT WRONG RADIAL DISTANCE FROM RING: %s (threshold=%.1f sigma)",
            table.concat(outlier_parts, "; "), NUMBERS_RADIUS_OUTLIER_SIGMA_THRESHOLD
        ), "error")
    end

    local angles = {}
    for _, c in ipairs(candidates) do
        local dx = c.x - group_center_x
        local dy = c.y - group_center_y
        local angle_deg = math.deg(math.atan2(dx, dy))
        if angle_deg < 0 then angle_deg = angle_deg + 360 end
        table.insert(angles, angle_deg)
    end
    table.sort(angles)

    local expected_gap = 360.0 / #candidates

    local gaps = {}
    local min_gap, max_gap = nil, nil
    for i = 1, #angles do
        local next_i = (i % #angles) + 1
        local gap = angles[next_i] - angles[i]
        if gap < 0 then gap = gap + 360 end
        table.insert(gaps, gap)
        min_gap = min_gap and math.min(min_gap, gap) or gap
        max_gap = max_gap and math.max(max_gap, gap) or gap
    end

    -- Angular-spacing outlier check - see
    -- NUMBERS_ANGULAR_OUTLIER_SIGMA_THRESHOLD comment above for the
    -- full methodology and history. expected_gap (360/N) IS the true
    -- mean by mathematical necessity, not an empirical estimate - only
    -- the spread around it is computed from the actual data.
    local gap_variance_sum = 0
    for _, gap in ipairs(gaps) do
        gap_variance_sum = gap_variance_sum + (gap - expected_gap) * (gap - expected_gap)
    end
    local gap_stddev = math.sqrt(gap_variance_sum / (#gaps - 1))

    r:Line(string.format(
        "  Angular spacing: expected %.2f deg, actual range %.2f-%.2f deg, sample stddev=%.2f deg",
        expected_gap, min_gap, max_gap, gap_stddev
    ))

    local angular_outlier_parts = {}
    for i = 1, #angles do
        local next_i = (i % #angles) + 1
        local gap = gaps[i]
        local z = (gap_stddev > 0) and ((gap - expected_gap) / gap_stddev) or 0
        if math.abs(z) > NUMBERS_ANGULAR_OUTLIER_SIGMA_THRESHOLD then
            table.insert(angular_outlier_parts, string.format(
                "%.2f->%.2f gap=%.2f deg (%.1f sigma from mean)",
                angles[i], angles[next_i], gap, z
            ))
        end
    end

    if #angular_outlier_parts > 0 then
        r:Line(string.format(
            "  NUMBER(S) AT WRONG ANGULAR POSITION IN RING: %s (threshold=%.1f sigma)",
            table.concat(angular_outlier_parts, "; "), NUMBERS_ANGULAR_OUTLIER_SIGMA_THRESHOLD
        ), "error")
    end

    end  -- NUMBERS_POSITION_CHECKS_ENABLED

    return r
end

-- Clusters circular candidates by shared center (true concentricity -
-- see DRAGONFLY_CONCENTRIC_CLUSTER_TOLERANCE_IN). Returns a list of
-- clusters, each {members=, x=, y=} where x/y is the average center of
-- that cluster's members. Simple O(n^2) grouping - fine given a
-- dragonfly's circular-member count is expected to be small (a
-- handful, not all ~52 pieces).
function ClusterByCenter(candidates, cluster_tol)
    local clusters = {}
    for _, c in ipairs(candidates) do
        local matched = nil
        for _, cluster in ipairs(clusters) do
            local dx = c.x - cluster.x
            local dy = c.y - cluster.y
            if math.sqrt(dx * dx + dy * dy) < cluster_tol then
                matched = cluster
                break
            end
        end
        if matched then
            table.insert(matched.members, c)
            local sum_x, sum_y = 0, 0
            for _, m in ipairs(matched.members) do
                sum_x = sum_x + m.x
                sum_y = sum_y + m.y
            end
            matched.x = sum_x / #matched.members
            matched.y = sum_y / #matched.members
        else
            table.insert(clusters, { members = { c }, x = c.x, y = c.y })
        end
    end
    return clusters
end

-- Dragonfly center-circle check: finds the two-or-more concentric
-- circles near the dragonfly's visual center (see DRAGONFLY_* comment
-- above) and checks their shared center against the workpiece origin,
-- within Mike's by-eye tolerance. Searches the dragonfly's leftover
-- objects (see FindDragonflyObjectsAndLayerStats above) directly -
-- no longer depends on a group existing, since the correct student
-- workflow may ungroup before toolpath creation (see DRAGONFLY comment
-- block above for the full history of why this changed 2026-08-16).
function FormatDragonflyCenterCircleReport(job, mtl_block)
    local r = NewReport()
    local units = mtl_block.InMM and "mm" or "inches"
    local center_tol = ToJobUnits(DRAGONFLY_CENTER_CIRCLE_TOLERANCE_IN, mtl_block)
    local cluster_tol = ToJobUnits(DRAGONFLY_CONCENTRIC_CLUSTER_TOLERANCE_IN, mtl_block)

    r:Blank()
    r:Header("DRAGONFLY CENTER-CIRCLE CHECK")

    local claimed_ids = GetDragonflyClaimedIds(job, mtl_block)
    local leftovers = FindDragonflyObjectsAndLayerStats(job, claimed_ids)

    if #leftovers == 0 then
        r:Line("  (skipped - no dragonfly objects found, see Dragonfly Layer Check above)")
        return r
    end

    -- Check each leftover object for circularity directly (same
    -- roundness technique as FindLargeCircularContours, but with no
    -- diameter target - see DRAGONFLY_* comment above for why)
    local circular_members = {}
    for _, lo in ipairs(leftovers) do
        local ok, contour = pcall(function() return lo.obj:GetContour() end)
        if ok and contour and contour.IsClosed then
            local bb = contour.BoundingBox2D
            if bb and not bb.IsInvalid then
                local roundness_diff = math.abs(bb.XLength - bb.YLength)
                if roundness_diff < DRAGONFLY_CIRCLE_ROUNDNESS_TOLERANCE_IN then
                    table.insert(circular_members, {
                        dia = (bb.XLength + bb.YLength) / 2.0,
                        x = bb.Centre.x,
                        y = bb.Centre.y,
                    })
                end
            end
        end
    end

    local clusters = ClusterByCenter(circular_members, cluster_tol)

    -- Only clusters with 2+ members count as "concentric" - a single
    -- circle isn't concentric with anything
    local concentric_clusters = {}
    for _, cluster in ipairs(clusters) do
        if #cluster.members >= 2 then
            table.insert(concentric_clusters, cluster)
        end
    end

    if #concentric_clusters == 0 then
        local candidate_parts = {}
        for i, c in ipairs(circular_members) do
            table.insert(candidate_parts, string.format("#%d dia=%.4f at (%.4f,%.4f)", i, c.dia, c.x, c.y))
        end
        r:Line(string.format(
            "  NO concentric circle pair found in the dragonfly artwork - could not verify center alignment. %d circular object(s) found: %s",
            #circular_members, table.concat(candidate_parts, "; ")
        ), "error")
        return r
    elseif #concentric_clusters > 1 then
        local cluster_parts = {}
        for i, cluster in ipairs(concentric_clusters) do
            table.insert(cluster_parts, string.format("cluster %d: %d circles at (%.4f,%.4f)", i, #cluster.members, cluster.x, cluster.y))
        end
        r:Line(string.format(
            "  %d distinct concentric-circle clusters found - expected exactly 1, review manually: %s",
            #concentric_clusters, table.concat(cluster_parts, "; ")
        ), "error")
        return r
    end

    local cluster = concentric_clusters[1]
    local offset = math.sqrt(cluster.x * cluster.x + cluster.y * cluster.y)

    r:Line(string.format(
        "  Concentric circle center found: (%.4f, %.4f) %s (%d circles), offset from origin=%.4f %s",
        cluster.x, cluster.y, units, #cluster.members, offset, units
    ))
    if offset > center_tol then
        r:Line(string.format(
            "  DRAGONFLY CENTER CIRCLES NOT ALIGNED WITH ORIGIN: offset=%.4f %s (tolerance=%.3f)",
            offset, units, center_tol
        ), "warning")
    end

    return r
end

-- Returns true if a computed depth counts as "cutting through the
-- material into the spoilboard" - shared threshold logic used by both
-- FormatOvercutReport and the toolpath order check (see
-- POCKET_TOOLPATH_DEPTH_OFFSET_IN comment above for why these two
-- checks each do their own independent scan and apply this SAME
-- predicate, rather than sharing toolpath object references across
-- scans).
function IsThroughCutDepth(depth, mtl_block)
    return depth > mtl_block.Thickness + 0.001
end

-- Overcut check on the final cutout toolpath, ported from the same
-- validated mechanism in both other projects: find the toolpath whose
-- absolute cut depth exceeds material thickness, and check the
-- overcut amount. Since this job is Single-Sided (only one Z-zero
-- reference plane in the data model - see IDENTIFICATION GAP at the
-- top of this file), any toolpath that legitimately cuts through the
-- material should be the final cutout - if MORE than one toolpath
-- exceeds thickness, this is flagged as ambiguous rather than guessed.
function FormatOvercutReport(job, mtl_block)
    local r = NewReport()
    local units = mtl_block.InMM and "mm" or "inches"
    local overcut_target = ToJobUnits(OVERCUT_TARGET_IN, mtl_block)
    local overcut_tolerance = ToJobUnits(OVERCUT_TOLERANCE_IN, mtl_block)
    local boundary_epsilon = ToJobUnits(BOUNDARY_EPSILON_IN, mtl_block)

    r:Blank()
    r:Header("OVERCUT CHECK (final cutout)")

    local tpm = ToolpathManager()
    local through_cuts = {}
    local pos = tpm:GetHeadPosition()
    while pos ~= nil do
        local tp
        tp, pos = tpm:GetNext(pos)
        local ok_stats, stats = pcall(function() return tp:Statistics() end)
        if ok_stats and stats and stats.IsValid then
            local depth = mtl_block:CalcDepthFromAbsoluteZ(stats.MinimumZ)
            if IsThroughCutDepth(depth, mtl_block) then
                table.insert(through_cuts, { tp = tp, depth = depth })
            end
        end
    end

    if #through_cuts == 0 then
        r:Line("  No toolpath found that cuts through the material - cannot check overcut", "error")
        return r
    elseif #through_cuts > 1 then
        r:Line(string.format(
            "  %d toolpaths cut through the material - expected exactly 1 (the final cutout), review manually:",
            #through_cuts
        ), "error")
        for _, tc in ipairs(through_cuts) do
            r:Line(string.format("     '%s' depth=%.4f %s", tc.tp.Name, tc.depth, units))
        end
        return r
    end

    local tc = through_cuts[1]
    local overcut = tc.depth - mtl_block.Thickness
    r:Line(string.format(
        "  '%s': depth=%.4f %s  thickness=%.4f %s  overcut=%.4f %s",
        tc.tp.Name, tc.depth, units, mtl_block.Thickness, units, overcut, units
    ))
    if math.abs(overcut - overcut_target) > overcut_tolerance + boundary_epsilon then
        r:Line(string.format(
            "  OVERCUT OUT OF RANGE: %.4f %s (target %.3f +/- %.3f %s)",
            overcut, units, overcut_target, overcut_tolerance, units
        ), "error")
    end

    return r
end

-- Toolpath count check: flags if the count isn't exactly 7 (see
-- TOOLPATHS_COUNT_EXPECTED comment above). Safe, always-on, non-
-- destructive - unlike the recalculation check below, this doesn't
-- need to touch the toolpaths at all.
function FormatToolpathCountReport(job)
    local r = NewReport()
    r:Blank()
    r:Header("TOOLPATH COUNT CHECK")

    local tpm = ToolpathManager()
    r:Line(string.format("  Found %d toolpath(s) (expected %d)", tpm.Count, TOOLPATHS_COUNT_EXPECTED))
    if tpm.Count ~= TOOLPATHS_COUNT_EXPECTED then
        r:Line(string.format(
            "  TOOLPATH COUNT MISMATCH: found %d, expected %d",
            tpm.Count, TOOLPATHS_COUNT_EXPECTED
        ), "error")
    end

    return r
end

-- Speeds/feeds checks (2026-08-17, per Mike): even though 4 of the 7
-- operations (accent circle, numbers, dragonfly, chamfer) can't be
-- told apart from EACH OTHER - see IDENTIFICATION GAP at the top of
-- this file - that doesn't mean they can't be CHECKED. All four share
-- the exact same tool (1/4" 60 deg V-bit) and the exact same target
-- RPM/feed/plunge (14,000 / 80 / 30) per the instructions - the
-- dragonfly section explicitly says "just like carving out the
-- numbers... use the same settings", and the chamfer section says
-- "since I already had the 60 deg v-bit out", confirming this is the
-- SAME physical tool across all four, not a coincidence. So rather
-- than identify WHICH of the four a given toolpath is, this checks
-- every toolpath matching that tool signature (Tool.ToolType==VBIT,
-- ToolDia~=0.25", VBit angle~=60deg - all real, documented,
-- non-name-based Tool properties) against the ONE shared target,
-- flagging any mismatch by whatever name the student gave it.
--
-- Pocket, Cutout, and Shaft Hole are ALL individually identifiable
-- (same depth-based signals already built for other checks - see
-- POCKET_TOOLPATH_DEPTH_OFFSET_IN and IsThroughCutDepth above), so
-- those three get their own individual targets - CONFIRMED they are
-- NOT all the same: Pocket and Cutout share 18,000 RPM / 110 IPM feed
-- / 55 IPM plunge, but Shaft Hole is genuinely different at 21,000 /
-- 60 / 30 - checked the exact instructions text for each rather than
-- assume they matched just because Pocket and Cutout did.
--
-- V-Bit angle property name: SDK documentation's own property TABLE
-- lists it as ".VBit_Angle", but EVERY real sample script that
-- actually SETS this property (Create_VCarving_Toolpath.lua,
-- Create_Prism_Toolpath.lua, etc.) consistently uses "tool.VBitAngle"
-- (no underscore) instead - a real, confirmed discrepancy between the
-- documentation table and actual working code (same category of gap
-- already hit with CadObject.Id). GetToolVBitAngle() below tries both
-- names defensively rather than trusting either blindly.
--
-- Feed/plunge/RPM values are read directly from tp.Tool, which
-- reflects the ACTUAL per-toolpath values the student explicitly set
-- (per Mike, 2026-08-17) - not a shared tool-database default. This
-- is already confirmed correct by every real toolpath dump seen in
-- this project, which consistently shows DIFFERENT values across
-- different toolpaths even when they nominally use "the same" bit.
POCKET_CUTOUT_RPM = 18000
POCKET_CUTOUT_FEED_IN = 110  -- IPM
POCKET_CUTOUT_PLUNGE_IN = 55  -- IPM

-- Shaft Hole identified by TOOL DIAMETER (~1/8"), not depth (per
-- Mike, 2026-08-17: depth was an unnecessary hedge - shaft hole is
-- the ONLY operation among all 7 using a 1/8" bit; every other
-- operation is 1/4" - confirmed directly against the instructions
-- text for each). This is a more direct signal than depth: it's tied
-- to an explicit physical tool choice ("the tool is a 1/8" downcut
-- bit"), not a computed Z-value that depends on the depth math being
-- right. Combined with Tool.ToolType == END_MILL for the same
-- multi-signal robustness already used for the V-bit group below.
SHAFT_HOLE_DIA_IN = 0.125  -- inches (1/8")
SHAFT_HOLE_DIA_TOLERANCE_IN = 0.01  -- inches
SHAFT_HOLE_RPM = 21000
SHAFT_HOLE_FEED_IN = 60  -- IPM
SHAFT_HOLE_PLUNGE_IN = 30  -- IPM

VBIT_GROUP_RPM = 14000
VBIT_GROUP_FEED_IN = 80  -- IPM
VBIT_GROUP_PLUNGE_IN = 30  -- IPM
VBIT_GROUP_DIA_IN = 0.25  -- inches
VBIT_GROUP_DIA_TOLERANCE_IN = 0.01  -- inches
VBIT_GROUP_ANGLE_DEG = 60  -- degrees
VBIT_GROUP_ANGLE_TOLERANCE_DEG = 2  -- degrees
VBIT_GROUP_COUNT_EXPECTED = 4  -- accent circle, numbers, dragonfly,
                                 -- chamfer - per Mike (2026-08-17):
                                 -- silently skipping a partial miss
                                 -- here (e.g. only 2 of 4 matched the
                                 -- tool signature) would hide a real
                                 -- problem, so this count is now
                                 -- checked explicitly rather than
                                 -- only firing when ALL 4 fail at once.

SPEEDS_FEEDS_RPM_TOLERANCE = 250
SPEEDS_FEEDS_RATE_TOLERANCE_IN = 5  -- IPM, applied to both feed and
                                     -- plunge - UNVALIDATED against
                                     -- real files, first reasonable
                                     -- guess

-- Tries both possible property names for the V-bit included angle -
-- see the comment block above for why this is uncertain rather than
-- trusting the documented name blindly.
function GetToolVBitAngle(tool)
    local ok1, angle1 = pcall(function() return tool.VBitAngle end)
    if ok1 and angle1 then
        return angle1
    end
    local ok2, angle2 = pcall(function() return tool.VBit_Angle end)
    if ok2 and angle2 then
        return angle2
    end
    return nil
end

-- Checks one toolpath's tool against a target RPM/feed/plunge, and
-- appends a finding to the report if it's off. tp.Tool reflects the
-- ACTUAL, per-toolpath values the student explicitly typed in (per
-- Mike, 2026-08-17) - confirmed by real data throughout this project
-- (every toolpath dump shows different RPM/feed/plunge per operation,
-- even ones nominally sharing a tool, which would be impossible if
-- Tool.FeedRate etc. were just an unchanging database default).
function CheckSpeedFeedTarget(r, name, tool, target_rpm, target_feed, target_plunge)
    local ok_rpm, rpm = pcall(function() return tool.SpindleSpeed end)
    local ok_feed, feed = pcall(function() return tool.FeedRate end)
    local ok_plunge, plunge = pcall(function() return tool.PlungeRate end)

    local problems = {}
    if ok_rpm and math.abs(rpm - target_rpm) > SPEEDS_FEEDS_RPM_TOLERANCE then
        table.insert(problems, string.format("RPM=%.0f (expect %.0f)", rpm, target_rpm))
    end
    if ok_feed and math.abs(feed - target_feed) > SPEEDS_FEEDS_RATE_TOLERANCE_IN then
        table.insert(problems, string.format("feed=%.1f (expect %.1f)", feed, target_feed))
    end
    if ok_plunge and math.abs(plunge - target_plunge) > SPEEDS_FEEDS_RATE_TOLERANCE_IN then
        table.insert(problems, string.format("plunge=%.1f (expect %.1f)", plunge, target_plunge))
    end

    if #problems > 0 then
        r:Line(string.format(
            "  SPEEDS/FEEDS MISMATCH on '%s': %s",
            name, table.concat(problems, ", ")
        ), "error")
    end
end

-- Speeds/feeds check across all identifiable operations. Does its own
-- single scan (same pattern as the order check, for the same reason -
-- no cross-scan object matching). EVERY category (Pocket, Cutout,
-- Shaft Hole, V-bit group) now reports explicitly when identification
-- fails or gives an ambiguous/wrong count (2026-08-17, per Mike -
-- previously a partial miss on the V-bit group, or any single-slot
-- category coming back with 0 or 2+ matches, was silently skipped
-- with no indication anything was wrong).
function FormatSpeedsFeedsReport(job, mtl_block)
    local r = NewReport()
    r:Blank()
    r:Header("SPEEDS/FEEDS CHECK")

    local vbit_dia_target = ToJobUnits(VBIT_GROUP_DIA_IN, mtl_block)
    local vbit_dia_tol = ToJobUnits(VBIT_GROUP_DIA_TOLERANCE_IN, mtl_block)
    local shaft_hole_dia_target = ToJobUnits(SHAFT_HOLE_DIA_IN, mtl_block)
    local shaft_hole_dia_tol = ToJobUnits(SHAFT_HOLE_DIA_TOLERANCE_IN, mtl_block)
    local pocket_target = mtl_block.Thickness - ToJobUnits(POCKET_TOOLPATH_DEPTH_OFFSET_IN, mtl_block)
    local pocket_tol = ToJobUnits(POCKET_TOOLPATH_DEPTH_TOLERANCE_IN, mtl_block)

    local tpm = ToolpathManager()
    local pocket_candidates, cutout_candidates, shaft_hole_candidates, vbit_candidates = {}, {}, {}, {}

    local pos = tpm:GetHeadPosition()
    while pos ~= nil do
        local tp
        tp, pos = tpm:GetNext(pos)

        local depth = nil
        local ok_stats, stats = pcall(function() return tp:Statistics() end)
        if ok_stats and stats and stats.IsValid then
            depth = mtl_block:CalcDepthFromAbsoluteZ(stats.MinimumZ)
        end

        local ok_tool, tool = pcall(function() return tp.Tool end)
        if ok_tool and tool then
            if depth and math.abs(depth - pocket_target) <= pocket_tol then
                table.insert(pocket_candidates, { name = tp.Name, tool = tool })
            end
            if depth and IsThroughCutDepth(depth, mtl_block) then
                table.insert(cutout_candidates, { name = tp.Name, tool = tool })
            end

            local ok_dia, tool_dia = pcall(function() return tool.ToolDia end)
            local ok_tt, tool_type = pcall(function() return tool.ToolType end)

            if ok_dia and ok_tt and tool_type == Tool.END_MILL
               and math.abs(tool_dia - shaft_hole_dia_target) <= shaft_hole_dia_tol then
                table.insert(shaft_hole_candidates, { name = tp.Name, tool = tool })
            end

            local vbit_angle = GetToolVBitAngle(tool)
            if ok_tt and tool_type == Tool.VBIT
               and ok_dia and math.abs(tool_dia - vbit_dia_target) <= vbit_dia_tol
               and vbit_angle and math.abs(vbit_angle - VBIT_GROUP_ANGLE_DEG) <= VBIT_GROUP_ANGLE_TOLERANCE_DEG then
                table.insert(vbit_candidates, { name = tp.Name, tool = tool })
            end
        end
    end

    -- Pocket
    if #pocket_candidates == 0 then
        r:Line("  Could not identify the Pocket toolpath by depth - cannot check its speeds/feeds", "error")
    elseif #pocket_candidates > 1 then
        local names = {}
        for _, c in ipairs(pocket_candidates) do table.insert(names, "'" .. c.name .. "'") end
        r:Line(string.format(
            "  %d toolpaths match Pocket's expected depth - cannot uniquely check speeds/feeds: %s",
            #pocket_candidates, table.concat(names, ", ")
        ), "error")
    else
        CheckSpeedFeedTarget(r, pocket_candidates[1].name, pocket_candidates[1].tool, POCKET_CUTOUT_RPM, POCKET_CUTOUT_FEED_IN, POCKET_CUTOUT_PLUNGE_IN)
    end

    -- Cutout
    if #cutout_candidates == 0 then
        r:Line("  Could not identify the Cutout toolpath (none cut through material) - cannot check its speeds/feeds", "error")
    elseif #cutout_candidates > 1 then
        local names = {}
        for _, c in ipairs(cutout_candidates) do table.insert(names, "'" .. c.name .. "'") end
        r:Line(string.format(
            "  %d toolpaths cut through the material - cannot uniquely check Cutout's speeds/feeds: %s",
            #cutout_candidates, table.concat(names, ", ")
        ), "error")
    else
        CheckSpeedFeedTarget(r, cutout_candidates[1].name, cutout_candidates[1].tool, POCKET_CUTOUT_RPM, POCKET_CUTOUT_FEED_IN, POCKET_CUTOUT_PLUNGE_IN)
    end

    -- Shaft Hole (identified by tool diameter, ~1/8" - see
    -- SHAFT_HOLE_DIA_IN comment above for why)
    if #shaft_hole_candidates == 0 then
        r:Line("  Could not identify the Shaft Hole toolpath (no 1/8\" end mill toolpath found) - cannot check its speeds/feeds", "error")
    elseif #shaft_hole_candidates > 1 then
        local names = {}
        for _, c in ipairs(shaft_hole_candidates) do table.insert(names, "'" .. c.name .. "'") end
        r:Line(string.format(
            "  %d toolpaths match Shaft Hole's 1/8\" tool signature - cannot uniquely check speeds/feeds: %s",
            #shaft_hole_candidates, table.concat(names, ", ")
        ), "error")
    else
        CheckSpeedFeedTarget(r, shaft_hole_candidates[1].name, shaft_hole_candidates[1].tool, SHAFT_HOLE_RPM, SHAFT_HOLE_FEED_IN, SHAFT_HOLE_PLUNGE_IN)
    end

    -- V-bit group: expect exactly 4 (accent circle, numbers, dragonfly,
    -- chamfer) - a partial miss is now reported explicitly, not just
    -- the all-4-failed case.
    if #vbit_candidates ~= VBIT_GROUP_COUNT_EXPECTED then
        local names = {}
        for _, c in ipairs(vbit_candidates) do table.insert(names, "'" .. c.name .. "'") end
        r:Line(string.format(
            "  V-BIT GROUP COUNT MISMATCH: found %d toolpath(s) matching the accent/numbers/dragonfly/chamfer tool signature, expected %d%s",
            #vbit_candidates, VBIT_GROUP_COUNT_EXPECTED,
            #names > 0 and (": " .. table.concat(names, ", ")) or ""
        ), "error")
    end
    for _, c in ipairs(vbit_candidates) do
        CheckSpeedFeedTarget(r, c.name, c.tool, VBIT_GROUP_RPM, VBIT_GROUP_FEED_IN, VBIT_GROUP_PLUNGE_IN)
    end

    return r
end

-- Toolpath order check - see POCKET_TOOLPATH_DEPTH_OFFSET_IN comment
-- above for the full rationale. Pocket identified by depth, cutout
-- identified by the shared through-cut threshold - both computed
-- within ONE single scan here (not by matching objects found in a
-- separate scan elsewhere), so there's no risk of the cross-scan
-- object-identity trap already hit once with CadObject.Id.
function FormatToolpathOrderReport(job, mtl_block)
    local r = NewReport()
    r:Blank()
    r:Header("TOOLPATH ORDER CHECK")

    local tpm = ToolpathManager()
    local ordered = {}
    local pos = tpm:GetHeadPosition()
    local idx = 0
    while pos ~= nil do
        local tp
        tp, pos = tpm:GetNext(pos)
        idx = idx + 1

        local depth = nil
        local ok_stats, stats = pcall(function() return tp:Statistics() end)
        if ok_stats and stats and stats.IsValid then
            depth = mtl_block:CalcDepthFromAbsoluteZ(stats.MinimumZ)
        end

        local tool_type = nil
        local ok_tool, tool = pcall(function() return tp.Tool end)
        if ok_tool and tool then
            local ok_tt, tt = pcall(function() return tool.ToolType end)
            if ok_tt then tool_type = tt end
        end

        table.insert(ordered, { name = tp.Name, depth = depth, tool_type = tool_type, index = idx })
    end

    local total = #ordered
    if total == 0 then
        r:Line("  No toolpaths found - cannot check order", "error")
        return r
    end

    -- Pocket must be first
    local pocket_target = mtl_block.Thickness - ToJobUnits(POCKET_TOOLPATH_DEPTH_OFFSET_IN, mtl_block)
    local pocket_tol = ToJobUnits(POCKET_TOOLPATH_DEPTH_TOLERANCE_IN, mtl_block)
    local pocket_candidates = {}
    for _, o in ipairs(ordered) do
        if o.depth and math.abs(o.depth - pocket_target) <= pocket_tol then
            table.insert(pocket_candidates, o)
        end
    end

    if #pocket_candidates == 0 then
        r:Line("  Could not identify the pocket toolpath by depth - cannot verify it's first", "error")
    elseif #pocket_candidates > 1 then
        local parts = {}
        for _, o in ipairs(pocket_candidates) do
            table.insert(parts, string.format("'%s'(pos %d)", o.name, o.index))
        end
        r:Line(string.format(
            "  %d toolpaths match the pocket's expected depth - can't uniquely identify it: %s",
            #pocket_candidates, table.concat(parts, "; ")
        ), "error")
    else
        local pocket = pocket_candidates[1]
        if pocket.index ~= 1 then
            r:Line(string.format(
                "  POCKET TOOLPATH NOT FIRST: '%s' is at position %d of %d, should be position 1",
                pocket.name, pocket.index, total
            ), "error")
        end
    end

    -- Cutout must be last or second-to-last; whatever follows it (if
    -- anything) must be a V-bit
    local cutout_candidates = {}
    for _, o in ipairs(ordered) do
        if o.depth and IsThroughCutDepth(o.depth, mtl_block) then
            table.insert(cutout_candidates, o)
        end
    end

    if #cutout_candidates == 0 then
        r:Line("  Could not identify the cutout toolpath (none cut through material) - cannot verify its position", "error")
    elseif #cutout_candidates > 1 then
        local parts = {}
        for _, o in ipairs(cutout_candidates) do
            table.insert(parts, string.format("'%s'(pos %d)", o.name, o.index))
        end
        r:Line(string.format(
            "  %d toolpaths cut through the material - can't uniquely identify the cutout for order checking: %s",
            #cutout_candidates, table.concat(parts, "; ")
        ), "error")
    else
        local cutout = cutout_candidates[1]
        if cutout.index ~= total and cutout.index ~= total - 1 then
            r:Line(string.format(
                "  CUTOUT TOOLPATH OUT OF ORDER: '%s' is at position %d of %d, should be last or second-to-last",
                cutout.name, cutout.index, total
            ), "error")
        elseif cutout.index == total - 1 then
            local following = ordered[total]
            if following.tool_type ~= Tool.VBIT then
                r:Line(string.format(
                    "  TOOLPATH AFTER CUTOUT MUST USE A V-BIT: '%s' follows the cutout but is not a V-bit toolpath",
                    following.name
                ), "error")
            end
        end
    end

    return r
end

-- Toolpath recalculation check - see RECALCULATE_TOOLPATHS_TO_CHECK_ERRORS
-- comment above for the full discussion (destructive, but on by
-- default as of 2026-08-15 - VCarve's own UI gives no other way to
-- detect this). Detects a toolpath whose source vectors are gone
-- (a real example: the "Micrometer" leftover toolpath in CorrectClock)
-- by attempting to recalculate every toolpath and recording which ones
-- fail.
function FormatToolpathRecalculationReport(job)
    local r = NewReport()
    r:Blank()
    r:Header("TOOLPATH RECALCULATION CHECK")

    if not RECALCULATE_TOOLPATHS_TO_CHECK_ERRORS then
        r:Line("  (disabled - set RECALCULATE_TOOLPATHS_TO_CHECK_ERRORS = true to re-enable)")
        return r
    end

    r:Line("  REMINDER: this Gadget marks the file 'modified' in VCarve \226\128\148 don't save over the student's original", "warning")

    local tpm = ToolpathManager()

    -- First pass: collect every toolpath's name + id WITHOUT
    -- recalculating anything yet - recalculating while iterating the
    -- manager's own list risks corrupting the iteration (the SDK
    -- warns the old toolpath is destroyed and replaced internally).
    local targets = {}
    local pos = tpm:GetHeadPosition()
    while pos ~= nil do
        local tp
        tp, pos = tpm:GetNext(pos)
        local ok_id, id_wrapper = pcall(function()
            local w = luaUUID()
            w:SetId(tp.Id)
            return w
        end)
        if ok_id then
            table.insert(targets, { name = tp.Name, id_wrapper = id_wrapper })
        else
            table.insert(targets, { name = tp.Name, id_wrapper = nil })
        end
    end

    -- Second pass: recalculate each one individually, re-finding its
    -- position each time - never reusing a toolpath variable across a
    -- recalculation, per the SDK's explicit warning that the passed
    -- toolpath is invalid after the call.
    --
    -- MESSAGE DESIGN (2026-08-17, per Mike): every real recalculation
    -- failure seen so far comes down to the same underlying condition
    -- - no vectors are currently selected for that toolpath (confirmed
    -- by Mike opening each one directly) - whether because the source
    -- vectors were deleted (Micrometer) or some other reason (Center
    -- hole, Numbers, Dragonfly on a later file). A post-attempt
    -- Statistics().IsValid re-check was tried as a way to distinguish
    -- "genuinely broken" from a suspected transient VCarve quirk with
    -- relative depth expressions ("z-.25" etc.) - tested against two
    -- real files and found to read IsValid=true in EVERY case,
    -- including the confirmed-genuine Micrometer failure - meaning it
    -- doesn't actually discriminate anything and was dropped. The
    -- message now just tells the instructor what to do about ANY
    -- failure, compactly, rather than implying an automated verdict
    -- the check can't actually deliver.
    local failures = {}
    local recalculated_count = 0
    for _, target in ipairs(targets) do
        if not target.id_wrapper then
            table.insert(failures, target.name .. " (could not get an ID to track it - skipped)")
        else
            local find_pos = tpm:Find(target.id_wrapper.RawId)
            if find_pos == nil then
                table.insert(failures, target.name .. " (could not be found for recalculation)")
            else
                local tp = tpm:GetAt(find_pos)
                local ok, result = pcall(function() return tpm:RecalculateToolpath(tp) end)

                if not ok or not result then
                    table.insert(failures, string.format(
                        "'%s' - open the toolpath, check for errors, run Calculate if needed",
                        target.name
                    ))
                else
                    recalculated_count = recalculated_count + 1
                end
            end
        end
    end

    r:Line(string.format("  %d of %d toolpaths recalculated successfully", recalculated_count, #targets))
    for _, f in ipairs(failures) do
        r:Line("  RECALCULATION FAILED: " .. f, "error")
    end

    -- Recalculating leaves every toolpath visible in the 2D view, and
    -- toolpath preview drawings live on hidden SYSTEM layers separate
    -- from the toolpath's own Visible flag (CadLayer.IsSystemLayer -
    -- confirmed 2026-08-15 against a real file; the toolpath-level
    -- SetAllToolpathsVisibility() call alone does NOT clear the 2D
    -- view, hiding the system layer's CadLayer.Visible directly is
    -- what actually works). This cleanup now happens silently - per
    -- Mike (2026-08-17), this is routine gadget housekeeping an
    -- experienced instructor doesn't need announced every run; it was
    -- only worth explaining once, while we were figuring out why it
    -- wasn't working (see git history / prior transcript for that
    -- investigation if ever needed again).
    pcall(function() tpm:SetAllToolpathsVisibility(false) end)
    pcall(function() job:Refresh2DView() end)

    local ok_layers, layer_manager = pcall(function() return job.LayerManager end)
    if ok_layers and layer_manager then
        local lpos = layer_manager:GetHeadPosition()
        while lpos ~= nil do
            local layer
            layer, lpos = layer_manager:GetNext(lpos)
            local ok_is_sys, is_sys = pcall(function() return layer.IsSystemLayer end)
            if ok_is_sys and is_sys then
                pcall(function() layer.Visible = false end)
            end
        end
        pcall(function() job:Refresh2DView() end)
    end

    return r
end

-- Per-pass depth reminder for the final cutout, same reasoning as
-- BoxProjectReviewReport.lua's FormatManualPassDepthReminder(): per-
-- pass depths aren't accessible via the Gadget API (confirmed
-- exhaustively there), and the instructions are explicit that the
-- FIRST pass on a compression bit must be deeper than the bit's upcut
-- portion (here: "I've set up 3 passes... I have set the first pass
-- depth to be 0.3" so that it's deeper than the upcut part of the bit").
function FormatManualPassDepthReminder()
    local r = NewReport()
    r:Blank()
    r:Line("  Manually verify per-pass depths on the final cutout (Edit Passes) - first pass must be deeper than the compression bit's upcut portion (~0.3\" suggested in the instructions)", "warning")
    return r
end

-- Tab reminder for the final cutout - kept deliberately terse
-- (2026-08-17, per Mike's audience principle): an experienced
-- instructor already knows what the tabs should look like from the
-- instructions, they just need a prompt to go check, not the spec
-- repeated every run. Same automatable-check gap as
-- BoxProjectReviewReport.lua's FormatManualTabsReminder() - see that
-- function for the full investigation history (no trustworthy
-- automated path found as of 2026-08-11).
function FormatManualTabsReminder()
    local r = NewReport()
    r:Blank()
    r:Line("  Manually verify tabs are placed on the final cutout", "warning")
    return r
end

function FormatLayerReport(job)
    local r = NewReport()
    local layer_manager = job.LayerManager
    r:Header("LAYERS (" .. layer_manager.Count .. ")")

    local pos = layer_manager:GetHeadPosition()
    while pos ~= nil do
        local layer
        layer, pos = layer_manager:GetNext(pos)

        if not layer.IsSystemLayer then
            local vis = layer.Visible and "visible" or "HIDDEN"
            local lock = layer.Locked and "LOCKED" or "unlocked"
            r:Line(string.format(
                "  %-25s objects=%-4d %s, %s",
                layer.Name, layer.Count, vis, lock
            ))
        end
    end

    return r
end

-- No fixed spec table for per-operation RPM/feed/plunge - see
-- IDENTIFICATION GAP at the top of this file. Lists every toolpath
-- with its computed depth from Z-zero, for manual comparison against
-- the instructions' per-operation values, same style as
-- BoxProjectReviewReport.lua's FormatToolpathReport (for the same
-- underlying reason: no reliable automated identification available
-- yet).
function FormatToolpathReport(job, mtl_block)
    local r = NewReport()
    local units = mtl_block.InMM and "mm" or "inches"

    local tpm = ToolpathManager()

    r:Blank()
    r:Header("TOOLPATHS (" .. tpm.Count .. ")")

    if tpm.Count == 0 then
        r:Line("  NO TOOLPATHS FOUND IN JOB", "error")
        return r
    end

    local pos = tpm:GetHeadPosition()
    while pos ~= nil do
        local tp
        tp, pos = tpm:GetNext(pos)

        local tool = tp.Tool
        local tool_desc = "no tool assigned"
        if tool then
            tool_desc = string.format(
                "tool='%s' dia=%.3f #%d feed=%.1f plunge=%.1f rpm=%.0f",
                tool.Name, tool.ToolDia, tool.ToolNumber,
                tool.FeedRate, tool.PlungeRate, tool.SpindleSpeed
            )
        end

        local depth_desc = ""
        local ok_stats, stats = pcall(function() return tp:Statistics() end)
        if ok_stats and stats and stats.IsValid then
            local depth = mtl_block:CalcDepthFromAbsoluteZ(stats.MinimumZ)
            depth_desc = string.format("  depth=%.4f %s", depth, units)
        end

        r:Line(string.format("  %-20s %s%s", tp.Name, tool_desc, depth_desc))
    end

    return r
end

function main(script_path)
    local job = VectricJob()
    if not job.Exists then
        local dialog = HTML_Dialog(false, "file:" .. script_path .. "\\" .. g_html_file, g_width, g_height, g_title)
        dialog:AddLabelField("ReportText", "No job loaded - open the student's file first.")
        dialog:ShowDialog()
        return false
    end

    local mtl_block = MaterialBlock()
    local units = mtl_block.InMM and "mm" or "inches"

    local full = NewReport()
    full:Line("CLOCK REVIEW REPORT v" .. g_version)
    full:Line("========================================")
    full:Line("Job: " .. job.Name)
    full:Line("Reviewed: " .. GetTimestampString())
    full:Line("Units: " .. units)
    full:Blank()
    full:Line("MATERIAL")
    full:Line("----------------------------------------")
    full:Line(string.format(
        "  Width=%.3f  Height=%.3f  Thickness=%.3f %s",
        mtl_block.Width, mtl_block.Height, mtl_block.Thickness, units
    ))
    full:Blank()

    -- GATING CHECK: must be Single-Sided before any further analysis
    -- can be trusted. Added 2026-08-17 after Mike discovered the
    -- report gives DIFFERENT, INCOMPLETE results depending on which
    -- side happens to be active in VCarve's UI when the job is
    -- Two-Sided - confirmed as real, documented VCarve behavior:
    -- job.LayerManager and ToolpathManager() are both scoped to
    -- whichever side is currently active (job:GetSideList() /
    -- :SetActiveSide() / :GetActiveSideId() exist specifically
    -- because each side has its own separate layers and toolpaths).
    -- Rather than build a full per-side-iteration architecture so
    -- every check sees both sides at once, Mike's call (2026-08-17):
    -- since Two-Sided is ALREADY something this project tells the
    -- student is wrong, just gate on it first and stop - there's no
    -- value in a partial, side-dependent review of a file that needs
    -- this fixed before anything else matters anyway.
    if job.IsDoubleSided then
        full:Line("  JOB TYPE ERROR: this project must be Single-Sided (per instructions). This job is currently set up as Two-Sided, which must be corrected BEFORE any further review.", "error")
    else
        full:Append(FormatMaterialSetupReport(mtl_block))
        full:Append(FormatJobTypeReport(job))
        full:Append(FormatCirclesGeometryReport(job, mtl_block))
        full:Append(FormatNumbersArrangementReport(job, mtl_block))
        full:Append(FormatDragonflyLayerReport(job, mtl_block))
        full:Append(FormatDragonflyCenterCircleReport(job, mtl_block))
        full:Append(FormatPocketGeometryReport(job, mtl_block))
        full:Append(FormatOvercutReport(job, mtl_block))
        full:Append(FormatToolpathCountReport(job))
        full:Append(FormatToolpathOrderReport(job, mtl_block))
        full:Append(FormatSpeedsFeedsReport(job, mtl_block))
        full:Append(FormatToolpathRecalculationReport(job))
        full:Append(FormatManualPassDepthReminder())
        full:Append(FormatManualTabsReminder())

        full:Blank()
        full:Append(FormatLayerReport(job))
        full:Append(FormatToolpathReport(job, mtl_block))
    end

    if full.flagged then
        full:Blank()
        full:Line("*** ISSUES FLAGGED ABOVE - REVIEW BEFORE APPOINTMENT ***")
    end

    local summary = NewReport()
    summary:Line("CLOCK REVIEW SUMMARY v" .. g_version)
    summary:Line("Job: " .. job.Name)
    summary:Line("Reviewed: " .. GetTimestampString())
    summary:Line(string.format(
        "Material: %.3f x %.3f x %.3f %s",
        mtl_block.Width, mtl_block.Height, mtl_block.Thickness, units
    ))
    summary:Line(string.format(
        "Layers: %d   Toolpaths: %d",
        job.LayerManager.Count, ToolpathManager().Count
    ))

    local report_html = RecordsToHtml(summary.records)

    if VERBOSE_OUTPUT then
        report_html = report_html .. "<br>\n" .. RecordsToHtml(full.records)
    elseif full.flagged then
        local warning_records = {}
        local error_records = {}
        for _, rec in ipairs(full.records) do
            if rec.severity == "warning" then
                table.insert(warning_records, rec)
            elseif rec.severity == "error" then
                table.insert(error_records, rec)
            end
        end

        if #warning_records > 0 then
            report_html = report_html .. NumberedSectionHtml("WARNINGS:", warning_records, "#b35900")
        end
        if #error_records > 0 then
            report_html = report_html .. NumberedSectionHtml("ERRORS:", error_records, "#b00000")
        end
    else
        report_html = report_html .. "<br>\nNo issues flagged."
    end

    local html_path = "file:" .. script_path .. "\\" .. g_html_file
    local dialog_title = g_title .. "  \226\128\148  " .. job.Name
    local dialog = HTML_Dialog(false, html_path, g_width, g_height, dialog_title)
    dialog:AddLabelField("ReportText", report_html)
    dialog:ShowDialog()

    return true
end
